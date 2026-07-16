//
//  SystemActionsAliasTests.swift
//  vidiTests
//
//  Pins the project-console alias parsing + name normalization that makes
//  "vidi, open My Console" resolve a web console URL instead of honestly-but-
//  uselessly reporting "I couldn't find an app called My Console". The file
//  parser and the name normalizer are pure, so they're testable without
//  touching NSWorkspace or the real ~/Library/Application Support file.
//

import Testing
import Foundation
@testable import Vidi

struct SystemActionsAliasTests {

    // MARK: - Name normalization (case- and space/hyphen-insensitive)

    @Test func normalizesCaseAndHyphens() {
        // "My Console", "my console", and "my-console" must all collapse to
        // one canonical key so any spoken form matches the alias table.
        #expect(SystemActions.normalizeAliasName("My Console") == "my console")
        #expect(SystemActions.normalizeAliasName("my console") == "my console")
        #expect(SystemActions.normalizeAliasName("my-console") == "my console")
        #expect(SystemActions.normalizeAliasName("MY-CONSOLE") == "my console")
    }

    @Test func collapsesAndTrimsWhitespace() {
        #expect(SystemActions.normalizeAliasName("  vidi   chat  ") == "vidi chat")
        #expect(SystemActions.normalizeAliasName("vidi-chat") == "vidi chat")
    }

    @Test func stripsTrailingPunctuationFromBatchTranscripts() {
        // Grok/Sarvam return punctuated transcripts, so "vidi, open My Console."
        // arrives at openApp as the spoken name "My Console." WITH a trailing
        // period. The normalizer must strip that so it still matches the
        // "my console" alias key instead of missing the table
        // and falling through to a useless "no app called My Console." error.
        #expect(SystemActions.normalizeAliasName("My Console.") == "my console")
        #expect(SystemActions.normalizeAliasName("my console.") == "my console")
        #expect(SystemActions.normalizeAliasName("Dashboard!") == "dashboard")
        #expect(SystemActions.normalizeAliasName("nightshift?") == "nightshift")
        // Leading punctuation is stripped too (belt-and-suspenders).
        #expect(SystemActions.normalizeAliasName("...my console") == "my console")
    }

    // MARK: - Alias file parsing

    @Test func parsesSimpleNameEqualsUrlLines() {
        let contents = """
        My Console = http://localhost:9000
        other = http://localhost:9001
        """
        let aliases = SystemActions.parseAliasFile(contents: contents)
        #expect(aliases["my console"] == "http://localhost:9000")
        #expect(aliases["other"] == "http://localhost:9001")
    }

    @Test func ignoresCommentsAndBlankLines() {
        let contents = """
        # this is a comment
        My Console = http://localhost:9000

        # another comment
        """
        let aliases = SystemActions.parseAliasFile(contents: contents)
        #expect(aliases.count == 1)
        #expect(aliases["my console"] == "http://localhost:9000")
    }

    @Test func normalizesNamesFromFileSameAsSpokenNames() {
        // A hyphenated name in the file must match a spoken "my console".
        let aliases = SystemActions.parseAliasFile(contents: "My-Console = http://localhost:9000")
        #expect(aliases["my console"] == "http://localhost:9000")
    }

    @Test func splitsOnFirstEqualsSoUrlQueryStringsSurvive() {
        // The URL itself may contain "=" in a query string; only the FIRST "="
        // separates name from url.
        let aliases = SystemActions.parseAliasFile(contents: "dash = http://localhost:9000/?a=1&b=2")
        #expect(aliases["dash"] == "http://localhost:9000/?a=1&b=2")
    }

    @Test func skipsMalformedLinesWithNoEqualsOrEmptyParts() {
        let contents = """
        no equals sign here
        = http://localhost:9000
        name =
        good = http://localhost:9002
        """
        let aliases = SystemActions.parseAliasFile(contents: contents)
        #expect(aliases.count == 1)
        #expect(aliases["good"] == "http://localhost:9002")
    }

    @Test func emptyFileParsesToEmptyMap() {
        #expect(SystemActions.parseAliasFile(contents: "").isEmpty)
    }
}
