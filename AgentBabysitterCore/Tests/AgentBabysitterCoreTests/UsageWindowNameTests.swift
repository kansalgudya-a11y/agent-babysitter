import XCTest
@testable import AgentBabysitterCore

/// The menu row and the notification banner both name windows. When they each
/// kept their own private table they drifted: a Cursor alert read "monthly
/// limit" under a row captioned "billing cycle". These tests pin the shared
/// table against the window lengths real agents actually publish.
final class UsageWindowNameTests: XCTestCase {

    /// Verified window_minutes from each agent's own data.
    private let realWindows: [(minutes: Int, tag: String)] = [
        (300, "5h"),          // Claude Code, Antigravity
        (1440, "daily"),      // Manus credit refresh
        (10080, "weekly"),    // Codex primary (secondary null)
        (43200, "billing cycle"),  // Cursor 30-day cycle
    ]

    func testRealAgentWindowsGetTheirOwnName() {
        for window in realWindows {
            XCTAssertEqual(UsageWindowName.forWindow(minutes: window.minutes).tag, window.tag)
        }
    }

    /// The three forms may differ in typography but never in identity: no
    /// window may be a "billing cycle" in one place and "monthly" in another.
    /// "5-hour"/"5h"/"five hour" is the one permitted spelling difference, so
    /// compare on digits-and-letters with the separators removed.
    func testEveryFormOfAWindowNamesTheSameThing() {
        func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "5 hour", with: "5h")
                .replacingOccurrences(of: "five hour", with: "5h")
                .replacingOccurrences(of: " window", with: "")
                .replacingOccurrences(of: " quota", with: "")
                .replacingOccurrences(of: " ", with: "")
        }
        for window in realWindows {
            let name = UsageWindowName.forWindow(minutes: window.minutes)
            XCTAssertEqual(normalize(name.tag), normalize(name.phrase), "\(window.minutes)")
            XCTAssertEqual(normalize(name.tag), normalize(name.spoken), "\(window.minutes)")
        }
    }

    /// The secondary 7-day window an agent publishes BESIDE its primary
    /// (Claude's seven_day, Codex's secondary) is the same window as a 7-day
    /// primary, so it must be called the same thing. The caption used to
    /// hardcode "week" for it while a Codex row in the same popover said
    /// "weekly" for an identical 10080 minutes.
    func testSecondaryWeeklyIsNamedLikeAnyOtherSevenDayWindow() {
        XCTAssertEqual(UsageWindowName.secondaryWeekly,
                       UsageWindowName.forWindow(minutes: 7 * 24 * 60))
        XCTAssertEqual(UsageWindowName.secondaryWeekly.tag, "weekly")
    }

    /// One boundary, not two: which pace-floor slider gates a window is
    /// derived from the window's NAME, so a window can never be captioned
    /// "weekly" while being governed by the slider labelled "Short window
    /// pace from". Asserted as the invariant rather than as a list of
    /// lengths, so retuning the name boundary moves both together or fails.
    func testLongWindowSplitFollowsTheNameAtEveryLength() {
        for minutes in stride(from: 5, through: 60 * 24 * 60, by: 5) {
            let name = UsageWindowName.forWindow(minutes: minutes)
            XCTAssertEqual(name.isLong, name.tag == "weekly" || name.tag == "billing cycle",
                           "\(minutes) minutes is named \"\(name.tag)\"")
        }
        // And the real agents land where the Preferences help says they do.
        XCTAssertFalse(UsageWindowName.forWindow(minutes: 300).isLong)    // Claude 5h
        XCTAssertFalse(UsageWindowName.forWindow(minutes: 1440).isLong)   // Manus daily
        XCTAssertTrue(UsageWindowName.forWindow(minutes: 10080).isLong)   // Codex weekly
        XCTAssertTrue(UsageWindowName.forWindow(minutes: 43200).isLong)   // Cursor cycle
    }

    /// Boundaries are loose either side on purpose: a vendor nudging its
    /// window by an hour must not silently rename it.
    func testBoundariesAreForgiving() {
        XCTAssertEqual(UsageWindowName.forWindow(minutes: 360).tag, "5h")
        XCTAssertEqual(UsageWindowName.forWindow(minutes: 361).tag, "daily")
        XCTAssertEqual(UsageWindowName.forWindow(minutes: 7 * 24 * 60 - 60).tag, "weekly")
        XCTAssertEqual(UsageWindowName.forWindow(minutes: 8 * 24 * 60).tag, "billing cycle")
    }
}
