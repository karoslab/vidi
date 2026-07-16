//
//  LocalInstantAnswersTests.swift
//  vidiTests
//
//  Pins the on-device instant-answer fast path — the fix for the owner's
//  number-one latency complaint ("she takes her sweet time"), where a trivial
//  "what time is it?" was routed through the full vision pipeline (~6s) or the
//  agent (13–16s) for a fact the Mac already knows. `LocalInstantAnswers` is
//  pure (Foundation Date/Calendar only, injected), so both the NARROW matcher
//  and the spoken-sentence composer are testable without audio, networking, or a
//  real clock. The load-bearing rules: the three trivial facts match across
//  casing/punctuation/STT stumbles, ANY extra intent (a location, a subject, a
//  qualifier) must NOT match so it falls through to the real brains, and the
//  composer speaks in Vidi's casual lowercase register written for the ear.
//

import Testing
import Foundation
@testable import Vidi

struct LocalInstantAnswersTests {

    // MARK: - Matches (the three trivial facts)

    @Test func currentTimePhrasingsMatch() {
        for query in [
            "what time is it",
            "What time is it?",
            "what's the time",
            "whats the time now",
            "time please",
            "tell me the time",
            "do you have the time?",
            "current time",
        ] {
            #expect(LocalInstantAnswers.match(query: query) == .currentTime,
                    "expected .currentTime for \"\(query)\"")
        }
    }

    @Test func todaysDatePhrasingsMatch() {
        for query in [
            "what's the date",
            "What's today's date?",
            "whats todays date",
            "what date is it",
            "what date is it today",
            "tell me the date",
            "date please",
        ] {
            #expect(LocalInstantAnswers.match(query: query) == .todaysDate,
                    "expected .todaysDate for \"\(query)\"")
        }
    }

    @Test func dayOfWeekPhrasingsMatch() {
        for query in [
            "what day is it",
            "what day is it today",
            "What day is it today?",
            "what day of the week is it",
            "which day is it",
        ] {
            #expect(LocalInstantAnswers.match(query: query) == .dayOfWeek,
                    "expected .dayOfWeek for \"\(query)\"")
        }
    }

    // MARK: - Clipped / accented forms (P1 widening from the live debug log)

    @Test func clippedTimeFormsMatch() {
        // "what time is?" (the 06:44 log — release-tail dropped the "it") went to
        // the vision brain and got clipped. These clipped/accented variants must
        // now hit the fast path.
        for query in [
            "what time is",       // the exact 06:44 clip
            "what time is?",
            "what the time",
            "whats time",
            "whats time now",
            "time now",
            "tell me time",
            "time",
        ] {
            #expect(LocalInstantAnswers.match(query: query) == .currentTime,
                    "expected .currentTime for \"\(query)\"")
        }
    }

    @Test func clippedDateFormsMatch() {
        for query in [
            "whats date",
            "what date",
            "what date today",
            "date today",
            "whats the date now",
        ] {
            #expect(LocalInstantAnswers.match(query: query) == .todaysDate,
                    "expected .todaysDate for \"\(query)\"")
        }
    }

    @Test func clippedDayFormsMatch() {
        for query in [
            "what day is",        // parallel clip of "what time is"
            "whats the day",
            "which day",
            "what day today",
            "day today",
        ] {
            #expect(LocalInstantAnswers.match(query: query) == .dayOfWeek,
                    "expected .dayOfWeek for \"\(query)\"")
        }
    }

    @Test func clippedFormsStillRejectExtraIntent() {
        // The widening must not loosen the narrowness rule — a clipped stem with
        // extra intent still falls through to the brains.
        #expect(LocalInstantAnswers.match(query: "what time is the meeting") == nil)
        #expect(LocalInstantAnswers.match(query: "what day is the standup") == nil)
        #expect(LocalInstantAnswers.match(query: "what date is the release") == nil)
    }

    // MARK: - STT-stumble tolerance

    @Test func doubledHelperWordStillMatches() {
        // The classic on-device transcriber stumble: an immediately-repeated
        // helper word. "what time is is it" must still be the time question.
        #expect(LocalInstantAnswers.match(query: "what time is is it") == .currentTime)
        #expect(LocalInstantAnswers.match(query: "what what time is it") == .currentTime)
        #expect(LocalInstantAnswers.match(query: "what day is is it today") == .dayOfWeek)
    }

    @Test func casingAndPunctuationAreIgnored() {
        #expect(LocalInstantAnswers.match(query: "  WHAT TIME IS IT!!  ") == .currentTime)
        #expect(LocalInstantAnswers.match(query: "What's The Date?") == .todaysDate)
    }

    // MARK: - Near-misses that MUST NOT match (extra intent → the real brains)

    @Test func timeInAnotherPlaceDoesNotMatch() {
        // A location is additional intent — the brains must handle it, not a
        // canned local clock. This is the load-bearing narrowness rule.
        #expect(LocalInstantAnswers.match(query: "what time is it in tokyo") == nil)
        #expect(LocalInstantAnswers.match(query: "what time is it in london right now") == nil)
    }

    @Test func dateOfSomethingDoesNotMatch() {
        // "the date of the meeting" is a real question about a subject, not
        // today's date.
        #expect(LocalInstantAnswers.match(query: "what's the date of the meeting") == nil)
        #expect(LocalInstantAnswers.match(query: "what day should we ship") == nil)
        #expect(LocalInstantAnswers.match(query: "what day is the standup on") == nil)
    }

    @Test func timeRelatedButNotTheBareFactDoesNotMatch() {
        #expect(LocalInstantAnswers.match(query: "what time should i leave") == nil)
        #expect(LocalInstantAnswers.match(query: "how much time do i have") == nil)
        #expect(LocalInstantAnswers.match(query: "set a timer for ten minutes") == nil)
        #expect(LocalInstantAnswers.match(query: "what time zone am i in") == nil)
    }

    @Test func emptyOrUnrelatedDoesNotMatch() {
        #expect(LocalInstantAnswers.match(query: "") == nil)
        #expect(LocalInstantAnswers.match(query: "   ") == nil)
        #expect(LocalInstantAnswers.match(query: "restart the dev server") == nil)
        #expect(LocalInstantAnswers.match(query: "what does this error mean") == nil)
    }

    // MARK: - Composer formatting (deterministic clock/calendar injection)

    /// A fixed UTC calendar so composed strings are stable regardless of the
    /// machine's locale/time zone under test.
    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Builds a Date at the given UTC wall-clock for composer tests.
    private static func dateAt(
        year: Int, month: Int, day: Int, hour: Int, minute: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")!
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func composesTimeForTheEar() {
        let calendar = Self.fixedCalendar()
        // 10:12 → "it's ten twelve pm."
        let afternoon = Self.dateAt(year: 2026, month: 7, day: 3, hour: 22, minute: 12)
        #expect(LocalInstantAnswers.compose(.currentTime, now: afternoon, calendar: calendar)
                == "it's ten twelve pm.")

        // 9:05 → single-digit minute gets a spoken "oh".
        let morning = Self.dateAt(year: 2026, month: 7, day: 3, hour: 9, minute: 5)
        #expect(LocalInstantAnswers.compose(.currentTime, now: morning, calendar: calendar)
                == "it's nine oh five am.")

        // On the hour drops the minutes entirely.
        let onTheHour = Self.dateAt(year: 2026, month: 7, day: 3, hour: 15, minute: 0)
        #expect(LocalInstantAnswers.compose(.currentTime, now: onTheHour, calendar: calendar)
                == "it's three pm.")
    }

    @Test func composesNoonAndMidnightByName() {
        let calendar = Self.fixedCalendar()
        let noon = Self.dateAt(year: 2026, month: 7, day: 3, hour: 12, minute: 0)
        #expect(LocalInstantAnswers.compose(.currentTime, now: noon, calendar: calendar)
                == "it's noon.")
        let midnight = Self.dateAt(year: 2026, month: 7, day: 3, hour: 0, minute: 0)
        #expect(LocalInstantAnswers.compose(.currentTime, now: midnight, calendar: calendar)
                == "it's midnight.")
        // 12:01 am must NOT be "midnight" — it's past the landmark.
        let pastMidnight = Self.dateAt(year: 2026, month: 7, day: 3, hour: 0, minute: 1)
        #expect(LocalInstantAnswers.compose(.currentTime, now: pastMidnight, calendar: calendar)
                == "it's twelve oh one am.")
    }

    @Test func composesDateAndWeekday() {
        let calendar = Self.fixedCalendar()
        // 2026-07-03 is a Friday.
        let friday = Self.dateAt(year: 2026, month: 7, day: 3, hour: 14, minute: 0)
        #expect(LocalInstantAnswers.compose(.dayOfWeek, now: friday, calendar: calendar)
                == "it's friday.")
        #expect(LocalInstantAnswers.compose(.todaysDate, now: friday, calendar: calendar)
                == "it's friday, july third.")

        // An ordinal in the twenties: 2026-07-21 is a Tuesday.
        let twentyFirst = Self.dateAt(year: 2026, month: 7, day: 21, hour: 9, minute: 0)
        #expect(LocalInstantAnswers.compose(.todaysDate, now: twentyFirst, calendar: calendar)
                == "it's tuesday, july twenty first.")
    }

    @Test func composedAnswersAreCasualLowercase() {
        // Vidi's register: all lowercase, ends with a period, no digits/symbols
        // that read oddly aloud.
        let calendar = Self.fixedCalendar()
        let sample = Self.dateAt(year: 2026, month: 7, day: 3, hour: 22, minute: 12)
        for kind in [LocalInstantAnswers.InstantAnswerKind.currentTime, .todaysDate, .dayOfWeek] {
            let spoken = LocalInstantAnswers.compose(kind, now: sample, calendar: calendar)
            #expect(spoken == spoken.lowercased())
            #expect(spoken.hasPrefix("it's "))
            #expect(spoken.hasSuffix("."))
            #expect(!spoken.contains(":"))
            #expect(spoken.rangeOfCharacter(from: .decimalDigits) == nil)
        }
    }
}
