//
//  PointTagStrippingTests.swift
//  vidiTests
//
//  Verifies that per-sentence POINT-tag stripping (Workstream A2) removes the
//  raw coordinate tag from any streamed sentence, wherever it appears, so the
//  tag is never spoken aloud. The full reply still reaches
//  parsePointingCoordinates afterward, so the pointing animation is unaffected.
//

import Foundation
import Testing
@testable import Vidi

@MainActor
struct PointTagStrippingTests {

    @Test func stripsTrailingPointTag() {
        let stripped = CompanionManager.stripPointTags(
            from: "click the run button. [POINT:100,200:run button]"
        )
        #expect(!stripped.contains("[POINT"))
        #expect(stripped.trimmingCharacters(in: .whitespaces) == "click the run button.")
    }

    @Test func stripsMidSentencePointTag() {
        let stripped = CompanionManager.stripPointTags(
            from: "look at [POINT:50,60:menu:screen2] the menu now."
        )
        #expect(!stripped.contains("[POINT"))
        #expect(stripped == "look at the menu now.")
    }

    @Test func stripsPointNoneTag() {
        let stripped = CompanionManager.stripPointTags(from: "here is your answer. [POINT:none]")
        #expect(!stripped.contains("[POINT"))
        #expect(stripped.trimmingCharacters(in: .whitespaces) == "here is your answer.")
    }

    @Test func leavesTagFreeTextUntouched() {
        let text = "no tag here at all."
        #expect(CompanionManager.stripPointTags(from: text) == text)
    }
}
