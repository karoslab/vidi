//
//  ScreenContextTests.swift
//  vidiTests
//
//  Covers the Orca accessibility-tree-first port: the pure prompt-block
//  formatter, the per-turn vision system-prompt composition, the capability
//  contract shape, and a regression guard for the (pre-existing) screenshot
//  payload-eviction guarantee. None of these touch the Accessibility
//  permission — the AX read itself (AccessibilityScreenContextProvider) needs
//  TCC and a real frontmost app, so it's covered by the manual-verification
//  note in the PR, not a fake test here.
//

import Foundation
import Testing
@testable import Vidi

struct ScreenContextFormattingTests {

    @Test func emitsAppWindowFocusAndControls() {
        let block = ScreenContextFormatting.promptBlock(
            appName: "Safari",
            windowTitle: "Inbox (3) - Gmail",
            focusedElement: "textfield \"Search mail\"",
            controls: ["button \"Compose\"", "button \"Send\"", "link \"Sign out\""]
        )
        #expect(block.contains("app: Safari — window: \"Inbox (3) - Gmail\""))
        #expect(block.contains("focused: textfield \"Search mail\""))
        #expect(block.contains("controls: button \"Compose\", button \"Send\", link \"Sign out\""))
        // The header tells the brain the screenshot wins on disagreement.
        #expect(block.lowercased().contains("screenshot is authoritative"))
    }

    @Test func omitsMissingWindowFocusAndControls() {
        let block = ScreenContextFormatting.promptBlock(
            appName: "Finder",
            windowTitle: nil,
            focusedElement: nil,
            controls: []
        )
        #expect(block.contains("app: Finder"))
        #expect(!block.contains("window:"))
        #expect(!block.contains("focused:"))
        #expect(!block.contains("controls:"))
    }

    @Test func capsControlsAndDropsBlanks() {
        let many = (1...20).map { "button \"b\($0)\"" } + ["   ", ""]
        let block = ScreenContextFormatting.promptBlock(
            appName: "X",
            windowTitle: "",
            focusedElement: "",
            controls: many
        )
        // Empty windowTitle/focusedElement are treated as absent.
        #expect(!block.contains("window:"))
        #expect(!block.contains("focused:"))
        let controlsLine = block.split(separator: "\n").first { $0.hasPrefix("controls:") }
        let renderedCount = controlsLine?.components(separatedBy: ", ").count ?? 0
        #expect(renderedCount == ScreenContextFormatting.maximumControls)
    }

    @Test func frontmostContextRoundTripsThroughBlock() {
        let context = FrontmostAppContext(
            appName: "Terminal",
            windowTitle: "zsh",
            focusedElement: nil,
            controls: ["button \"Clear\""]
        )
        let block = context.promptContextBlock()
        #expect(block.contains("app: Terminal — window: \"zsh\""))
        #expect(block.contains("controls: button \"Clear\""))
    }
}

@MainActor
struct ScreenContextCapabilityTests {

    // A hypothetical future provider (sidecar/Windows) slots in behind the
    // protocol without touching call sites — this proves the contract is the
    // only coupling point.
    private struct StubProvider: ScreenContextProviding {
        let capabilities: ScreenContextCapabilities
        let context: FrontmostAppContext?
        func frontmostContext() -> FrontmostAppContext? { context }
    }

    @Test func providerNegotiatesOnCapabilitiesNotConcreteType() {
        let axOnly = StubProvider(
            capabilities: ScreenContextCapabilities(accessibilityTree: true, screenshot: false),
            context: FrontmostAppContext(appName: "A", windowTitle: nil, focusedElement: nil, controls: [])
        )
        let provider: ScreenContextProviding = axOnly
        #expect(provider.capabilities.accessibilityTree)
        #expect(!provider.capabilities.screenshot)
        #expect(provider.frontmostContext()?.appName == "A")
    }

    @Test func failClosedProviderReturnsNilContext() {
        let denied = StubProvider(
            capabilities: ScreenContextCapabilities(accessibilityTree: false, screenshot: true),
            context: nil
        )
        // Fail-open contract: nil context means "no cheap grounding this turn",
        // the caller proceeds on the screenshot alone.
        #expect(denied.frontmostContext() == nil)
    }
}

@MainActor
struct VisionSystemPromptCompositionTests {

    private let base = "BASE PROMPT"

    @Test func allNilBlocksReturnsBaseUnchanged() {
        let composed = CompanionManager.composeVisionSystemPrompt(
            base: base, additionalBlocks: [nil, nil]
        )
        #expect(composed == base)
    }

    @Test func preservesLegacyCrossBrainOnlyShape() {
        // Before the AX port the composition was `base + "\n\n" + crossBrain`.
        // With screen context absent (nil) the output must be byte-identical.
        let composed = CompanionManager.composeVisionSystemPrompt(
            base: base, additionalBlocks: [nil, "CROSS BRAIN"]
        )
        #expect(composed == base + "\n\n" + "CROSS BRAIN")
    }

    @Test func screenContextPrecedesCrossBrain() {
        let composed = CompanionManager.composeVisionSystemPrompt(
            base: base, additionalBlocks: ["SCREEN", "CROSS BRAIN"]
        )
        #expect(composed == base + "\n\n" + "SCREEN" + "\n\n" + "CROSS BRAIN")
    }

    @Test func dropsEmptyAndWhitespaceBlocks() {
        let composed = CompanionManager.composeVisionSystemPrompt(
            base: base, additionalBlocks: ["   ", "SCREEN", ""]
        )
        #expect(composed == base + "\n\n" + "SCREEN")
    }
}

struct ScreenshotPayloadEvictionTests {

    // Regression guard for the (pre-existing) eviction guarantee that this PR
    // relies on and documents: Vidi's retained conversation history is TEXT
    // ONLY — the per-turn screenshot bytes are never persisted back into it
    // (Orca's withoutScreenshotPayload outcome). If someone later widens
    // VisionExchange to carry image data, this test fails loudly.
    @Test func retainedExchangeCarriesNoImageBytes() throws {
        let exchange = VisionHistoryStore.VisionExchange(
            userTranscript: "what app is this",
            assistantResponse: "that's Safari"
        )
        let data = try JSONEncoder().encode(exchange)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(json.keys) == ["userTranscript", "assistantResponse"])
        for forbidden in ["image", "images", "data", "base64", "imageData", "screenshot"] {
            #expect(json[forbidden] == nil)
        }
    }
}
