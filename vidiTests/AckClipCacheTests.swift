//
//  AckClipCacheTests.swift
//  vidiTests
//
//  Verifies the pure, filesystem-safe cache-file naming for acknowledgment
//  clips (Workstream A2). The disk I/O and network fetch are exercised at
//  runtime, not in unit tests; the deterministic slug is what must be pinned so
//  a cached clip is always found again on the next launch.
//

import Testing
@testable import Vidi

@MainActor
struct AckClipCacheTests {

    @Test func cacheFileNameIsLowercaseSlugWithMp3Extension() {
        #expect(AckClipCache.cacheFileName(for: "On it.") == "on_it.mp3")
        #expect(AckClipCache.cacheFileName(for: "One sec.") == "one_sec.mp3")
        #expect(AckClipCache.cacheFileName(for: "Let me look.") == "let_me_look.mp3")
        #expect(AckClipCache.cacheFileName(for: "Got it.") == "got_it.mp3")
    }

    @Test func cacheFileNameCollapsesAndTrimsPunctuationRuns() {
        // Leading/trailing/interior punctuation runs collapse to single
        // underscores and never leak into the file name.
        #expect(AckClipCache.cacheFileName(for: "  Hey!!  There??  ") == "hey_there.mp3")
    }

    @Test func acknowledgmentPhrasesEachProduceADistinctFileName() {
        let fileNames = AckClipCache.acknowledgmentPhrases.map {
            AckClipCache.cacheFileName(for: $0)
        }
        #expect(Set(fileNames).count == fileNames.count)
    }
}
