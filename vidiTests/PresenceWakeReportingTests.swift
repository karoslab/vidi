//
//  PresenceWakeReportingTests.swift
//  vidiTests
//
//  Verifies the pure decision helpers behind the presence-wake reporter
//  (Workstream S3): the 30-minute client throttle that coalesces a burst of
//  wake/unlock notifications into one POST, and the hour-bucketed dedupe key the
//  broker uses as a server-side backstop. Both are extracted from
//  PresenceWakeReporter so they can be checked without AppKit or a live backend.
//

import Foundation
import Testing
@testable import Vidi

struct PresenceWakeReportingTests {

    // MARK: - Throttle: first-of-session always posts

    @Test func firstSignalOfSessionPosts() {
        // No prior post this app session (fresh launch) → always send. Launching
        // after sleep genuinely IS presence.
        let shouldPost = PresenceWakeReporting.shouldPost(
            lastPostTime: nil,
            now: Date()
        )
        #expect(shouldPost == true)
    }

    // MARK: - Throttle: bursts within 30 minutes collapse

    @Test func secondSignalMomentsLaterIsThrottled() {
        // A returning human trips wake → screens-wake → unlock back-to-back. Only
        // the first should POST; the ones seconds later must be suppressed.
        let firstPostTime = Date()
        let secondsLater = firstPostTime.addingTimeInterval(3)
        let shouldPost = PresenceWakeReporting.shouldPost(
            lastPostTime: firstPostTime,
            now: secondsLater
        )
        #expect(shouldPost == false)
    }

    @Test func signalJustUnderThirtyMinutesIsThrottled() {
        let firstPostTime = Date()
        // 29m59s later — still inside the 30-minute window → suppressed.
        let justUnder = firstPostTime.addingTimeInterval(30 * 60 - 1)
        let shouldPost = PresenceWakeReporting.shouldPost(
            lastPostTime: firstPostTime,
            now: justUnder
        )
        #expect(shouldPost == false)
    }

    // MARK: - Throttle: after 30 minutes, post again

    @Test func signalAtExactlyThirtyMinutesPostsAgain() {
        let firstPostTime = Date()
        // Exactly 30 minutes later — the spacing is inclusive (>=) → post.
        let atThreshold = firstPostTime.addingTimeInterval(30 * 60)
        let shouldPost = PresenceWakeReporting.shouldPost(
            lastPostTime: firstPostTime,
            now: atThreshold
        )
        #expect(shouldPost == true)
    }

    @Test func signalWellAfterWindowPostsAgain() {
        let firstPostTime = Date()
        let anHourLater = firstPostTime.addingTimeInterval(60 * 60)
        let shouldPost = PresenceWakeReporting.shouldPost(
            lastPostTime: firstPostTime,
            now: anHourLater
        )
        #expect(shouldPost == true)
    }

    // MARK: - Dedupe key formatting

    /// A fixed calendar (UTC) so the hour bucket is deterministic regardless of
    /// where the test runs — the app uses `.current`, but the FORMAT is what we
    /// are pinning here, not the local zone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func dedupeKeyIsPresencePrefixedHourBucket() {
        // 2026-07-03 08:42:17 UTC → bucketed to the 08:00 hour.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 3
        components.hour = 8
        components.minute = 42
        components.second = 17
        components.timeZone = TimeZone(identifier: "UTC")

        let date = utcCalendar.date(from: components)!
        let key = PresenceWakeReporting.presenceDedupeKey(for: date, calendar: utcCalendar)
        #expect(key == "presence:2026-07-03-08")
    }

    @Test func dedupeKeyZeroPadsMonthDayAndHour() {
        // Single-digit month, day, and a pre-noon hour must all zero-pad so the
        // key is fixed-width and sorts/compares cleanly.
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 5
        components.hour = 6
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")

        let date = utcCalendar.date(from: components)!
        let key = PresenceWakeReporting.presenceDedupeKey(for: date, calendar: utcCalendar)
        #expect(key == "presence:2026-01-05-06")
    }

    @Test func twoTimesInSameHourShareOneKey() {
        // Two wakes 20 minutes apart in the same clock hour → identical dedupe key
        // so the broker collapses them even if both somehow POST.
        var earlyComponents = DateComponents()
        earlyComponents.year = 2026
        earlyComponents.month = 12
        earlyComponents.day = 31
        earlyComponents.hour = 23
        earlyComponents.minute = 5
        earlyComponents.timeZone = TimeZone(identifier: "UTC")

        var lateComponents = earlyComponents
        lateComponents.minute = 55

        let earlyDate = utcCalendar.date(from: earlyComponents)!
        let lateDate = utcCalendar.date(from: lateComponents)!

        let earlyKey = PresenceWakeReporting.presenceDedupeKey(for: earlyDate, calendar: utcCalendar)
        let lateKey = PresenceWakeReporting.presenceDedupeKey(for: lateDate, calendar: utcCalendar)
        #expect(earlyKey == lateKey)
        #expect(earlyKey == "presence:2026-12-31-23")
    }

    @Test func adjacentHoursGetDistinctKeys() {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.hour = 9
        components.minute = 59
        components.timeZone = TimeZone(identifier: "UTC")

        let nineFiftyNine = utcCalendar.date(from: components)!
        let tenOhOne = nineFiftyNine.addingTimeInterval(2 * 60)

        let firstKey = PresenceWakeReporting.presenceDedupeKey(for: nineFiftyNine, calendar: utcCalendar)
        let secondKey = PresenceWakeReporting.presenceDedupeKey(for: tenOhOne, calendar: utcCalendar)
        #expect(firstKey == "presence:2026-06-15-09")
        #expect(secondKey == "presence:2026-06-15-10")
        #expect(firstKey != secondKey)
    }
}
