// ucu-window: pick which window of a macOS app ucu will act on.
//
// ucu (Sky computer use) binds `cua.getApp("App")` to the app's main window and has no
// window selector on macOS. This helper uses the Accessibility API to list an app's windows
// and to make one of them the main window (optionally leaving full screen first), so the next
// `cua.getApp(...)` targets it.
//
//   ucu-window list <app>
//   ucu-window focus <app> <title substring> [--unfullscreen] [--activate]
//   ucu-window unfullscreen <app> <title substring>
//
// <app> is a display name or bundle id of a running app. `focus` un-minimizes and raises the
// window and makes it the app's main window; it brings the app to the front only with
// --activate. Needs Accessibility permission for the process that runs it (Claude Code).
// Build: `ucu install` (swiftc -O native/ucu-window.swift -o ~/.local/bin/ucu-window)
import AppKit
import ApplicationServices

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func frame(_ window: AXUIElement) -> String {
    var origin = CGPoint.zero, size = CGSize.zero
    if let value: AXValue = attribute(window, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &origin) }
    if let value: AXValue = attribute(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
    return "\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))"
}

func runningApp(_ query: String) -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
            || $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame
    }
    guard let app = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first else {
        fail("No running app named or with bundle id \"\(query)\".")
    }
    return app
}

func windows(of app: NSRunningApplication) -> (AXUIElement, [AXUIElement]) {
    guard AXIsProcessTrusted() else {
        fail("Accessibility permission is missing for the process running this helper "
            + "(System Settings > Privacy & Security > Accessibility).", 3)
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    let list: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
    return (element, list)
}

func title(_ window: AXUIElement) -> String { attribute(window, kAXTitleAttribute) ?? "" }
func flag(_ window: AXUIElement, _ name: String) -> Bool { (attribute(window, name) as Bool?) ?? false }

func find(_ query: String, in list: [AXUIElement]) -> AXUIElement {
    let matches = list.filter { title($0).localizedCaseInsensitiveContains(query) }
    if matches.count == 1 { return matches[0] }
    if let exact = matches.first(where: { title($0).caseInsensitiveCompare(query) == .orderedSame }) { return exact }
    let titles = list.map { "\"\(title($0))\"" }.joined(separator: ", ")
    fail(matches.isEmpty ? "No window title contains \"\(query)\". Windows: \(titles)"
                         : "\(matches.count) windows match \"\(query)\"; be more specific. Windows: \(titles)", 2)
}

func leaveFullScreen(_ window: AXUIElement) {
    guard flag(window, "AXFullScreen") else { return }
    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
    for _ in 0..<40 where flag(window, "AXFullScreen") { usleep(100_000) }  // the animation takes ~1 s
    usleep(300_000)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, args.count >= 2 else {
    fail("usage: ucu-window list <app> | focus <app> <title> [--unfullscreen] [--activate] | unfullscreen <app> <title>")
}
let app = runningApp(args[1])
let (appElement, list) = windows(of: app)

switch command {
case "list":
    let main: AXUIElement? = attribute(appElement, kAXMainWindowAttribute)
    print("\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier), active=\(app.isActive))")
    for (index, window) in list.enumerated() {
        let isMain = main.map { CFEqual($0, window) } ?? false
        print("[\(index)] \"\(title(window))\" main=\(isMain) minimized=\(flag(window, kAXMinimizedAttribute)) "
            + "fullscreen=\(flag(window, "AXFullScreen")) frame=\(frame(window))")
    }
case "focus", "unfullscreen":
    guard args.count >= 3 else { fail("usage: ucu-window \(command) <app> <title substring>") }
    let window = find(args[2], in: list)
    if command == "unfullscreen" || args.contains("--unfullscreen") { leaveFullScreen(window) }
    if command == "focus" {
        if flag(window, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if args.contains("--activate") { app.activate() }
        usleep(200_000)
    }
    let main: AXUIElement? = attribute(appElement, kAXMainWindowAttribute)
    let isMain = main.map { CFEqual($0, window) } ?? false
    print("\"\(title(window))\" main=\(isMain) fullscreen=\(flag(window, "AXFullScreen")) frame=\(frame(window))")
    exit(command == "focus" && !isMain ? 4 : 0)
default:
    fail("unknown command \(command)")
}
