import Foundation
import os

/// Structured logging for the app, mirroring the desktop's `lib/log.js` tag model.
///
/// Built on `os.Logger` so messages land in the unified logging system: visible in
/// the Console.app, `xcrun simctl spawn booted log stream`, and Xcode's console —
/// the channels we use to debug on-site issues. Each category is a separate
/// `Logger`, so a field engineer can filter by subsystem/category, e.g.
/// `log stream --predicate 'subsystem == "com.inbox2.app"'`.
///
/// Usage: `Log.store.info("loaded \(rows.count) conversations")`.
enum Log {
    static let subsystem = "com.inbox2.app"

    /// Engine lifecycle (FFI construction, start/stop, account boot).
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Local SQLite read path (conversation/message queries).
    static let store = Logger(subsystem: subsystem, category: "store")
    /// Sync + engine events flowing back through the listener.
    static let sync = Logger(subsystem: subsystem, category: "sync")
    /// User actions written back through the FFI (archive/trash/read…).
    static let action = Logger(subsystem: subsystem, category: "action")
    /// View lifecycle / navigation / data binding.
    static let ui = Logger(subsystem: subsystem, category: "ui")
    /// WebView email-body rendering.
    static let reader = Logger(subsystem: subsystem, category: "reader")
    /// inbox2-domain (MX) REST client — auth, API requests, domain mail.
    static let cloud = Logger(subsystem: subsystem, category: "cloud")
}
