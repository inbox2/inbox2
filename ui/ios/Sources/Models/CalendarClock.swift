import Foundation

/// "14:30" for calendar and zone times. One formatter, so the calendar's shown
/// time zone (CalendarZone) applies to every time it prints. Main thread only.
enum CalendarClock {
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    /// Always this device's zone: notification text (meeting alarms) is read outside
    /// the calendar, where the calendar's shown zone means nothing.
    static let device: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .autoupdatingCurrent; return f
    }()
}
