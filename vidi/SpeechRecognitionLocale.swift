//
//  SpeechRecognitionLocale.swift
//  vidi
//
//  Pure decision logic (no Speech framework, no audio, no I/O side effects — the
//  keyterms parse takes the already-read file text) for two accent-tuning levers
//  Vidi's speech paths share:
//
//   1. LOCALE choice. The owner speaks Indian English, and Apple's default
//      recognizer locale (en-US / system) routinely mishears their accent
//      ("What time is is it?", wake heard as "Video"/"Annette"). Preferring
//      en-IN (English, India) is the big lever. But the locale is only usable if
//      (a) `SFSpeechRecognizer(locale:)` exists for it AND — where on-device is
//      REQUIRED (the ambient path never lets idle audio leave the Mac; the PTT
//      path keeps whatever on-device posture it has today) — (b) that locale has
//      an ON-DEVICE asset installed. If en-IN can't satisfy the on-device
//      requirement on this machine, we fall back to en-US on-device rather than
//      silently sending audio to Apple's servers. `chooseLocale` encodes exactly
//      that decision so it is unit-testable without a recognizer.
//
//   2. CONTEXTUAL keyterms from a user-editable file. `parseKeytermsFile` turns
//      the optional `~/Library/Application Support/Vidi/speech-keyterms.txt`
//      (one term per line, `#` comments, blank lines ignored) into a clean list
//      the recognizer biases toward via `contextualStrings`.
//
//  Both are pure so `SpeechRecognitionLocaleTests` can pin the accent behavior
//  without a microphone or the Speech framework.
//

import Foundation

/// The result of resolving which recognition locale a speech path should use,
/// given what the user requested, what recognizers exist, and whether on-device
/// recognition is required and available for the requested locale.
struct SpeechRecognitionLocaleDecision: Equatable {
    /// The BCP-47 identifier the path should construct its `SFSpeechRecognizer`
    /// with (e.g. "en-IN" or "en-US").
    let chosenLocaleIdentifier: String

    /// True when the chosen locale differs from the one that was requested
    /// because the requested one could not satisfy the on-device requirement —
    /// the caller logs the exact fallback line when this is set.
    let didFallBackFromRequestedLocale: Bool

    /// The identifier that was requested before any fallback, for the log line.
    let requestedLocaleIdentifier: String
}

enum SpeechRecognitionLocale {

    /// The accent lever's default: prefer Indian English. Used when the
    /// `vidiSpeechLocale` override is absent or set to the sentinel "auto".
    static let indianEnglishLocaleIdentifier = "en-IN"

    /// The on-device fallback locale. This is the one locale that ships an
    /// on-device asset on effectively every Mac, so it is the safe landing spot
    /// when a preferred locale (en-IN) has no on-device asset installed and the
    /// path requires on-device recognition.
    static let onDeviceFallbackLocaleIdentifier = "en-US"

    /// The UserDefaults key for the optional user override, read the same way as
    /// `vidiVoiceProcessingBargeIn` / `vidiWakeCueEnabled`. Value is either the
    /// sentinel "auto" (or absent) → prefer en-IN, or an explicit BCP-47
    /// identifier (e.g. "en-GB") the user wants instead.
    static let localeOverrideDefaultsKey = "vidiSpeechLocale"

    /// The sentinel value that means "use Vidi's preferred locale (en-IN)".
    static let automaticLocaleSentinel = "auto"

    /// Resolve the identifier the caller should TRY first from the raw override
    /// value (as read from UserDefaults). Absent / blank / "auto" → the Indian
    /// English preference; any other value is taken verbatim as an explicit
    /// request. Pure so the override handling is unit-testable.
    static func requestedLocaleIdentifier(fromOverrideValue overrideValue: String?) -> String {
        guard let overrideValue else { return indianEnglishLocaleIdentifier }
        let trimmedOverrideValue = overrideValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOverrideValue.isEmpty else { return indianEnglishLocaleIdentifier }
        if trimmedOverrideValue.caseInsensitiveCompare(automaticLocaleSentinel) == .orderedSame {
            return indianEnglishLocaleIdentifier
        }
        return trimmedOverrideValue
    }

