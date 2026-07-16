//
//  VidiAnalytics.swift
//  vidi
//
//  Analytics intentionally disabled — local personal build. Method surface kept so call sites stay untouched.
//

import Foundation

enum VidiAnalytics {

    // MARK: - Setup

    static func configure() {}

    // MARK: - App Lifecycle

    static func trackAppOpened() {}

    // MARK: - Onboarding

    static func trackOnboardingStarted() {}

    static func trackOnboardingReplayed() {}

    static func trackOnboardingVideoCompleted() {}

    static func trackOnboardingDemoTriggered() {}

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {}

    static func trackPermissionGranted(permission: String) {}

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {}

    static func trackPushToTalkReleased() {}

    static func trackUserMessageSent(transcript: String) {}

    static func trackAIResponseReceived(response: String) {}

    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - Errors

    static func trackResponseError(error: String) {}

    static func trackTTSError(error: String) {}
}
