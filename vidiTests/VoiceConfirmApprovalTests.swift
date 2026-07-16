//
//  VoiceConfirmApprovalTests.swift
//  vidiTests
//
//  Pins the B1 approval parse + nonce lifecycle (VoiceConfirmApproval), the app
//  half of vidi-chat's confirm nonce gate. No hardware — pure decision logic.
//

import XCTest
@testable import Vidi

final class VoiceConfirmApprovalTests: XCTestCase {

    // MARK: pendingConfirm parse

    func testParsesWellFormedPendingConfirm() {
        let event: [String: Any] = [
            "type": "result",
            "text": "I'm about to send an email to Sam — say confirm to go ahead.",
            "pendingConfirm": ["description": "send an email to Sam", "nonce": "abc123XYZ_-"],
        ]
        let parsed = VoiceConfirmApproval.pendingConfirm(fromResultEvent: event)
        XCTAssertEqual(parsed, VoiceConfirmApproval.PendingConfirm(
            description: "send an email to Sam", nonce: "abc123XYZ_-"))
    }

    func testNoPendingConfirmFieldReturnsNil() {
        let event: [String: Any] = ["type": "result", "text": "it's 10:12 pm."]
        XCTAssertNil(VoiceConfirmApproval.pendingConfirm(fromResultEvent: event))
    }

    // Fail closed: a partial/blank object must NOT yield a confirm — storing a
    // blank nonce would later be POSTed as a bogus approval.
    func testMalformedPendingConfirmFailsClosed() {
        let missingNonce: [String: Any] = ["pendingConfirm": ["description": "send an email"]]
        let missingDescription: [String: Any] = ["pendingConfirm": ["nonce": "n0nce"]]
        let blankNonce: [String: Any] = ["pendingConfirm": ["description": "x", "nonce": ""]]
        let blankDescription: [String: Any] = ["pendingConfirm": ["description": "   ", "nonce": "n"]]
        let wrongType: [String: Any] = ["pendingConfirm": "not-an-object"]
        XCTAssertNil(VoiceConfirmApproval.pendingConfirm(fromResultEvent: missingNonce))
        XCTAssertNil(VoiceConfirmApproval.pendingConfirm(fromResultEvent: missingDescription))
        XCTAssertNil(VoiceConfirmApproval.pendingConfirm(fromResultEvent: blankNonce))
        XCTAssertNil(VoiceConfirmApproval.pendingConfirm(fromResultEvent: blankDescription))
        XCTAssertNil(VoiceConfirmApproval.pendingConfirm(fromResultEvent: wrongType))
    }

    // MARK: nonce lifecycle

    func testNonceToHoldSetsOnParkAndClearsOnResolve() {
        // Turn parks an action → hold its nonce.
        let parked: [String: Any] = [
            "type": "result", "text": "confirm?",
            "pendingConfirm": ["description": "create a calendar event", "nonce": "keepme"],
        ]
        XCTAssertEqual(VoiceConfirmApproval.nonceToHold(afterResultEvent: parked), "keepme")

        // A later turn with nothing parked (approved / cancelled / expired, or an
        // ordinary answer) → clear.
        let resolved: [String: Any] = ["type": "result", "text": "Done."]
        XCTAssertNil(VoiceConfirmApproval.nonceToHold(afterResultEvent: resolved))
    }

    func testNonceToHoldSupersedesWithNewestParkedAction() {
        let first: [String: Any] = ["pendingConfirm": ["description": "a", "nonce": "first"]]
        let second: [String: Any] = ["pendingConfirm": ["description": "b", "nonce": "second"]]
        XCTAssertEqual(VoiceConfirmApproval.nonceToHold(afterResultEvent: first), "first")
        // Newest parked action wins (depth-1 confirm slot, newest replaces older).
        XCTAssertEqual(VoiceConfirmApproval.nonceToHold(afterResultEvent: second), "second")
    }

    // MARK: background-turn nonce preservation (barge-in)

    // A turn that was barged-in and moved to the background slot can STILL park a
    // risky action in its final result. That nonce must be stored so a later
    // "vidi, confirm" finds it — the barge-in nonce-loss bug this fixes.
    func testBackgroundResultWithParkedActionStoresItsNonce() {
        let parked: [String: Any] = [
            "type": "result", "text": "confirm?",
            "pendingConfirm": ["description": "send an email to Sam", "nonce": "bg-parked"],
        ]
        XCTAssertEqual(
            VoiceConfirmApproval.nonceToHoldAfterBackgroundResultEvent(
                currentlyHeldNonce: nil, event: parked),
            "bg-parked")
    }

    // SET-ONLY: a background result with NO pendingConfirm must NOT clear a nonce
    // a newer foreground command has already parked (the clobber the
    // foreground-only store was guarding against).
    func testBackgroundResultWithoutParkedActionKeepsHeldNonce() {
        let ordinary: [String: Any] = ["type": "result", "text": "Done."]
        XCTAssertEqual(
            VoiceConfirmApproval.nonceToHoldAfterBackgroundResultEvent(
                currentlyHeldNonce: "foreground-parked", event: ordinary),
            "foreground-parked")
        // And with nothing held, a non-parking background result holds nothing.
        XCTAssertNil(
            VoiceConfirmApproval.nonceToHoldAfterBackgroundResultEvent(
                currentlyHeldNonce: nil, event: ordinary))
    }

    // A background result that parks a fresh action supersedes an older held
    // nonce (same newest-wins semantics as the foreground path).
    func testBackgroundParkedActionSupersedesHeldNonce() {
        let parked: [String: Any] = [
            "pendingConfirm": ["description": "delete a file", "nonce": "bg-new"],
        ]
        XCTAssertEqual(
            VoiceConfirmApproval.nonceToHoldAfterBackgroundResultEvent(
                currentlyHeldNonce: "older-held", event: parked),
            "bg-new")
    }

    // Fail closed: a malformed pendingConfirm on a background result is treated as
    // "nothing parked", so it keeps (never clobbers, never stores a blank) the
    // held nonce.
    func testBackgroundResultWithMalformedPendingConfirmKeepsHeldNonce() {
        let blankNonce: [String: Any] = ["pendingConfirm": ["description": "x", "nonce": ""]]
        XCTAssertEqual(
            VoiceConfirmApproval.nonceToHoldAfterBackgroundResultEvent(
                currentlyHeldNonce: "held", event: blankNonce),
            "held")
    }
}