    /// Decide which locale a speech path should actually use.
    ///
    /// - Parameters:
    ///   - requestedLocaleIdentifier: what the caller wants first (from
    ///     `requestedLocaleIdentifier(fromOverrideValue:)`).
    ///   - requestedLocaleHasRecognizer: whether `SFSpeechRecognizer(locale:)`
    ///     returned non-nil for the requested locale (locale is supported at all).
    ///   - requestedLocaleSupportsOnDevice: whether the requested locale's
    ///     recognizer reports `supportsOnDeviceRecognition == true`.
    ///   - requiresOnDeviceRecognition: whether THIS path must run on-device
    ///     (true for the ambient/idle path — audio must never leave the Mac;
    ///     the PTT path passes its own current posture).
    ///
    /// The requested locale is kept only when it both has a recognizer AND, when
    /// on-device is required, supports on-device. Otherwise the decision falls
    /// back to `onDeviceFallbackLocaleIdentifier` (en-US), which the caller then
    /// runs on-device. When on-device is NOT required, a supported requested
    /// locale is kept even without an on-device asset (server recognition is
    /// acceptable for that path's posture).
    static func chooseLocale(
        requestedLocaleIdentifier: String,
        requestedLocaleHasRecognizer: Bool,
        requestedLocaleSupportsOnDevice: Bool,
        requiresOnDeviceRecognition: Bool
    ) -> SpeechRecognitionLocaleDecision {
        let requestedLocaleIsUsable: Bool
        if !requestedLocaleHasRecognizer {
            requestedLocaleIsUsable = false
        } else if requiresOnDeviceRecognition {
            requestedLocaleIsUsable = requestedLocaleSupportsOnDevice
        } else {
            requestedLocaleIsUsable = true
        }

        if requestedLocaleIsUsable {
            return SpeechRecognitionLocaleDecision(
                chosenLocaleIdentifier: requestedLocaleIdentifier,
                didFallBackFromRequestedLocale: false,
                requestedLocaleIdentifier: requestedLocaleIdentifier
            )
        }

        return SpeechRecognitionLocaleDecision(
            chosenLocaleIdentifier: onDeviceFallbackLocaleIdentifier,
            didFallBackFromRequestedLocale: requestedLocaleIdentifier != onDeviceFallbackLocaleIdentifier,
            requestedLocaleIdentifier: requestedLocaleIdentifier
        )
    }

    // MARK: - Keyterms file

    /// The absolute path of the optional user-editable keyterms file
    /// (`~/Library/Application Support/Vidi/speech-keyterms.txt`, one term per
    /// line, `#` comments). A missing file is fine (returns an empty list); the
    /// caller merges whatever this yields with the built-in vocabulary.
    static let userKeytermsFileURL: URL = {
        let applicationSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return applicationSupportDirectory
            .appendingPathComponent("Vidi", isDirectory: true)
            .appendingPathComponent("speech-keyterms.txt", isDirectory: false)
    }()

    /// Parse the raw text of the keyterms file into a clean, de-duplicated list:
    /// one term per line, `#` starts a comment (the whole line is dropped if it
    /// begins with `#` after trimming; an inline `#` also truncates the term),
    /// blank lines ignored, surrounding whitespace trimmed. Pure — the caller
    /// reads the file (or gets nil for a missing file) and hands the text here.
    static func parseKeytermsFile(contents fileContents: String?) -> [String] {
        guard let fileContents else { return [] }

        var seenNormalizedTerms = Set<String>()
        var orderedTerms: [String] = []

        for rawLine in fileContents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // Drop anything from an inline `#` onward so a trailing comment on a
            // term line doesn't leak into the term.
            let lineWithoutComment: Substring
            if let commentStartIndex = rawLine.firstIndex(of: "#") {
                lineWithoutComment = rawLine[rawLine.startIndex..<commentStartIndex]
            } else {
                lineWithoutComment = rawLine
            }

            let trimmedTerm = lineWithoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmedTerm.isEmpty else { continue }

            let normalizedTerm = trimmedTerm.lowercased()
            guard !seenNormalizedTerms.contains(normalizedTerm) else { continue }
            seenNormalizedTerms.insert(normalizedTerm)
            orderedTerms.append(trimmedTerm)
        }

        return orderedTerms
    }

    /// Read + parse the user keyterms file, tolerating a missing file. All I/O
    /// failures collapse to an empty list — a missing or unreadable file must
    /// never break speech setup. (Thin impure wrapper over `parseKeytermsFile`.)
    static func loadUserKeyterms() -> [String] {
        let fileContents = try? String(contentsOf: userKeytermsFileURL, encoding: .utf8)
        return parseKeytermsFile(contents: fileContents)
    }
}
