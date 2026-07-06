import XCTest
@testable import AgentBabysitterCore

final class ReleaseNotesDigestTests: XCTestCase {

    /// The exact style of this app's release notes: bold-lead bullets under
    /// "## Fixed"/"## Added" headers, plus a trailer paragraph.
    func testRealReleaseBodyYieldsHeadlines() {
        let body = """
        Two user-reported fixes.

        ## Fixed
        - **Long-running tools no longer show as "needs your input."** In the transcript, \
        a permission prompt and a slow tool look identical, so any build longer than ~10 \
        seconds flipped the session to 🟡 while Claude was actually working.
        - **The app icon now appears on Notification Center banners.** The app shipped \
        only a legacy .icns.

        All 285 Core tests pass. Universal binary (Apple Silicon + Intel).
        """
        XCTAssertEqual(ReleaseNotesDigest.digest(markdown: body), """
        • Long-running tools no longer show as "needs your input."
        • The app icon now appears on Notification Center banners.
        """.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testCapsItemCountAndLength() {
        let body = (1...5).map { "- item \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ReleaseNotesDigest.digest(markdown: body),
                       "• item 1\n• item 2\n• item 3")

        let long = "- " + String(repeating: "x", count: 300)
        let digest = ReleaseNotesDigest.digest(markdown: long, maxItemLength: 100)
        XCTAssertEqual(digest?.count, 2 + 100)  // "• " + 99 chars + ellipsis
        XCTAssertTrue(digest?.hasSuffix("…") == true)
    }

    func testStripsInlineMarkdown() {
        let body = "- Fixed `parse()` — see [the docs](https://example.com) for *details*"
        XCTAssertEqual(ReleaseNotesDigest.digest(markdown: body),
                       "• Fixed parse() — see the docs for details")
    }

    func testStarBulletsAndIndentedBulletsCount() {
        XCTAssertEqual(ReleaseNotesDigest.digest(markdown: "* starred\n  - nested"),
                       "• starred\n• nested")
    }

    func testHeadersAndProseAreIgnored() {
        XCTAssertNil(ReleaseNotesDigest.digest(markdown: "## Fixed\nJust prose, no bullets."))
        XCTAssertNil(ReleaseNotesDigest.digest(markdown: ""))
    }

    func testUnclosedBoldFallsBackToWholeLine() {
        XCTAssertEqual(ReleaseNotesDigest.digest(markdown: "- **oops unclosed bold"),
                       "• oops unclosed bold")
    }

    /// Bodies edited in GitHub's web UI arrive with CRLF line endings.
    func testCRLFBodiesParseClean() {
        XCTAssertEqual(ReleaseNotesDigest.digest(markdown: "## Fixed\r\n- one\r\n- two\r\n"),
                       "• one\n• two")
    }
}
