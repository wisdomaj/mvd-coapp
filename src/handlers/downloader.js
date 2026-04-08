import fs from 'fs';
import path from 'path';
import os from 'os';
import { logDebug, getFreeDiskSpace, normalizeForFsWindows, sanitizeFilename, ensureUniqueFilename } from '../utils/utils';
import { TRANSCODE_TOOL_TIMEOUT } from '../utils/config';
import { handleRunTool } from './tools';

const activeDownloads = new Map();

// --- Helpers ---
function resolveSaveDir(raw) {
    if (!raw || typeof raw !== 'string') return null;
    let expanded = raw;
    if (expanded === '~') {
        expanded = os.homedir();
    } else if (expanded.startsWith('~/') || expanded.startsWith('~\\')) {
        expanded = path.join(os.homedir(), expanded.slice(2));
    }
    return path.resolve(expanded);
}

function isPathInUse(fullPath) {
    for (const entry of activeDownloads.values()) {
        if (entry?.finalPath === fullPath) return true;
    }
    return false;
}

function buildUiPath(fullPath) {
    const home = os.homedir();
    const relative = path.relative(home, fullPath);
    if (relative && !relative.startsWith('..') && !path.isAbsolute(relative)) {
        return path.join('~', relative);
    }
    return fullPath;
}

// --- Main Handler ---
export async function handleDownload(request, responder) {
    const { command, downloadId } = request;

    if (command === 'cancel-download-v2') {
        const entry = activeDownloads.get(downloadId);
        if (!entry) return { success: false, from: command, downloadId, error: 'Not found', key: 'ENOENT' };

        logDebug(`[Downloader] Canceling ${downloadId}`);
        const { child } = entry;
        try { if (child.stdin?.writable) child.stdin.write('q\n'); } catch { /* ignore */ }
        setTimeout(() => !child.killed && child.kill('SIGTERM'), 15000);
        setTimeout(() => !child.killed && child.kill('SIGKILL'), 35000);
        return { success: true, from: command, downloadId };
    }

    if (command === 'transcode') {
        return startTranscodeOnly(request, responder);
    }

    return startDownload(request, responder);
}

