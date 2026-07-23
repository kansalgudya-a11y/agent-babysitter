import Foundation

/// What to CALL a usage window, derived from its length.
///
/// This lives in Core because BOTH layers name windows and they drifted: the
/// menu caption called Cursor's 30-day window a "billing cycle" while the
/// notification fired underneath it said "monthly limit". A user reading both
/// has no way to tell whether that is one window or two — and the app's whole
/// claim about limits is that it never guesses. Neither layer can own the
/// names (the menu can't be imported by the notification path and vice
/// versa), so the shared dependency of both is where the single source of
/// truth belongs.
///
/// The three forms differ only in typography, never in identity — every form
/// of a given window says the same word for it:
/// - `tag`     the compact form the narrow menu caption can afford
/// - `phrase`  the adjective form a notification sentence needs
///             ("at 82% of its ___ limit")
/// - `spoken`  the noun phrase for VoiceOver and prose tooltips
public struct UsageWindowName: Equatable, Sendable {
    public let tag: String
    public let phrase: String
    public let spoken: String

    /// Which of the user's two "show pace from N%" floors this window is
    /// gated by — the LONG one when true, the short one when false.
    ///
    /// This rides on the NAME rather than on a second length comparison, and
    /// that is the point: the two used to be separate numbers (names split at
    /// 2 days, the pace floor at 7), so a 3-day window would have been
    /// captioned "weekly" and spoken as "weekly window" while being gated by
    /// the slider labelled "Short window pace from" and documented as covering
    /// windows that refill within a day. Nothing publishes a 3-day window
    /// today — which is exactly why the split would have shipped unnoticed and
    /// misfired on whichever vendor introduced one. Now there is one boundary:
    /// a window is long when the row calls it "weekly" or "billing cycle", so
    /// the Preferences help can describe the split by the words the user can
    /// actually see on the row.
    public let isLong: Bool

    /// Boundaries follow the windows real agents publish, each verified in
    /// that agent's own data: Claude and Antigravity 300 minutes (5h), Manus
    /// 1440 (daily), Codex 10080 (weekly), Cursor 43200 (30-day billing
    /// cycle). The ranges are loose either side so a vendor nudging its window
    /// by an hour can't silently rename it.
    public static func forWindow(minutes: Int) -> UsageWindowName {
        switch minutes {
        case ..<361:
            return UsageWindowName(tag: "5h", phrase: "5-hour", spoken: "five hour window",
                                   isLong: false)
        case ..<(2 * 24 * 60):
            return UsageWindowName(tag: "daily", phrase: "daily", spoken: "daily quota",
                                   isLong: false)
        case ..<(8 * 24 * 60):
            return UsageWindowName(tag: "weekly", phrase: "weekly", spoken: "weekly window",
                                   isLong: true)
        default:
            return UsageWindowName(tag: "billing cycle", phrase: "billing cycle",
                                   spoken: "billing cycle", isLong: true)
        }
    }

    /// The 7-day window an agent can publish ALONGSIDE its primary one
    /// (Claude's seven_day beside its 5-hour, Codex's secondary). It is the
    /// same window as a 7-day primary and must be called the same thing: the
    /// caption used to hardcode "week" here while a Codex row one line away
    /// said "weekly" for an identical 10080 minutes.
    public static var secondaryWeekly: UsageWindowName { forWindow(minutes: 7 * 24 * 60) }
}
