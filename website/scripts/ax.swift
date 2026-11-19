// Accessibility tree dumper for the desktop app.
//
// osascript can read the same tree, but it costs one Apple Event per attribute
// per node — a full walk of the inbox takes a minute, which is useless for
// driving a screen recording. The C API walks it in milliseconds.
//
//   swift ax.swift <pid>                 → tab-separated role/title/desc/x/y/w/h
//   swift ax.swift <pid> "Compose"       → only rows whose title or description
//                                          contains the needle (case-insensitive)
import Cocoa
import ApplicationServices

let args = CommandLine.arguments

// `--window <pid>` prints "<windowid> <x> <y> <w> <h>" for the app's biggest
// on-screen window — screencapture -l wants the CGWindowID, which the
// accessibility API does not expose.
if args.count >= 3, args[1] == "--window", let pid = pid_t(args[2]) {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    guard let w = mine.max(by: { a, b in
        let ra = a[kCGWindowBounds as String] as! [String: CGFloat]
        let rb = b[kCGWindowBounds as String] as! [String: CGFloat]
        return ra["Width"]! * ra["Height"]! < rb["Width"]! * rb["Height"]!
    }) else { exit(1) }
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    let id = w[kCGWindowNumber as String] as! Int
    print("\(id) \(Int(b["X"]!)) \(Int(b["Y"]!)) \(Int(b["Width"]!)) \(Int(b["Height"]!))")
    exit(0)
}

guard args.count >= 2, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: ax.swift <pid> [needle] | ax.swift --window <pid>\n".data(using: .utf8)!)
    exit(2)
}
let needle = args.count > 2 ? args[2].lowercased() : nil

func str(_ el: AXUIElement, _ attr: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return "" }
    return (v as? String) ?? ""
}

func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}

var out = ""
func walk(_ el: AXUIElement, _ depth: Int) {
    if depth > 40 { return }
    let role = str(el, kAXRoleAttribute as String)
    let title = str(el, kAXTitleAttribute as String)
    let desc = str(el, kAXDescriptionAttribute as String)
    let value = str(el, kAXValueAttribute as String)
    let p = point(el, kAXPositionAttribute as String) ?? .zero
    let s = size(el, kAXSizeAttribute as String) ?? .zero
    let hay = (title + " " + desc + " " + value).lowercased()
    if needle == nil || hay.contains(needle!) {
        out += "\(role)\t\(title)\t\(desc)\t\(value.prefix(120))\t\(Int(p.x))\t\(Int(p.y))\t\(Int(s.width))\t\(Int(s.height))\n"
    }
    var kids: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
       let arr = kids as? [AXUIElement] {
        for k in arr { walk(k, depth + 1) }
    }
}

walk(AXUIElementCreateApplication(pid), 0)
FileHandle.standardOutput.write(out.data(using: .utf8)!)