async function startDownload(params, responder) {
    const { downloadId, argsBeforeOutput, saveDir, filename, container, allowOverwrite = false, url } = params;
    logDebug(`[Downloader] Starting download ${downloadId} (name: ${filename}, dir: ${saveDir})`);
    
    const resolvedDir = resolveSaveDir(saveDir);
    if (!resolvedDir) {
        logDebug(`[Downloader] Failed to resolve saveDir: ${saveDir}`);
        return { command: 'download-finished', downloadId, key: 'ENOENT', error: 'Invalid saveDir' };
    }

    try {
        if (!fs.existsSync(resolvedDir)) {
            logDebug(`[Downloader] Creating directory: ${resolvedDir}`);
            fs.mkdirSync(resolvedDir, { recursive: true });
        }
        fs.accessSync(normalizeForFsWindows(resolvedDir), fs.constants.W_OK);
    } catch (err) {
        const key = err.key || err.code || 'internalError';
        logDebug(`[Downloader] FS setup failed for ${resolvedDir}:`, err.message);
        return {
            command: 'download-finished',
            downloadId,
            key,
            error: err.message,
            ...(Array.isArray(err.substitutions) && err.substitutions.length ? { substitutions: err.substitutions } : {})
        };
    }

    // Disk space report (once at start as per original)
    getFreeDiskSpace(resolvedDir).then(free => {
        responder.send({ command: 'download-disk-space', downloadId, targetDir: resolvedDir, freeBytes: free });
    });

    const sanitized = sanitizeFilename(filename, `download-${downloadId}`, container);
    
    // If filename already has the extension and we are in allowOverwrite mode (download-as),
    // we should trust the filename more strictly.
    const finalFilename = (allowOverwrite && !isPathInUse(path.join(resolvedDir, filename))) 
        ? filename 
        : ensureUniqueFilename(resolvedDir, sanitized, isPathInUse);
    
    const finalPath = path.resolve(resolvedDir, finalFilename);
    const spawnPath = normalizeForFsWindows(finalPath);
    const uiPath = buildUiPath(finalPath);

    logDebug(`[Downloader] Path resolved: ${finalPath}`);
    responder.send({ command: 'filename-resolved', downloadId, resolvedFilename: finalFilename, path: uiPath });

    const spawnResult = await handleRunTool({
        tool: 'ffmpeg',
        args: [...argsBeforeOutput, spawnPath],
        timeoutMs: 0,
        job: { kind: 'download', id: downloadId, url },
        progressCommand: 'download-progress'
    }, responder, {
        onSpawn: (child) => activeDownloads.set(downloadId, { child, finalPath })
    });

    activeDownloads.delete(downloadId);
    const stderr = String(spawnResult.stderr || '').split(/\r?\n|\r(?!\n)/).filter(Boolean).slice(-50).join('\n');

    // --- Post-download transcoding ---
    if (spawnResult.success && fs.existsSync(finalPath) && params.transcode) {
        const transcodeResult = await runTranscode(downloadId, finalPath, params.transcode, responder);

        if (transcodeResult.success) {
            return {
                command: 'download-finished',
                downloadId,
                success: true,
                transcoded: true,
                path: transcodeResult.path,
                ...(transcodeResult.stats ? { transcodeStats: transcodeResult.stats } : {})
            };
        } else {
            // Transcode failed — download still succeeded, original preserved
            return {
                command: 'download-finished',
                downloadId,
                success: true,
                path: finalPath,
                transcodeFailed: true,
                transcodeError: transcodeResult.error || 'Transcoding failed',
                ...(transcodeResult.hwFallbackFailed ? { hwFallbackFailed: true } : {})
            };
        }
    }

    const finalResult = {
        command: 'download-finished',
        downloadId,
        ...(spawnResult.success ? { success: true } : {}),
        ...(spawnResult.code !== undefined && spawnResult.code !== null && spawnResult.code !== 0 ? { code: spawnResult.code } : {}),
        ...(spawnResult.signal ? { signal: spawnResult.signal } : {}),
        ...(fs.existsSync(finalPath) ? { path: finalPath } : {}),
        ...(spawnResult.timeout ? { timeout: true } : {}),
        ...(spawnResult.key ? { key: spawnResult.key } : {}),
        ...(spawnResult.error ? { error: spawnResult.error } : {}),
        ...(spawnResult.stdout ? { stdout: spawnResult.stdout } : {}),
        ...(stderr ? { stderr } : {}),
        ...(Array.isArray(spawnResult.substitutions) && spawnResult.substitutions.length ? { substitutions: spawnResult.substitutions } : {})
    };

    return finalResult;
}

// --- Standalone Transcode (retry) ---

async function startTranscodeOnly(params, responder) {
    const { downloadId, inputPath, transcode } = params;
    logDebug(`[Transcode] Starting standalone transcode ${downloadId} (input: ${inputPath})`);

    if (!inputPath || !transcode) {
        return { command: 'transcode-finished', downloadId, success: false, error: 'Missing inputPath or transcode params' };
    }

    // Verify input file exists
    if (!fs.existsSync(inputPath)) {
        return { command: 'transcode-finished', downloadId, success: false, error: 'Input file not found', key: 'ENOENT' };
    }

    const transcodeResult = await runTranscode(downloadId, inputPath, transcode, responder);

    if (transcodeResult.success) {
        return {
            command: 'transcode-finished',
            downloadId,
            success: true,
            transcoded: true,
            path: transcodeResult.path,
            ...(transcodeResult.stats ? { transcodeStats: transcodeResult.stats } : {})
        };
    } else {
        return {
            command: 'transcode-finished',
            downloadId,
            success: false,
            path: inputPath,
            error: transcodeResult.error || 'Transcoding failed',
            ...(transcodeResult.hwFallbackFailed ? { hwFallbackFailed: true } : {})
        };
    }
}

// --- Transcoding ---

