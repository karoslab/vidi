//
//  SpeechRecognitionLocaleTests.swift
//  vidiTests
//
//  Pins the accent-tuning decisions that make Apple Speech understand the owner's
//  Indian-English accent better: (1) which recognition locale a speech path
//  chooses given what was requested, whether that locale has a recognizer, and
//  whether it can satisfy an on-device requirement; and (2) parsing the optional
//  user-editable keyterms file. Both are pure in `SpeechRecognitionLocale`, so
//  the behavior is testable without a microphone or the Speech framework.
//

import Testing
import Foundation
@testable import Vidi

struct SpeechRecognitionLocaleTests {

    // MARK: - Requested-locale resolution from the override value

    @Test func absentOverridePrefersIndianEnglish() {
        #expect(
            SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: nil)
                == "en-IN"
        )
    }

    @Test func autoSentinelPrefersIndianEnglish() {
        #expect(
            SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: "auto")
                == "en-IN"
        )
        // Case-insensitive + surrounding whitespace tolerated.
        #expect(
            SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: "  AUTO ")
                == "en-IN"
        )
    }

    @Test func blankOverridePrefersIndianEnglish() {
        #expect(
            SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: "   ")
                == "en-IN"
        )
    }

    @Test func explicitOverrideIsTakenVerbatim() {
        #expect(
            SpeechRecognitionLocale.requestedLocaleIdentifier(fromOverrideValue: "en-GB")
                == "en-GB"
        )
    }

    // MARK: - Locale choice: requested locale usable → kept

    @Test func keepsRequestedLocaleWhenItSupportsOnDeviceAndOnDeviceIsRequired() {
        // The good path once Apple ships the en-IN on-device asset: en-IN has a
        // recognizer AND on-device support, and the ambient path requires
        // on-device → en-IN is used, no fallback.
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: "en-IN",
            requestedLocaleHasRecognizer: true,
            requestedLocaleSupportsOnDevice: true,
            requiresOnDeviceRecognition: true
        )
        #expect(decision.chosenLocaleIdentifier == "en-IN")
        #expect(decision.didFallBackFromRequestedLocale == false)
        #expect(decision.requestedLocaleIdentifier == "en-IN")
    }

    @Test func keepsRequestedLocaleWithoutOnDeviceWhenOnDeviceIsNotRequired() {
        // A path that does NOT require on-device keeps a supported requested
        // locale even without an on-device asset (server recognition is within
        // that path's posture).
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: "en-IN",
            requestedLocaleHasRecognizer: true,
            requestedLocaleSupportsOnDevice: false,
            requiresOnDeviceRecognition: false
        )
        #expect(decision.chosenLocaleIdentifier == "en-IN")
        #expect(decision.didFallBackFromRequestedLocale == false)
    }

    // MARK: - Locale choice: fallback to en-US on-device

    @Test func fallsBackToEnUSWhenRequestedLocaleLacksOnDeviceAndOnDeviceRequired() {
        // THIS MACHINE'S REALITY (probed 2026-07-03): en-IN has a recognizer but
        // supportsOnDeviceRecognition == false, and the ambient path requires
        // on-device → must fall back to en-US on-device, and flag the fallback so
        // the caller logs the exact "en-IN on-device unavailable" line.
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: "en-IN",
            requestedLocaleHasRecognizer: true,
            requestedLocaleSupportsOnDevice: false,
            requiresOnDeviceRecognition: true
        )
        #expect(decision.chosenLocaleIdentifier == "en-US")
        #expect(decision.didFallBackFromRequestedLocale == true)
        #expect(decision.requestedLocaleIdentifier == "en-IN")
    }

    @Test func fallsBackToEnUSWhenRequestedLocaleHasNoRecognizerAtAll() {
        // An unsupported locale (nil recognizer) falls back regardless of the
        // on-device requirement.
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: "zz-ZZ",
            requestedLocaleHasRecognizer: false,
            requestedLocaleSupportsOnDevice: false,
            requiresOnDeviceRecognition: false
        )
        #expect(decision.chosenLocaleIdentifier == "en-US")
        #expect(decision.didFallBackFromRequestedLocale == true)
    }

    @Test func fallbackFlagIsFalseWhenRequestedLocaleWasAlreadyEnUS() {
        // Requesting en-US that itself can't do on-device is still a "fallback"
        // to en-US, but there is no locale CHANGE to log — the flag stays false
        // so no misleading "fell back" line is emitted.
        let decision = SpeechRecognitionLocale.chooseLocale(
            requestedLocaleIdentifier: "en-US",
            requestedLocaleHasRecognizer: true,
            requestedLocaleSupportsOnDevice: false,
            requiresOnDeviceRecognition: true
        )
        #expect(decision.chosenLocaleIdentifier == "en-US")
        #expect(decision.didFallBackFromRequestedLocale == false)
    }

    // MARK: - Keyterms file parsing

    @Test func missingFileYieldsEmptyKeyterms() {
        #expect(SpeechRecognitionLocale.parseKeytermsFile(contents: nil) == [])
    }

    @Test func parsesOneTermPerLineTrimmingWhitespace() {
        let fileContents = "Tailscale\n  AirPods  \nNotes\n"
        #expect(
            SpeechRecognitionLocale.parseKeytermsFile(contents: fileContents)
                == ["Tailscale", "AirPods", "Notes"]
        )
    }

    @Test func ignoresBlankLinesAndFullLineComments() {
        let fileContents = """
        # my custom vidi vocabulary
        Tailscale

        # another comment
        Notes
        """
        #expect(
            SpeechRecognitionLocale.parseKeytermsFile(contents: fileContents)
                == ["Tailscale", "Notes"]
        )
    }

    @Test func stripsInlineTrailingComments() {
        let fileContents = "Tailscale # the VPN\nNotes#brain"
        #expect(
            SpeechRecognitionLocale.parseKeytermsFile(contents: fileContents)
                == ["Tailscale", "Notes"]
        )
    }

    @Test func deduplicatesCaseInsensitivelyPreservingFirstSpelling() {
        let fileContents = "Tailscale\ntailscale\nTAILSCALE\nNotes"
        #expect(
            SpeechRecognitionLocale.parseKeytermsFile(contents: fileContents)
                == ["Tailscale", "Notes"]
        )
    }
}
