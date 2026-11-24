import Foundation

/// Diagnostics that survive without a Mac-side log stream: appended to
/// Documents/inbox2/<file> (pull with `devicectl device copy from`, docs/iOS-Device.md).
enum DiagLog {
    static func note(_ file: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("inbox2", isDirectory: true) else { return }
        let url = dir.appendingPathComponent(file)
        // Bounded: past 512 KB the file starts over.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }
}