async function runTranscode(downloadId, inputPath, transcodeParams, responder) {
    const { args, outputContainer, deleteOriginal = true, softwareFallbackArgs } = transcodeParams;

    // Build output path: same directory, same basename, new extension
    const dir = path.dirname(inputPath);
    const baseName = path.basename(inputPath, path.extname(inputPath));
    const transcodeExt = outputContainer ? `.${outputContainer}` : path.extname(inputPath);
    const tempFilename = `${baseName}.transcoding${transcodeExt}`;
    const tempPath = path.resolve(dir, tempFilename);

    // Pre-transcode disk space check (need at least the size of original as headroom)
    try {
        const inputSize = fs.statSync(inputPath).size;
        const freeBytes = await getFreeDiskSpace(dir);
        if (freeBytes !== null && freeBytes < inputSize) {
            logDebug(`[Transcode] Insufficient disk space: ${freeBytes} free, need ~${inputSize}`);
            return { success: false, error: 'Insufficient disk space for transcoding' };
        }
    } catch { /* proceed anyway if check fails */ }

    responder.send({ command: 'transcode-started', downloadId });

    const result = await executeTranscode(downloadId, inputPath, tempPath, args, responder);

    if (!result.success && softwareFallbackArgs) {
        // HW encode failed — retry with software encoder
        logDebug(`[Transcode] HW encode failed, retrying with software encoder`);
        cleanupFile(tempPath);
        responder.send({ command: 'transcode-started', downloadId, hwFallback: true });
        const fallbackResult = await executeTranscode(downloadId, inputPath, tempPath, softwareFallbackArgs, responder);

        if (!fallbackResult.success) {
            cleanupFile(tempPath);
            return { success: false, error: fallbackResult.error || 'Transcoding failed (HW and software)', hwFallbackFailed: true };
        }

        return finalizeTranscode(downloadId, inputPath, tempPath, dir, baseName, transcodeExt, deleteOriginal);
    }

    if (!result.success) {
        cleanupFile(tempPath);
        return { success: false, error: result.error || 'Transcoding failed' };
    }

    return finalizeTranscode(downloadId, inputPath, tempPath, dir, baseName, transcodeExt, deleteOriginal);
}

async function executeTranscode(downloadId, inputPath, outputPath, args, responder) {
    const spawnPath = normalizeForFsWindows(outputPath);

    const transcodeResult = await handleRunTool({
        tool: 'ffmpeg',
        args: ['-i', inputPath, '-stats', '-progress', 'pipe:2', '-y', ...args, spawnPath],
        timeoutMs: TRANSCODE_TOOL_TIMEOUT,
        job: { kind: 'download', id: downloadId },
        progressCommand: 'transcode-progress'
    }, responder, {
        onSpawn: (child) => activeDownloads.set(downloadId, { child, finalPath: outputPath })
    });

    activeDownloads.delete(downloadId);
    const stderr = String(transcodeResult.stderr || '').split(/\r?\n|\r(?!\n)/).filter(Boolean).slice(-50).join('\n');
    return { success: transcodeResult.success, error: stderr, key: transcodeResult.key };
}

function finalizeTranscode(_downloadId, inputPath, tempPath, dir, baseName, transcodeExt, deleteOriginal) {
    try {
        const inputSize = fs.existsSync(inputPath) ? fs.statSync(inputPath).size : 0;
        const outputSize = fs.existsSync(tempPath) ? fs.statSync(tempPath).size : 0;

        // Rename transcoded file to final name
        const finalName = ensureUniqueFilename(dir, `${baseName}${transcodeExt}`, isPathInUse);
        const finalPath = path.resolve(dir, finalName);
        fs.renameSync(tempPath, finalPath);

        // Delete original if requested
        if (deleteOriginal && fs.existsSync(inputPath) && inputPath !== finalPath) {
            fs.unlinkSync(inputPath);
            logDebug(`[Transcode] Deleted original: ${inputPath}`);
        }

        logDebug(`[Transcode] Complete: ${finalPath} (${inputSize} → ${outputSize})`);
        return {
            success: true,
            path: finalPath,
            stats: { inputSize, outputSize }
        };
    } catch (err) {
        logDebug(`[Transcode] Finalize error: ${err.message}`);
        // Both files may exist — don't delete either, let user sort it out
        return { success: true, path: tempPath, stats: {} };
    }
}

function cleanupFile(filePath) {
    try {
        if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
    } catch { /* ignore cleanup errors */ }
}
