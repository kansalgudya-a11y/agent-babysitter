import Foundation

/// "Don't ping me between 22:00 and 08:00." Pure hour-window math so the app
/// can suppress notifications on a schedule; handles windows that wrap past
/// midnight (start > end).
public enum QuietHours {

    /// True when `now`'s local hour falls inside [startHour, endHour). A window
    /// like 22→8 wraps midnight; 9→17 doesn't. start == end means "never".
    public static func isQuiet(now: Date, startHour: Int, endHour: Int,
                               calendar: Calendar = .current) -> Bool {
        guard startHour != endHour else { return false }
        let hour = calendar.component(.hour, from: now)
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        }
        // Wrap-around: quiet if after start OR before end.
        return hour >= startHour || hour < endHour
    }
}
