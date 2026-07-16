//
//  VidiLogTests.swift
//  vidiTests
//
//  Pins the pure, side-effect-free pieces of the live-tail logger: the line
//  format the orchestrator's `tail -F` parses, and the size-cap rotation trigger.
//  The disk I/O itself is deliberately best-effort-and-silent (untestable by
//  design — it must never throw), so only the pure helpers are asserted here.
//

import Testing
import Foundation
@testable import Vidi

struct VidiLogTests {

    // MARK: - Line format

    @Test func lineHasTimestampPrefixMessageAndNewline() {
        // A fixed date so the formatted prefix is deterministic. 13:05:07.123 in
        // the formatter's local timezone.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 3
        components.hour = 13
        components.minute = 5
        components.second = 7
        components.nanosecond = 123_000_000
        let calendar = Calendar(identifier: .gregorian)
        let fixedDate = calendar.date(from: components)!

        let line = VidiLog.formattedLogLine(for: "🎙️ start requested", at: fixedDate)

        // Ends with the message + newline.
        #expect(line.hasSuffix("🎙️ start requested\n"))
        // Starts with an HH:mm:ss.SSS timestamp then a single space.
        let timestampPattern = #"^\d{2}:\d{2}:\d{2}\.\d{3} "#
        #expect(line.range(of: timestampPattern, options: .regularExpression) != nil)
        // Exactly one trailing newline.
        #expect(line.filter { $0 == "\n" }.count == 1)
    }

    @Test func timestampReflectsTheGivenTime() {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = 9
        components.minute = 41
        components.second = 30
        components.nanosecond = 500_000_000
        let fixedDate = Calendar(identifier: .gregorian).date(from: components)!

        let line = VidiLog.formattedLogLine(for: "hello", at: fixedDate)
        // The minute/second are stable regardless of timezone shifts within the
        // hour; assert the deterministic minute:second.millis tail of the stamp.
        #expect(line.contains(":41:30.500 hello\n"))
    }

    // MARK: - Rotation trigger

    @Test func doesNotRotateBelowTheCap() {
        #expect(VidiLog.shouldRotate(
            currentSizeBytes: 4 * 1024 * 1024,
            maximumLogFileSizeBytes: 5 * 1024 * 1024
        ) == false)
    }

    @Test func rotatesAtTheCap() {
        #expect(VidiLog.shouldRotate(
            currentSizeBytes: 5 * 1024 * 1024,
            maximumLogFileSizeBytes: 5 * 1024 * 1024
        ) == true)
    }

    @Test func rotatesAboveTheCap() {
        #expect(VidiLog.shouldRotate(
            currentSizeBytes: 9 * 1024 * 1024,
            maximumLogFileSizeBytes: 5 * 1024 * 1024
        ) == true)
    }

    // MARK: - Path contract (the orchestrator tails this exact file)

    @Test func logFilePathIsTheContractPath() {
        // Retest instructions assume this EXACT path. If this ever changes, those
        // instructions must change too — that's what this test guards.
        #expect(VidiLog.logFileURL.path.hasSuffix(
            "Library/Application Support/Vidi/vidi-debug.log"
        ))
        #expect(VidiLog.rotatedLogFileURL.lastPathComponent == "vidi-debug.log.old")
    }
}
