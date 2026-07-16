//
//  LocalInstantAnswers.swift
//  vidi
//
//  Pure, unit-testable matcher + composer for the handful of trivial questions
//  Vidi can answer ON-DEVICE with ZERO network to any brain — current time,
//  today's date, and the day of the week. The owner's number-one felt complaint is
//  "she takes her sweet time": tonight's debug log showed "what time is it?" going
//  through the FULL vision pipeline (multi-display screenshots + GPT-5.2 + element
//  pointing) at ~6s, or the agent path at 13–16s. Those are facts the Mac already
//  knows. This type answers them from `Date()`/`Calendar` alone, so the only
//  latency left is one TTS round-trip (~1–2s) — still Vidi's real ara voice.
//
//  DELIBERATELY NARROW. The matcher returns a kind ONLY for the bare fact. The
//  instant ANY additional intent rides along — "what time is it in tokyo", "what's
//  the date of the meeting", "what day should we ship" — it must return nil so the
//  query falls through to the normal brains, which can actually reason about the
//  extra intent. A false positive here (answering a real question with a canned
//  local fact) is far worse than a false negative (missing a fast-path and paying
//  the normal latency), so every rule below errs toward NOT matching.
//
//  No audio, no networking, no UserDefaults, no Speech framework — only Foundation
//  Date/Calendar/DateComponents, injected by the caller so the decision is
//  testable without a clock. Same pure-decision pattern as VoiceCommandOutcome,
//  StreamedSpeechCoordinator, and SpokenSentenceChunker.
//

import Foundation

enum LocalInstantAnswers {

    /// The three on-device facts a trivial query can ask for. Anything outside
    /// this closed set is NOT an instant answer.
    enum InstantAnswerKind: Equatable {
        /// "what time is it" → the current wall-clock time.
        case currentTime
        /// "what's the date" / "what's today's date" → today's calendar date.
        case todaysDate
        /// "what day is it" → the day of the week (Monday, Tuesday, …).
        case dayOfWeek
    }

    // MARK: - Matcher

