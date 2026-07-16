//
//  VidiLog.swift
//  vidi
//
//  Tiny, thread-safe, non-blocking file logger for LIVE debugging of the voice
//  path. The owner runs `tail -F ~/Library/Application Support/Vidi/vidi-debug.log`
//  while testing push-to-talk, so the orchestrator can watch what Vidi is doing
//  in real time instead of copy-pasting the Xcode console.
//
//  Design constraints (all deliberate):
//  - Logging must NEVER affect the app. Every write path swallows its errors —
//    a failed directory create, a failed open, a full disk: all silently ignored.
//    A debug logger that can crash or block the app is worse than no logger.
//  - Non-blocking / thread-safe: all file work runs on a private serial queue, so
//    call sites (many on @MainActor) never touch the disk on their own thread.
//  - Per-line flush is fine at this volume (a handful of lines per voice turn) —
//    it keeps the tail up to date without a background flush timer.
//  - Rotates at 5 MB, keeping exactly one `.old` file, so an all-night test run
//    can't grow the log without bound.
//
//  The public entry point is the free function `vlog(_:)`, which BOTH prints to
//  the Xcode console (so an attached debug run is unchanged) AND appends to the
//  file. Call sites on the voice path were converted from bare `print(...)` to
//  `vlog(...)`.
//

import Foundation

/// Dual-write log helper for the voice path: prints to the Xcode console exactly
/// as before AND appends the same line to the live-tail debug file. Use this in
/// place of `print(...)` on the voice path (dictation, PTT, ambient, TTS,
/// hands-control action lines) so the orchestrator's `tail -F` sees the same
/// stream the owner sees in Xcode.
func vlog(_ message: String) {
    print(message)
    VidiLog.log(message)
}

/// File-backed live-tail logger. All state is confined to `serialWriteQueue`;
/// callers only ever hand it a fully-formed message and return immediately.
enum VidiLog {
    /// Absolute path the orchestrator tails: retest instructions assume this
    /// EXACT location, so do not change it without updating those instructions.
    /// `~/Library/Application Support/Vidi/vidi-debug.log`.
    static let logFileURL: URL = {
        let applicationSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory
            .appendingPathComponent("Vidi", isDirectory: true)
            .appendingPathComponent("vidi-debug.log", isDirectory: false)
    }()

    /// The `.old` file we rotate the current log into once it crosses the size
    /// cap. Exactly one generation is kept; the previous `.old` is overwritten.
    static let rotatedLogFileURL: URL = logFileURL.appendingPathExtension("old")

    /// Rotate once the live file crosses this size, keeping one `.old` file.
    static let maximumLogFileSizeBytes: UInt64 = 5 * 1024 * 1024

    /// All disk work happens here so no call site (many on @MainActor) blocks on
    /// I/O and concurrent calls can't interleave a half-written line.
    private static let serialWriteQueue = DispatchQueue(label: "com.vidi.vidilog")

    /// Timestamp formatter for the `HH:mm:ss.SSS` prefix on every line. Confined
    /// to the serial queue (DateFormatter is not thread-safe), so it is only ever
    /// touched from `serialWriteQueue`.
    private static let lineTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Append one line to the live-tail file as `HH:mm:ss.SSS <message>`. Returns
    /// immediately; the actual write is enqueued on the serial queue. ALL failures
    /// are silently ignored — logging must never affect the app.
    static func log(_ message: String) {
        // Capture the time on the calling thread so the timestamp reflects when
        // the event happened, not when the queue drained to it.
        let eventDate = Date()
        serialWriteQueue.async {
            let formattedLine = formattedLogLine(for: message, at: eventDate)
            writeLineToFile(formattedLine)
        }
    }

    /// Builds the `HH:mm:ss.SSS <message>\n` line. Pure given the formatter's
    /// timezone/locale — exposed internal so the formatting is unit-testable.
    static func formattedLogLine(for message: String, at date: Date) -> String {
        return "\(lineTimestampFormatter.string(from: date)) \(message)\n"
    }

    /// Whether a file of `currentSizeBytes` should be rotated before appending
    /// `incomingLineByteCount` more bytes. Pure — unit-testable without touching
    /// the disk. Rotation triggers once the file has reached the cap (so the
    /// `.old` file is at most cap-sized and the live file restarts small).
    static func shouldRotate(
        currentSizeBytes: UInt64,
        maximumLogFileSizeBytes: UInt64
    ) -> Bool {
        return currentSizeBytes >= maximumLogFileSizeBytes
    }

    // MARK: - Private disk plumbing (serialWriteQueue only)

    /// Appends the already-formatted line to the file, creating the directory and
    /// file if needed and rotating first if the file is at the size cap. Every
    /// failure is swallowed — a debug logger must be incapable of harming the app.
    private static func writeLineToFile(_ formattedLine: String) {
        let fileManager = FileManager.default
        let logDirectoryURL = logFileURL.deletingLastPathComponent()

        // Best-effort directory create. If this throws (permissions, read-only
        // volume) we simply give up on this line — no propagation.
        do {
            try fileManager.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        rotateLogFileIfNeeded()

        guard let lineData = formattedLine.data(using: .utf8) else { return }

        // If the file doesn't exist yet, create it with this first line. If it
        // does, open a handle, seek to the end, append, and close.
        if !fileManager.fileExists(atPath: logFileURL.path) {
            try? lineData.write(to: logFileURL, options: .atomic)
            return
        }

        guard let fileHandle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? fileHandle.close() }
        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: lineData)
        } catch {
            // Swallow — a mid-write failure must not surface to the app.
        }
    }

    /// Rotates the live file to `.old` (overwriting any previous `.old`) once it
    /// crosses the size cap, so the log can't grow without bound overnight. All
    /// failures ignored.
    private static func rotateLogFileIfNeeded() {
        let fileManager = FileManager.default

        guard
            let fileAttributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
            let currentSizeBytes = (fileAttributes[.size] as? NSNumber)?.uint64Value
        else {
            return
        }

        guard shouldRotate(
            currentSizeBytes: currentSizeBytes,
            maximumLogFileSizeBytes: maximumLogFileSizeBytes
        ) else {
            return
        }

        // Replace the single `.old` generation with the current file.
        try? fileManager.removeItem(at: rotatedLogFileURL)
        try? fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }
}
