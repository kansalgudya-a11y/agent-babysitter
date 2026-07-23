import Foundation

/// "Don't ping me between 22:00 and 08:00." Pure hour-window math so the app
/// can suppress notifications on a schedule; handles windows that wrap past
/// midnight (start > end).
public enum QuietHours {

    /// True when `now`'s local hour falls inside [startHour, endHour). A window
    /// like 22→8 wraps midnight; 9→17 doesn't. start == end means the WHOLE DAY
    /// is quiet: a user who picks the same From and To hour is asking to be
    /// silenced around the clock. (This previously returned false — "never quiet"
    /// — which silently inverted the toggle: the switch read ON while every
    /// banner still fired. Callers gate on the enable toggle first, so an
    /// unconfigured/off state never reaches here; the registered default window
    /// is 22→8, so start == end only occurs when deliberately chosen.)
    public static func isQuiet(now: Date, startHour: Int, endHour: Int,
                               calendar: Calendar = .current) -> Bool {
        guard startHour != endHour else { return true }
        let hour = calendar.component(.hour, from: now)
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        }
        // Wrap-around: quiet if after start OR before end.
        return hour >= startHour || hour < endHour
    }
}