    /// Decides whether `query` is one of the trivial on-device facts, and which.
    /// Returns nil when the query is anything else — including a trivial fact
    /// that carries ANY additional intent (a location, a subject, a qualifier),
    /// which must go to the real brains.
    ///
    /// Case- and punctuation-tolerant, and tolerant of minor speech-to-text
    /// stumbles (a doubled helper word like "what time is is it"). The command
    /// text handed in here has already had any wake prefix ("vidi, …") stripped
    /// by the caller, so we match the bare question.
    static func match(query: String) -> InstantAnswerKind? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        // Each kind owns an exhaustive list of the EXACT normalized phrasings it
        // accepts. Exact-match (not "contains") is what keeps this narrow: a
        // query with any extra word — "what time is it in tokyo" — simply isn't
        // in the list, so it falls through to the brains instead of being
        // hijacked by a substring hit.
        if currentTimePhrasings.contains(normalizedQuery) {
            return .currentTime
        }
        if dayOfWeekPhrasings.contains(normalizedQuery) {
            return .dayOfWeek
        }
        if todaysDatePhrasings.contains(normalizedQuery) {
            return .todaysDate
        }
        return nil
    }

    /// The exact normalized phrasings that mean "what is the current time".
    /// Day-of-week phrasings are matched FIRST (in `match`) so "what day is it
    /// today" never lands here — this set deliberately excludes any "day"
    /// wording.
    private static let currentTimePhrasings: Set<String> = [
        "what time is it",
        "what time is it now",
        "what time is it right now",
        "whats the time",
        "whats the time now",
        "what is the time",
        "what is the time now",
        "time please",
        "the time please",
        "tell me the time",
        "do you have the time",
        "got the time",
        "current time",
        "the time",
        "what time",
        // Clipped / accented forms seen in the live debug log and Indian-English
        // cadence variants. All are bare-fact clippings that only ever mean "the
        // current time" — no extra intent rides along.
        "what time is",          // the 06:44 clip: "what time is?" (dropped "it")
        "what is time",
        "what is the time please",
        "whats time",
        "whats time now",
        "whats time is it",
        "time now",
        "the time now",
        "tell me time",
        "what the time",         // dropped "is", common accented clip
        "time",
    ]

    /// The exact normalized phrasings that mean "what is today's date". These
    /// all reference the DATE explicitly so they never collide with the bare
    /// day-of-week question.
    private static let todaysDatePhrasings: Set<String> = [
        "whats the date",
        "whats the date today",
        "whats todays date",
        "what is the date",
        "what is the date today",
        "what is todays date",
        "whats the date today please",
        "todays date",
        "the date",
        "what date is it",
        "what date is it today",
        "tell me the date",
        "tell me todays date",
        "whats the date please",
        "date please",
        // Clipped / accented date forms — all still reference the DATE, so no
        // collision with the bare day-of-week question, and no extra intent.
        "whats date",
        "whats date today",
        "what date",
        "what is date",
        "what is date today",
        "what date today",
        "date today",
        "whats the date now",
        "what todays date",      // dropped "is"
    ]

    /// The exact normalized phrasings that mean "what day of the week is it".
    /// "what day is it" is inherently about the weekday in casual speech; the
    /// date-specific questions above all say "date", so there is no overlap.
    private static let dayOfWeekPhrasings: Set<String> = [
        "what day is it",
        "what day is it today",
        "what day is today",
        "whats today",
        "what day of the week is it",
        "what day of the week is it today",
        "what is the day today",
        "what day",
        "which day is it",
        "which day is it today",
        // Clipped / accented day-of-week forms — the parallel clip of the "day"
        // question ("what day is" mirrors the "what time is" failure shape). All
        // are bare weekday questions with no extra intent.
        "what day is",           // parallel clip of "what time is"
        "whats the day",
        "whats day today",
        "what is day today",
        "which day",
        "what day today",
        "whats day",
        "day today",
    ]

    /// Normalizes a raw query for matching: lowercased, apostrophes/punctuation
    /// removed, whitespace collapsed, and a minor speech-to-text stumble (a word
    /// immediately repeated, like "what time is is it") de-duplicated. This is
    /// what makes the exact-phrasing sets tolerant of casing, punctuation, and
    /// small transcriber hiccups without widening them into substring matching.
    static func normalize(_ rawQuery: String) -> String {
        let lowercased = rawQuery.lowercased()

        // Delete apostrophes FIRST (both the straight ' and the curly ’ the
        // transcriber may emit) so a contraction collapses to one word:
        // "what's" → "whats", matching the phrasing sets. If we mapped the
        // apostrophe to a space like other punctuation, "what's" would become
        // the two words "what s" and never match.
        let apostrophesRemoved = lowercased.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        // Keep only letters, digits, and spaces. Every remaining punctuation
        // mark (a trailing "?" / "." the transcriber added, etc.) becomes a
        // space so it can't glue onto a word.
        let lettersDigitsAndSpaces = apostrophesRemoved.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        let punctuationStripped = String(lettersDigitsAndSpaces)

        // Collapse runs of whitespace and drop immediately-repeated words. A
        // doubled helper word ("is is", "the the") is the classic on-device STT
        // stumble; removing consecutive duplicates recovers the intended phrase
        // without loosening the match for genuinely different words.
        let words = punctuationStripped
            .split(separator: " ")
            .map(String.init)

        var deduplicatedWords: [String] = []
        for word in words {
            if deduplicatedWords.last == word {
                continue
            }
            deduplicatedWords.append(word)
        }

        return deduplicatedWords.joined(separator: " ")
    }

    // MARK: - Composer

    /// Composes the short, natural spoken answer for a matched kind in Vidi's
    /// casual voice register — all lowercase, warm, written for the ear (small
    /// numbers implied by the formatter, no symbols that read oddly aloud). The
    /// clock/calendar are injected so the output is deterministic under test.
    ///
    /// - `kind`: which fact to answer.
    /// - `now`: the instant to describe (defaults to `Date()` in production).
    /// - `calendar`: the calendar/time-zone to resolve `now` against (defaults
    ///   to the user's current calendar in production).
    static func compose(
        _ kind: InstantAnswerKind,
        now: Date = Date(),
        calendar: Calendar = Calendar.current
    ) -> String {
        switch kind {
        case .currentTime:
            return "it's \(spokenClockTime(now: now, calendar: calendar))."
        case .todaysDate:
            return "it's \(spokenDate(now: now, calendar: calendar))."
        case .dayOfWeek:
            return "it's \(spokenWeekday(now: now, calendar: calendar))."
        }
    }

    /// The wall-clock time as Vidi would say it: "ten twelve pm", "nine oh five
    /// am", "noon", "midnight". Written for the ear — the minutes are spoken as
    /// words (with a leading "oh" for single-digit minutes) and there are no
    /// digits or colons that read oddly through text-to-speech.
    private static func spokenClockTime(now: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let hour24 = components.hour ?? 0
        let minute = components.minute ?? 0

        // Special-case the two clock landmarks people say by name, not by digits.
        if hour24 == 0 && minute == 0 {
            return "midnight"
        }
        if hour24 == 12 && minute == 0 {
            return "noon"
        }

        let isAfternoonOrEvening = hour24 >= 12
        let meridiem = isAfternoonOrEvening ? "pm" : "am"

        // Convert 24-hour to a spoken 12-hour hour (0 and 12 both read as "twelve").
        let hour12 = {
            let mod = hour24 % 12
            return mod == 0 ? 12 : mod
        }()

        let spokenHour = numberSpokenAloud(hour12)

        if minute == 0 {
            // On the hour Vidi says "ten pm", not "ten zero zero pm".
            return "\(spokenHour) \(meridiem)"
        }
        if minute < 10 {
            // Single-digit minutes get a spoken leading "oh": "nine oh five pm".
            return "\(spokenHour) oh \(numberSpokenAloud(minute)) \(meridiem)"
        }
        return "\(spokenHour) \(numberSpokenAloud(minute)) \(meridiem)"
    }

    /// Today's date as a spoken phrase: "tuesday, july third". Weekday + month +
    /// ordinal day, all lowercase, no year (people asking "what's the date"
    /// almost always want the day, and the year reads as clutter aloud).
    private static func spokenDate(now: Date, calendar: Calendar) -> String {
        let weekday = spokenWeekday(now: now, calendar: calendar)
        let monthName = spokenMonthName(now: now, calendar: calendar)
        let dayOfMonth = calendar.component(.day, from: now)
        let ordinalDay = ordinalSpokenAloud(dayOfMonth)
        return "\(weekday), \(monthName) \(ordinalDay)"
    }

    /// The lowercase weekday name for `now` ("monday", "tuesday", …), resolved
    /// through the injected calendar's time zone.
    private static func spokenWeekday(now: Date, calendar: Calendar) -> String {
        // weekday is 1-based starting at Sunday, matching `weekdaySymbols`.
        let weekdayIndex = calendar.component(.weekday, from: now) - 1
        let symbols = calendar.weekdaySymbols
        guard weekdayIndex >= 0 && weekdayIndex < symbols.count else {
            return ""
        }
        return symbols[weekdayIndex].lowercased()
    }

    /// The lowercase month name for `now` ("january", "february", …).
    private static func spokenMonthName(now: Date, calendar: Calendar) -> String {
        let monthIndex = calendar.component(.month, from: now) - 1
        let symbols = calendar.monthSymbols
        guard monthIndex >= 0 && monthIndex < symbols.count else {
            return ""
        }
        return symbols[monthIndex].lowercased()
    }

    // MARK: - Number → spoken words

    /// The English words for 0–59, the only range these answers ever need (hours
    /// 1–12 and minutes 0–59). Spelled out because digits and symbols read oddly
    /// through text-to-speech — the same "write for the ear" rule the vision
    /// prompt follows ("spell out small numbers").
    private static func numberSpokenAloud(_ value: Int) -> String {
        let onesAndTeens = [
            "zero", "one", "two", "three", "four", "five", "six", "seven",
            "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
            "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        ]
        if value < onesAndTeens.count {
            return onesAndTeens[value]
        }

        let tens = ["", "", "twenty", "thirty", "forty", "fifty"]
        let tensDigit = value / 10
        let onesDigit = value % 10
        guard tensDigit < tens.count else {
            // Out of the range these answers ever produce; fall back to digits
            // rather than crash — unreachable for valid clock values.
            return String(value)
        }
        if onesDigit == 0 {
            return tens[tensDigit]
        }
        return "\(tens[tensDigit]) \(onesAndTeens[onesDigit])"
    }

    /// The English ordinal words for days 1–31 ("first", "second", … "thirty
    /// first"), spelled out for the ear.
    private static func ordinalSpokenAloud(_ dayOfMonth: Int) -> String {
        let ordinalOnesAndTeens = [
            "", "first", "second", "third", "fourth", "fifth", "sixth",
            "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
            "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
            "eighteenth", "nineteenth", "twentieth",
        ]
        if dayOfMonth >= 1 && dayOfMonth < ordinalOnesAndTeens.count {
            return ordinalOnesAndTeens[dayOfMonth]
        }
        if dayOfMonth == 30 {
            return "thirtieth"
        }
        // 21–29 and 31: "twenty first", "thirty first", etc. The tens word is
        // cardinal ("twenty"), the ones word ordinal ("first").
        let tensCardinal = dayOfMonth < 30 ? "twenty" : "thirty"
        let onesOrdinal = ordinalOnesAndTeens[dayOfMonth % 10]
        return "\(tensCardinal) \(onesOrdinal)"
    }
}
