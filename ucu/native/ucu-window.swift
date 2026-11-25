// ucu-window: windows and quiet launches for ucu.
//
// This helper uses the Accessibility API to list an app's windows
// and to make one of them the main window (optionally leaving full screen first).
//
//   ucu-window list [app]
//   ucu-window focus <app> <title substring> [--unfullscreen] [--activate]
//   ucu-window unfullscreen <app> <title substring>
//   ucu-window press <app> <shortcut such as cmd+shift+t>
//   ucu-window menu <app> <path such as "File > New Window">
//   ucu-window watch
//
// <app> is a display name or bundle id of a running app; `list` without one covers every app.
// `focus` un-minimizes the window and makes it the app's main window; it shows the app and brings
// it to the front only with --activate, onto the user's screen if it was out of sight, and then it
// is no failure that another window stays the app's main one. `press` runs
// the menu command a shortcut stands for, and `menu` the one at a path, which work on an app in the
// background, even a hidden one. `watch` is what the server runs next to the engine: see Watcher.
// Needs Accessibility permission for the process that runs it (Claude Code).
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

// The same as app_key in ucu-proxy.py: case and invisible marks (WhatsApp's name starts with one) don't count.
func key(_ name: String) -> String {
    let visible = name.unicodeScalars.filter { $0.properties.generalCategory != .format }
    return String(String.UnicodeScalarView(visible)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func matching(_ query: String) -> NSRunningApplication? {
    let wanted = key(query)
    let apps = NSWorkspace.shared.runningApplications.filter {
        key($0.bundleIdentifier ?? "") == wanted || key($0.localizedName ?? "") == wanted
            || key($0.bundleURL?.path ?? "") == wanted
    }
    if let app = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first { return app }
    // An app's file can have another name than the one it shows (DeviceHub.app is "Device Hub"), and look and act
    // know it by either. A program's name counts only when one running app has it, as many apps run the same one.
    let all = NSWorkspace.shared.runningApplications
    let filed = all.filter { key($0.bundleURL?.deletingPathExtension().lastPathComponent ?? "") == wanted }
    if let app = filed.first(where: { $0.activationPolicy == .regular }) ?? filed.first { return app }
    let programs = all.filter { key($0.executableURL?.lastPathComponent ?? "") == wanted }
    return programs.count == 1 ? programs[0] : nil
}

func runningApp(_ query: String) -> NSRunningApplication {
    guard let app = matching(query) else { fail("No running app named or with bundle id \"\(query)\".") }
    return app
}

func requireTrust() {
    guard AXIsProcessTrusted() else {
        fail("Accessibility permission is missing for the process running this helper "
            + "(System Settings > Privacy & Security > Accessibility).", 3)
    }
}

func appElement(_ pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 1)  // a busy app must not hold up the others
    return element
}

func windows(of app: NSRunningApplication) -> (AXUIElement, [AXUIElement]) {
    requireTrust()
    let element = appElement(app.processIdentifier)
    let list: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
    return (element, list)
}

func isMain(_ window: AXUIElement, of element: AXUIElement) -> Bool {
    (attribute(element, kAXMainWindowAttribute) as AXUIElement?).map { CFEqual($0, window) } ?? false
}

func title(_ window: AXUIElement) -> String { attribute(window, kAXTitleAttribute) ?? "" }
func flag(_ window: AXUIElement, _ name: String) -> Bool { (attribute(window, name) as Bool?) ?? false }

// A hidden app reports all its windows as dialogs, so that says nothing there.
func kind(of window: AXUIElement, in app: NSRunningApplication) -> String? {
    switch attribute(window, kAXSubroleAttribute) as String? {
    case _ where app.isHidden: return nil
    case kAXDialogSubrole, kAXSystemDialogSubrole: return "dialog"
    case kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole: return "panel"
    default: return nil
    }
}

func printWindows(of app: NSRunningApplication, element: AXUIElement, list: [AXUIElement]) {
    let main: AXUIElement? = attribute(element, kAXMainWindowAttribute)
    let notes = (app.isActive ? ", active" : "") + (app.isHidden ? ", hidden" : "")
    print("\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier)\(notes))")
    for (index, window) in list.enumerated() {
        let marks = [main.map { CFEqual($0, window) } ?? false ? "main" : nil, kind(of: window, in: app),
                     flag(window, kAXMinimizedAttribute) ? "minimized" : nil,
                     flag(window, "AXFullScreen") ? "fullscreen" : nil, frame(window)]
        print("[\(index)] \"\(title(window))\" " + marks.compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: where the user is

// What the window server knows of Spaces. These calls aren't public, so each is looked up, and where one is missing
// nothing is said of Spaces.
enum Spaces {
    private static func found<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }
    private static let connection = found("CGSMainConnectionID", as: (@convention(c) () -> Int32).self)
    private static let managed = found("CGSCopyManagedDisplaySpaces",
                                       as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
    private static let forWindows = found("CGSCopySpacesForWindows",
                                          as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)

    struct Layout {
        var desktops = 0
        var fullScreen = [Int]()  // the user's full-screen Spaces, in their order
        var showing = Set<Int>()  // the Space each of the user's displays shows
        var all = Set<Int>()
    }

    // The Spaces of the user's displays. An agent's desktop has Spaces of its own, which aren't theirs.
    static func layout() -> Layout? {
        guard let connection, let managed,
              let displays = managed(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let agents = agentDisplays()
        var layout = Layout()
        for display in displays where !agents.contains(display["Display Identifier"] as? String ?? "") {
            if let now = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int {
                layout.showing.insert(now)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["ManagedSpaceID"] as? Int else { continue }
                layout.all.insert(id)
                if space["type"] as? Int == 4 { layout.fullScreen.append(id) } else { layout.desktops += 1 }
            }
        }
        return layout
    }

    static func agentDisplays() -> Set<String> {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return [] }
        let agents = displays.prefix(Int(count)).filter { CGDisplayVendorNumber($0) == AgentDesktop.vendor }
        return Set(agents.compactMap { display in
            CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        })
    }

    static func of(window number: Int) -> [Int] {
        guard let connection, let forWindows else { return [] }
        return forWindows(connection(), 7, [number] as CFArray)?.takeRetainedValue() as? [Int] ?? []
    }
}

// Every window the window server has. It takes 15 ms, so it is read only where there is more than one Space.
func allWindows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}

// An app goes by several names, and the deny list may give any of them. One that can't be read denies every app, as
// it does everywhere else.
func isDenied(_ app: NSRunningApplication, by deny: Set<String>?) -> Bool {
    guard let deny else { return true }
    let info = app.bundleURL.flatMap { Bundle(url: $0) }?.infoDictionary
    let names = [app.localizedName, app.bundleIdentifier, app.bundleURL?.deletingPathExtension().lastPathComponent,
                 info?["CFBundleName"] as? String, info?["CFBundleDisplayName"] as? String]
    return !Set(names.compactMap { $0 }.map(key)).isDisjoint(with: deny)
}

// Whether the user is typing, doing something else, or how long they have done nothing.
func userActivity() -> String {
    let key = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    let any = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    if key < 2 { return "typing" }
    if any < 2 { return "active" }
    return any < 90 ? "idle \(Int(any)) s" : "idle \(Int(any / 60)) min"
}

// The user's Spaces in a few words: how many desktops, which apps are in full screen, and what they are looking at.
func spacesLine(_ layout: Spaces.Layout, windows: [[String: Any]]) -> String {
    var apps = [Int: [String]]()
    if !layout.fullScreen.isEmpty {
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let number = window[kCGWindowNumber as String] as? Int,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Height"] ?? 0) > 100 else { continue }  // not the strip a full-screen app keeps for its toolbar
            for space in Spaces.of(window: number) where layout.fullScreen.contains(space) {
                if !(apps[space] ?? []).contains(owner) { apps[space, default: []].append(owner) }
            }
        }
    }
    func name(_ space: Int) -> String { apps[space].map { $0.joined(separator: " + ") } ?? "an app" }
    var said = "Spaces: \(layout.desktops) desktop\(layout.desktops == 1 ? "" : "s")"
    if !layout.fullScreen.isEmpty { said += ", full screen: " + layout.fullScreen.map(name).joined(separator: ", ") }
    let shown = layout.fullScreen.filter(layout.showing.contains)
    return said + (shown.isEmpty ? "; showing a desktop" : "; showing full screen (\(shown.map(name).joined(separator: ", ")))")
}

// What the user is doing, in a line: the app and window they are in, whether they type, and their Spaces. The title
// of a window is left out for an app on the deny list.
func userLine(deny: Set<String>?, layout: Spaces.Layout?, windows: [[String: Any]]) -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    var said = "User: in \(app.localizedName ?? "an app")"
    if !isDenied(app, by: deny) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)  // a busy app must not hold up the list
        let window: AXUIElement? = attribute(element, kAXFocusedWindowAttribute)
            ?? attribute(element, kAXMainWindowAttribute)
        if let name = window.map(title), !name.isEmpty { said += ", window \"\(name.prefix(80))\"" }
    }
    return said + ", " + userActivity() + (layout.map { ". " + spacesLine($0, windows: windows) } ?? "") + "."
}

// The displays, as x, y, width, height and whether each is an agent's desktop: the server tells from them where a
// listed window is. `list` itself would have to connect to the display system for it, which took 27 ms.
func screens() -> [[Any]] {
    var count: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 32)
    guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return [] }
    return displays.prefix(Int(count)).map { display in
        let bounds = CGDisplayBounds(display)
        return [Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height),
                CGDisplayVendorNumber(display) == AgentDesktop.vendor]
    }
}

// The windows of an app on a Space the user isn't looking at, such as one in full screen: the app's own list leaves
// them out. They are told by their titles, which the window server gives only with Screen Recording permission.
func windowsElsewhere(of app: NSRunningApplication, layout: Spaces.Layout, windows: [[String: Any]]) -> [String] {
    let listed: [AXUIElement] = attribute(appElement(app.processIdentifier), kAXWindowsAttribute) ?? []
    let known = Set(listed.map(title))
    var lines = [String]()
    for window in windows where (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier {
        guard (window[kCGWindowLayer as String] as? Int) == 0,
              !((window[kCGWindowIsOnscreen as String] as? Bool) ?? false),
              let number = window[kCGWindowNumber as String] as? Int,
              let name = window[kCGWindowName as String] as? String, !name.isEmpty, !known.contains(name) else { continue }
        let spaces = Spaces.of(window: number)
        guard !spaces.isEmpty, layout.showing.isDisjoint(with: spaces), !layout.all.isDisjoint(with: spaces) else { continue }
        let full = layout.fullScreen.contains(where: spaces.contains) ? "fullscreen " : ""
        let line = "\(app.localizedName ?? "?"): \"\(name)\" \(full)other-space"
        if !lines.contains(line) { lines.append(line) }
    }
    return lines
}

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

// What the window server knows about one window, without the cost of listing them all.
func windowInfo(_ id: CGWindowID) -> [String: Any]? {
    var pointer = UnsafeRawPointer(bitPattern: UInt(id))
    guard let list = CFArrayCreate(kCFAllocatorDefault, &pointer, 1, nil) else { return nil }
    return (CGWindowListCreateDescriptionFromArray(list) as? [[String: Any]])?.first
}

func bounds(of window: [String: Any]) -> CGRect {
    (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null
}

func color(_ hex: String) -> NSColor? {
    guard let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}

func emit(_ message: [String: Any]) {
    guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
    line.append(10)
    line.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, stdout) }
    fflush(stdout)
}

func applicationURL(_ query: String) -> URL? {
    if query.hasPrefix("/") { return FileManager.default.fileExists(atPath: query) ? URL(fileURLWithPath: query) : nil }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) { return url }
    return NSWorkspace.shared.fullPath(forApplication: query).map(URL.init(fileURLWithPath:))
}

// What a person would read first in a window: its text and its buttons, within a budget, because a web page
// can hold thousands of elements.
func contents(of window: AXUIElement) -> (text: String, buttons: [String]) {
    let controls: Set<String> = [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole,
                                 kAXFullScreenButtonSubrole]
    var texts = [String](), buttons = [String](), queue = [window], visited = 0, length = 0
    while visited < queue.count, visited < 300, length < 300 {
        let element = queue[visited]
        visited += 1
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole, let value: String = attribute(element, kAXValueAttribute), !value.isEmpty,
           !texts.contains(value) {
            texts.append(value)
            length += value.count
        } else if role == kAXButtonRole, let name: String = attribute(element, kAXTitleAttribute), !name.isEmpty,
                  !controls.contains(attribute(element, kAXSubroleAttribute) ?? ""), !buttons.contains(name) {
            buttons.append(name)  // those without a title are toolbar icons, not answers to a question
        }
        queue += attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? []
    }
    return (texts.joined(separator: " "), Array(buttons.prefix(6)))
}

// A display only an agent uses, placed so that it touches the user's screens at a corner at most. Windows on it are
// on screen for macOS, so they render and take clicks by position, but nobody sees them. When it goes away, macOS
// moves them back to where they were. The classes are private, so they are looked up at run time: without them
// `open()` returns nil and apps stay hidden or are shown behind the user's windows.
final class AgentDesktop {
    static let width: UInt = 1920, height: UInt = 1200, slots = 1...8, vendor: UInt32 = 0x55C1
    static let modeSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
    static let settle = 0.6

    var display: NSObject?  // the display lasts as long as this object
    var made = Date.distantFuture
    var slot: UInt32?

    // Screens are remembered by serial number, so reusing a few numbers keeps macOS's list of them short.
    // Whether a place is on an agent's desktop, or on no screen at all, where nobody would see it.
    static func isOutOfSight(_ point: CGPoint) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return true }
        return CGDisplayVendorNumber(display) == vendor
    }

    // Whether a place is on an agent's desktop: on no screen, a window may be one the user is moving.
    static func holds(_ point: CGPoint) -> Bool {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count > 0
            && CGDisplayVendorNumber(display) == vendor
    }

    func takeSlot() -> UInt32? {
        let folder = NSHomeDirectory() + "/Library/Application Support/ucu"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for slot in Self.slots {
            let lock = Darwin.open("\(folder)/desktop-\(slot).lock", O_CREAT | O_RDWR, 0o600)
            if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 {  // the file stays open: the lock goes with this process
                self.slot = UInt32(slot)
                return self.slot
            }
            close(lock)
        }
        return nil
    }

    func make() -> NSObject? {
        guard let descriptor = (NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type)?.init(),
              let settings = (NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type)?.init(),
              let displayClass = NSClassFromString("CGVirtualDisplay") as AnyObject?,
              let modeClass: AnyClass = NSClassFromString("CGVirtualDisplayMode"),
              let implementation = class_getMethodImplementation(modeClass, Self.modeSelector),
              let serial = slot ?? takeSlot() else { return nil }
        descriptor.setValue("UCU Agent Desktop", forKey: "name")
        descriptor.setValue(Self.width * 2, forKey: "maxPixelsWide")
        descriptor.setValue(Self.height * 2, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 520, height: 325)), forKey: "sizeInMillimeters")
        descriptor.setValue(Self.vendor, forKey: "productID")
        descriptor.setValue(Self.vendor, forKey: "vendorID")
        descriptor.setValue(serial, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>
        let allocated = (modeClass as AnyObject).perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        let start = unsafeBitCast(implementation, to: ModeInit.self)
        let mode = start(allocated, Self.modeSelector, Self.width, Self.height, 30)
        settings.setValue(1, forKey: "hiDPI")  // screenshots and coordinates assume Retina
        settings.setValue([mode.takeUnretainedValue()], forKey: "modes")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let apply = NSSelectorFromString("applySettings:")
        let blank: AnyObject = displayClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        guard let made = blank.perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor),
              let display = made.takeUnretainedValue() as? NSObject,
              let method = class_getMethodImplementation(type(of: display), apply),
              unsafeBitCast(method, to: Apply.self)(display, apply, settings) else { return nil }
        return display
    }

    func open() -> Bool {
        if display == nil {
            display = make()
            made = Date()
            guard let id = displayID else { return false }
            var configuration: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&configuration)
            CGConfigureDisplayOrigin(configuration, id, -6000, -6000)  // macOS moves it next to the others, at a corner
            CGCompleteDisplayConfiguration(configuration, .forSession)
        }
        return displayID != nil
    }

    // Where the desktop is, in the coordinates windows use.
    var bounds: CGRect? { displayID.map(CGDisplayBounds).flatMap { $0.width > 0 ? $0 : nil } }

    var displayID: CGDirectDisplayID? { (display?.value(forKey: "displayID") as? NSNumber)?.uint32Value }

    // Apps hear about a new display a moment after macOS shows it. Until then, one that gets a window moved there
    // brings it back to a screen it knows, in part onto the user's. A display that was just made also starts out on
    // top of the user's screen, so a window sent there before macOS moves it aside would land in front of them.
    var isReady: Bool {
        -made.timeIntervalSinceNow > Self.settle && isApart && NSScreen.screens.contains {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    var isApart: Bool {
        guard let id = displayID, let area = bounds else { return false }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).allSatisfy { $0 == id || !CGDisplayBounds($0).intersects(area) }
    }
}

// The agent's own cursor, one per chat in its color. The server says where each action lands. It stays just above the
// window it is working on, so the user's front windows cover it, and it takes no clicks.
final class AgentCursor {
    static let size: CGFloat = 126, tick = 1.0 / 120, linger = 20.0, fadeTime = 0.25
    static let bend: CGFloat = 0.16, tiltLimit: CGFloat = 0.42, tiltEase = 0.07, restHeading = 3 * CGFloat.pi / 4
    static let tabDepth = 10, tabSearch = 150, tabSearchPause = 2.0

    var color: NSColor?  // comes from the server
    var timer: Timer?
    var panel: NSPanel?
    let arrow = CAShapeLayer()
    var restAt = Date.distantFuture, lastStep = Date()
    var target: CGWindowID?  // the window under the cursor, which it stays just above
    var tab: AXUIElement?  // that window's selected tab as the cursor came, in a window that has tabs
    var searched = Date.distantPast
    var ticks = 0
    var position: CGPoint?, velocity = CGPoint.zero, tilt: CGFloat = 0
    var path: (start: CGPoint, control: CGPoint, end: CGPoint, began: Date, time: Double, moving: Bool)?

    func move(to point: CGPoint, over apps: [NSRunningApplication], busy: @escaping () -> Bool) {
        guard color != nil, !AgentDesktop.isOutOfSight(point), let window = topWindow(at: point, of: apps) else { return }
        restAt = Date() + Self.linger
        head(to: point, over: window, Date())
        guard timer == nil else { return }
        lastStep = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [self] _ in step(busy: busy()) }
    }

    func rest() { restAt = Date() }

    func step(busy: Bool) {
        let now = Date(), elapsed = now.timeIntervalSince(lastStep)
        lastStep = now
        ticks += 1
        if busy { restAt = now + Self.linger }
        glide(now, elapsed)
        if ticks % 30 == 0 { keepInPlace() }
        if let panel, position != nil, now >= restAt {
            panel.alphaValue -= elapsed / Self.fadeTime
            if panel.alphaValue <= 0 {
                panel.orderOut(nil)
                position = nil
                path = nil
                target = nil
                tab = nil
            }
        }
        if position == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    // The frontmost window of the apps this chat drives at that point. A hidden app has none, so it shows no cursor.
    func topWindow(at point: CGPoint, of apps: [NSRunningApplication]) -> [String: Any]? {
        let pids = Set(apps.map { Int($0.processIdentifier) })
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.first {
            pids.contains($0[kCGWindowOwnerPID as String] as? Int ?? 0) && bounds(of: $0).contains(point)
        }
    }

    func head(to end: CGPoint, over window: [String: Any], _ now: Date) {
        let panel = panel ?? makePanel()
        let number = window[kCGWindowNumber as String] as? CGWindowID
        // A step lands in the tab that shows, so the tab is found as the cursor comes and never later, when the tab
        // that shows may be another. A window without tabs can get them, so it is searched again after a while.
        if number != target || (tab == nil ? now.timeIntervalSince(searched) > Self.tabSearchPause : !tabShows()) {
            tab = Self.selectedTab(of: window)
            searched = now
        }
        target = number
        panel.level = NSWindow.Level(rawValue: window[kCGWindowLayer as String] as? Int ?? 0)
        panel.alphaValue = 1
        guard let start = position else {
            position = end
            place(panel, at: end)
            keepInPlace()
            return
        }
        let dx = end.x - start.x, dy = end.y - start.y, distance = hypot(dx, dy)
        guard distance > 0.5 else { return }
        let time = min(0.55, 0.2 + Double(distance) / 1800)
        var control: CGPoint
        let moving = path != nil
        if moving {  // already on its way: it leaves at the speed it has, so the turn is a curve and not a corner
            let lead = CGFloat(time) / 4
            control = CGPoint(x: start.x + velocity.x * lead, y: start.y + velocity.y * lead)
        } else {  // a hand swings on an arc, so the path bows upward, or to the right when it goes straight up or down
            var side = CGPoint(x: dy / distance, y: -dx / distance)
            if side.y > 0.01 || (abs(side.y) <= 0.01 && side.x < 0) { side = CGPoint(x: -side.x, y: -side.y) }
            control = CGPoint(x: (start.x + end.x) / 2 + side.x * distance * Self.bend * 2,
                              y: (start.y + end.y) / 2 + side.y * distance * Self.bend * 2)
        }
        path = (start, control, end, now, time, moving)
    }

    func glide(_ now: Date, _ elapsed: Double) {
        guard let panel, let old = position else { return }
        var turn: CGFloat = 0
        if let path {
            let t = min(1, CGFloat(now.timeIntervalSince(path.began) / path.time))
            let u = path.moving ? t * (2 - t) : t * t * (3 - 2 * t)  // from rest it eases in as well as out
            let v = 1 - u
            let next = CGPoint(x: v * v * path.start.x + 2 * v * u * path.control.x + u * u * path.end.x,
                               y: v * v * path.start.y + 2 * v * u * path.control.y + u * u * path.end.y)
            if elapsed > 0 { velocity = CGPoint(x: (next.x - old.x) / elapsed, y: (next.y - old.y) / elapsed) }
            position = next
            place(panel, at: next)
            if t >= 1 {
                self.path = nil
                velocity = .zero
            }
            // It leans toward where it is going, more the faster it goes. Screen y grows downward, the layer's upward.
            let speed = hypot(velocity.x, velocity.y)
            if speed > 1 {
                var away = atan2(-velocity.y, velocity.x) - Self.restHeading
                away = atan2(sin(away), cos(away))
                turn = max(-Self.tiltLimit, min(Self.tiltLimit, away * 0.5)) * min(1, speed / 900)
            }
        }
        tilt += (turn - tilt) * CGFloat(1 - exp(-elapsed / Self.tiltEase))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        CATransaction.commit()
    }

    func place(_ panel: NSPanel, at point: CGPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0  // window coordinates count from its top, these from its bottom
        panel.setFrameOrigin(NSPoint(x: point.x - Self.size / 2, y: height - point.y - Self.size / 2))
    }

    // The window under it may have come forward or gone to another Space since, or show another tab.
    func keepInPlace() {
        guard let panel, let target else { return }
        if let window = windowInfo(target), window[kCGWindowIsOnscreen as String] as? Bool == true, tabShows() {
            panel.order(.above, relativeTo: Int(target))
        } else {
            panel.orderOut(nil)
        }
    }

    // The agent works in one tab of a window, such as a page in the user's browser window. Once the user goes to
    // another tab the cursor would point at their page, so it shows only while its tab does, and again when they
    // come back. An app too busy to answer isn't asked again.
    func tabShows() -> Bool {
        guard let tab else { return true }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &value) {
        case .success: return (value as? NSNumber)?.boolValue == true
        case .cannotComplete:
            self.tab = nil
            return true
        default: return false  // the tab was closed
        }
    }

    // The selected tab of a window that has tabs. The window's own tabs are near its top, so the search goes level by
    // level, stops at the first element that doesn't answer, and leaves web content out: a page can have tabs too.
    static func selectedTab(of window: [String: Any]) -> AXUIElement? {
        guard let pid = window[kCGWindowOwnerPID as String] as? Int else { return nil }
        let place = bounds(of: window).origin
        let all: [AXUIElement] = attribute(appElement(pid_t(pid)), kAXWindowsAttribute) ?? []
        guard let found = all.first(where: { window in
            Watcher.frame(of: window).map { abs($0.minX - place.x) < 2 && abs($0.minY - place.y) < 2 } ?? false
        }) else { return nil }
        var level = [found], seen = 0
        for _ in 0..<tabDepth {
            var next = [AXUIElement]()
            for element in level {
                seen += 1
                guard seen <= tabSearch, let role: String = attribute(element, kAXRoleAttribute) else { return nil }
                if role == "AXWebArea" { continue }
                if role == kAXRadioButtonRole, (attribute(element, kAXSubroleAttribute) as String?) == "AXTabButton" {
                    if (attribute(element, kAXValueAttribute) as NSNumber?)?.boolValue == true { return element }
                    continue
                }
                next += attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? []
            }
            level = next
        }
        return nil
    }

    func makePanel() -> NSPanel {
        NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon, and it never becomes the active app
        let size = Self.size, bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        panel.contentView = view
        let tint = color ?? .gray
        let shadow = CAGradientLayer()  // a soft shadow that fades out at about 33 points
        shadow.type = .radial
        shadow.frame = bounds
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 1)
        shadow.colors = [0.8, 0.65, 0.44, 0.22, 0.08, 0.02, 0].map { tint.withAlphaComponent($0).cgColor }
        shadow.locations = [0, 0.14, 0.24, 0.33, 0.43, 0.52, 0.6]
        view.layer?.addSublayer(shadow)
        arrow.frame = bounds
        arrow.path = Self.arrowPath(center: size / 2)
        arrow.fillColor = (tint.blended(withFraction: 0.28, of: .black) ?? tint).cgColor  // darker than the shadow
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1.3
        arrow.lineJoin = .round
        view.layer?.addSublayer(arrow)
        self.panel = panel
        return panel
    }

    // A rounded dart around the click point, pointing up and to the left. Its corners are in screen directions.
    static func arrowPath(center: CGFloat) -> CGPath {
        let corners: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
            (-6, -6, 1.6), (10.4, 0.4, 1.4), (3.4, 3.4, 2.5), (0.4, 10.4, 1.4)]
        let points = corners.map { CGPoint(x: center + $0.x, y: center - $0.y) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: (points[0].x + points[3].x) / 2, y: (points[0].y + points[3].y) / 2))
        for (index, corner) in corners.enumerated() {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % 4], radius: corner.radius)
        }
        path.closeSubpath()
        return path
    }
}

// What an agent needs from the user, said on the window it brought to them: "Waiting for you: Sign in", with a Done
// button, in the chat's color. It sits at the top of the window the agent brought them, while that window is the one
// they are in, until the user clicks Done, the agent goes on working there, the window closes, or the chat ends. It
// stays between turns too, which is when an agent that has stopped to wait for the user needs it most. Over another
// window, even one of the same app, it would say nothing of where the user is needed.
final class AskLabel: NSObject {
    var panel: NSPanel?
    var app: NSRunningApplication?
    var window: AXUIElement?
    var timer: Timer?
    var done: ((Bool) -> Void)?  // true when the user clicked Done, false when the window is gone
    var isShowing: Bool { panel != nil }

    func show(_ text: String, on app: NSRunningApplication, window: AXUIElement, color: NSColor?,
              done: @escaping (Bool) -> Void) {
        hide()
        NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon, and it never becomes the active app
        let label = NSTextField(labelWithString: "Waiting for you: " + text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        // It fits in the window it is on: in a narrow one the text is cut short, and reads whole in the chat.
        let room = (Watcher.frame(of: window)?.width ?? 600) - 120
        label.widthAnchor.constraint(lessThanOrEqualToConstant: min(460, max(120, room))).isActive = true
        let button = NSButton(title: "", target: self, action: #selector(clicked))
        button.isBordered = false  // a system button's dark title can't be read on the chat's color
        button.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
        button.layer?.cornerRadius = 10
        button.widthAnchor.constraint(equalToConstant: 56).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let stack = NSStackView(views: [label, button])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 10)
        let size = stack.fittingSize, bounds = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let back = NSView(frame: bounds)
        back.wantsLayer = true
        let tint = color ?? .darkGray
        back.layer?.backgroundColor = (tint.blended(withFraction: 0.45, of: .black) ?? tint).cgColor
        back.layer?.cornerRadius = size.height / 2
        stack.frame = bounds
        back.addSubview(stack)
        panel.contentView = back
        (self.panel, self.app, self.window, self.done) = (panel, app, window, done)
        place()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] _ in place() }
    }

    // Just under the window's title bar, and only while the user is in that window or in what is over it. A sheet or
    // a dialog there is often the very thing they must answer, and the label would cover it, so it goes above the
    // window when there is room. A window that has closed says so itself. One that doesn't answer is in a busy app,
    // a page loading for instance, and is still there.
    func place() {
        var role: CFTypeRef?
        guard let panel, let app, let window, !app.isTerminated,
              AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) != .invalidUIElement else {
            let ended = done
            hide()
            ended?(false)
            return
        }
        let element = appElement(app.processIdentifier)
        let current: AXUIElement? = attribute(element, kAXFocusedWindowAttribute)
            ?? attribute(element, kAXMainWindowAttribute)
        guard app.isActive, Self.belongs(current, to: window), let frame = Watcher.frame(of: window),
              !Watcher.isOutOfSight(window), let screen = NSScreen.screens.first else { return panel.orderOut(nil) }
        let size = panel.frame.size, menuBar = screen.frame.height - screen.visibleFrame.maxY
        let inIt = current.map { CFEqual($0, window) } ?? true
        let above = frame.minY - size.height - 6
        let top = (!inIt || Self.hasSheet(window)) && above >= menuBar ? above : frame.minY + 36
        // Windows count from the top, screens up.
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: screen.frame.height - top - size.height))
        panel.orderFrontRegardless()
    }

    // Whether the user, in `current`, is still with the window: in it, in a sheet on it, or in a dialog of the app's,
    // which is over whatever window they were in. In another ordinary window the label would say of that one what it
    // says of this. An app that doesn't say where they are is a busy one.
    static func belongs(_ current: AXUIElement?, to window: AXUIElement) -> Bool {
        guard let current, !CFEqual(current, window) else { return true }
        if (attribute(current, kAXRoleAttribute) as String?) == kAXSheetRole as String {
            return isSheet(current, of: window)
        }
        return (attribute(current, kAXSubroleAttribute) as String?) != kAXStandardWindowSubrole as String
    }

    static func isSheet(_ element: AXUIElement, of window: AXUIElement) -> Bool {
        (attribute(element, kAXRoleAttribute) as String?) == kAXSheetRole as String
            && (attribute(element, kAXParentAttribute) as AXUIElement?).map { CFEqual($0, window) } ?? false
    }

    static func hasSheet(_ window: AXUIElement) -> Bool {
        let parts: [AXUIElement] = attribute(window, kAXChildrenAttribute) ?? []
        return parts.contains { (attribute($0, kAXRoleAttribute) as String?) == kAXSheetRole as String }
    }

    @objc func clicked() {
        let done = done
        hide()
        done?(true)
    }

    func hide() {
        timer?.invalidate()
        panel?.orderOut(nil)
        (panel, app, window, timer, done) = (nil, nil, nil, nil, nil)
    }
}

// Runs next to the server for as long as its stdin stays open, so it can't outlive the proxy. Commands come as one
// JSON object per line on stdin; replies and reports go out the same way on stdout.
//
//   {"id": 1, "open": "Blender", "deny": ["Terminal"]}  open a closed app hidden, unless it is denied
//   {"id": 2, "show": ["Blender"]}                      show hidden apps, behind the user's windows
//   {"id": 3, "desktop": true}                          make the agent's desktop and say where it is
//   {"id": 4, "park": ["Blender"]}                      move apps' windows to that desktop and show them there
//   {"watch": ["safari"]}                               report these apps' new windows from now on
//   {"watch": ["safari"], "own": true}                  and the agent works there in a window of its own
//   {"busy": true}                                      an agent's call began (false: it ended)
//   {"allow": "Blender"}                                bring this app back and let it come to the front just now
//   {"ours": "Google Chrome"}                           the agent is about to bring this app forward: always undo it
//   {"who": "claude-code:my-project"}                   the chat, for the focus log
//   {"rest": true}                                      the turn is over: go, unless this keeps apps ucu opened
//   {"cursor": "#E5484D"}                               draw the agent's cursor in this color
//   {"cursorTo": [640, 480]}                            move the cursor to this place on screen
//   {"turnEnded": true}                                 the turn ended, so the cursor can go
//   {"id": 5, "borrow": "Blender", "wait": 8}           bring this app to the front for an agent's steps, once the
//                                                       user has done nothing for a moment
//   {"id": 6, "giveBack": true}                         those steps are done: the user's app comes back
//   {"id": 7, "front": true, "at": [640, 480]}          say which app is in front, and whose window is at a place
//   {"id": 8, "atWork": "Safari"}                       say whether the user is typing or clicking in this app now
//   {"ask": "Sign in", "app": "Safari", "window": "…"}  say on that window what the user must do ("": no more)
//
// Reports are {"event": "window", ...} for a new window, and {"event": "focus", ...} when an app that an agent's
// action started or drives came to the front by itself and the user's app was put back, or, with "window": true, when
// it gave one of its windows out of sight the keyboard, while the user was in that app, and their window got it back.
// {"event": "taken", ...} says the user came to an app ucu kept out of their sight, which is on their screen now.
// {"event": "done", ...} says the user clicked Done on what the agent asked of them in an app.
final class Watcher {
    static let dialogOwners: Set<String> = ["SecurityAgent", "UserNotificationCenter", "CoreServicesUIAgent",
                                            "AuthenticationServicesAgent", "coreautha"]
    static let quietTail = 1.5, windowSettle = 0.3, hideGuard = 3.0, noWindowLimit = 6.0, openLimit = 45.0
    static let inputWindow = 1.5, longestCall = 300.0, moveSettle = 0.3
    // Apps come forward by themselves seconds after an action too, such as a browser once a page has loaded.
    static let guardTail = 10.0, allowGrace = 5.0, switchWindow = 1.0, modifierWindow = 0.5, focusTick = 0.1
    static let putBackCheck = 0.1, putBackTries = 3, oursGrace = 3.0, quitWait = 3.0, dockWindow = 5.0

    var watched = Set<String>()
    var own = Set<String>()  // the watched apps where the agent works in a window of its own, never in the user's
    var driven = [NSRunningApplication]()  // the watched apps that were running when the last call began
    var seenWindows = [pid_t: [AXUIElement]]()
    var seenDialogs = Set<Int>()
    var known = [String: NSRunningApplication]()  // finding a running app takes ~15 ms, and agents get apps often
    var keptHidden = Set<pid_t>()
    let desktop = AgentDesktop()
    let cursor = AgentCursor()
    let ask = AskLabel()
    var parked = [pid_t: (app: NSRunningApplication, places: [(AXUIElement, CGPoint)], target: CGPoint)]()
    var busySince = Date.distantFuture
    var busyUntil = Date.distantPast
    var guardUntil = Date.distantPast  // until then, the apps this chat drives can't take the user's focus
    var front = NSWorkspace.shared.frontmostApplication
    var userWindows = [pid_t: AXUIElement]()  // each driven app's window the user last had, which they can see
    var allowed: pid_t?
    var allowedUntil = Date.distantPast
    var oursUntil = [pid_t: Date]()  // until when an app comes forward because of the agent, whatever the user does
    // Apps ucu opened for the agent, which stay out of the user's sight, on the desktop or else hidden, until the user
    // takes one: they can't come forward at any time while the chat runs.
    var launchedHidden = Set<pid_t>()
    var opening = Set<URL>()  // the apps ucu is opening this moment: one can come forward before ucu has its process
    var launchedFresh = Set<pid_t>()  // those that weren't running before: they quit when the chat ends
    var resting = false  // between turns, this runs only to keep ucu's apps out of sight
    var observers = [pid_t: AXObserver]()  // new windows of parked apps, which join the others on the desktop
    var who = "?"
    var usersWindows = [Int: CGPoint]()  // the windows on the user's screens as the desktop was made, and where
    var dockClick: (at: Date, app: URL)?  // the user's last click, when it was on an app's icon in the Dock

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)  // a stuck app must not hold up the run loop
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ action: @escaping (NSRunningApplication) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { action(app) }
            }
        }
        on(NSWorkspace.didActivateApplicationNotification) { [self] in activated($0) }
        on(NSWorkspace.didTerminateApplicationNotification) { [self] in
            seenWindows[$0.processIdentifier] = nil
            stopWatchingWindows(of: $0.processIdentifier)
            launchedHidden.remove($0.processIdentifier)
            launchedFresh.remove($0.processIdentifier)
            if resting { restIfDone() }
        }
        // Another chat's desktop coming or going has macOS arrange the displays again, and move windows with them.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.returnStrays(known: false)
                self.rescueStranded()
            }
        }
        rescueStranded()  // what an earlier chat's desktop left behind
        scanDialogs(reporting: false)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] _ in
            if Date() < busyUntil { scan() }
        }
        Timer.scheduledTimer(withTimeInterval: Self.focusTick, repeats: true) { [self] _ in
            if Date() < guardUntil { guardWindow() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [self] in noteClick($0) }
        Thread.detachNewThread { [self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                DispatchQueue.main.async { self.handle(command) }
            }
            DispatchQueue.main.async { self.finish() }
        }
        // macOS moves an agent's desktop when another chat's goes away. A process sees where its displays are now only
        // while it takes the window server's events, which the application's own loop does and a bare run loop doesn't.
        NSApplication.shared.run()
        exit(0)
    }

    // Apps ucu opened for the chat, that weren't running before and that the user hasn't taken over.
    func keptApps() -> [NSRunningApplication] {
        launchedFresh.intersection(launchedHidden).compactMap(NSRunningApplication.init(processIdentifier:))
            .filter { !$0.isTerminated }
    }

    // Between turns this goes, and the agent's desktop with it, unless it keeps apps ucu opened: with nothing here to
    // put the user's app back, one of them could come forward over it at any time.
    func restIfDone() {
        if resting, keptApps().isEmpty, !ask.isShowing { finish() }  // a user who is asked something still sees it
    }

    // When the chat ends, the apps ucu opened for it are quit, so that none can come forward later with nothing to put
    // the user's app back. One that won't quit yet, such as one asking about unsaved changes, stays hidden. Without the
    // desktop, macOS moves its windows back to the user's screens, so they are hidden first.
    func finish() {
        giveBack(id: nil)
        let leaving = keptApps(), started = Date()
        leaving.forEach { $0.terminate() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] timer in
            guard leaving.allSatisfy(\.isTerminated) || -started.timeIntervalSinceNow > Self.quitWait else { return }
            timer.invalidate()
            leaving.filter { !$0.isTerminated }.forEach {
                log("\($0.localizedName ?? "?"), which ucu opened, didn't quit when the chat ended: left hidden")
            }
            // An app the user had open, which the agent moved to its desktop, is theirs again where it was. One that
            // ucu opened has no place of the user's, so it hides.
            for place in Array(parked.values) where !place.app.isTerminated {
                if launchedHidden.contains(place.app.processIdentifier) { place.app.hide() } else { bringBack(place.app) }
            }
            returnStrays()
            rescueStranded()
            let tucked = tuckAway()
            if parked.isEmpty && !tucked { exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
    }

    // The user's windows are theirs wherever macOS puts them. When a display comes or goes it moves windows about, and
    // one of the user's can end up on the agent's desktop, where they can't see it and where it stays, on no screen at
    // all, once the desktop is gone: they click the app's Dock icon and nothing comes. So what is on the desktop without
    // ucu having put it there goes back. A window seen on the user's screen as the desktop was made goes where it was.
    // Any other is of an app the chat neither opened, nor moved, nor works in with a window of its own, and goes to
    // the same place on the user's main screen.
    func noteUsersWindows() {
        usersWindows = [:]
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            let origin = bounds(of: window).origin
            if let number = window[kCGWindowNumber as String] as? Int, !AgentDesktop.isOutOfSight(origin) {
                usersWindows[number] = origin
            }
        }
    }

    // `known` says the windows noted as the desktop was made still tell the user's from the chat's: later a browser
    // window of the chat's own that the user had on their screen may be back on the desktop, where it belongs.
    func returnStrays(known: Bool = true) {
        guard let area = desktop.bounds else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            let frame = bounds(of: window)
            guard area.contains(CGPoint(x: frame.midX, y: frame.minY + 10)), frame.height > 60,
                  let pid = (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != getpid(),
                  parked[pid] == nil, !launchedHidden.contains(pid),
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let was = (window[kCGWindowNumber as String] as? Int).flatMap { usersWindows[$0] }
            guard !isOwn(app) || (known && was != nil) else { continue }  // the chat's own, in a browser it works in
            let home = was ?? CGPoint(x: frame.minX - area.minX, y: max(frame.minY - area.minY, 30))
            let all: [AXUIElement] = attribute(appElement(pid), kAXWindowsAttribute) ?? []
            for stray in all where Self.frame(of: stray).map({ abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2 })
                ?? false {
                move(stray, to: home)
                log("a window of \(app.localizedName ?? "?") was on the agent's desktop without ucu having put it "
                    + "there: back on the user's screen")
            }
        }
    }

    // A window can also be left where a desktop is or was without showing there: one that an earlier ucu sent to the
    // Dock from its desktop, which comes out of the Dock where nobody sees it, or one that is placed there but still
    // belongs to the user's screen. The user clicks the app's Dock icon and nothing comes. A window that an agent
    // keeps on a desktop shows there, so it isn't one of these. Such a window gets a place on the user's main screen,
    // as far from its corner as it was from the desktop's; one in the Dock stays there, and comes out in sight.
    func rescueStranded(of only: NSRunningApplication? = nil) {
        let shown = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { window -> String? in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int else { return nil }
            let frame = bounds(of: window)
            return "\(pid) \(Int(frame.minX)) \(Int(frame.minY))"
        })
        let apps = only.map { [$0] } ?? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps where !app.isHidden && !app.isTerminated {
            let pid = app.processIdentifier
            guard pid != getpid(), parked[pid] == nil, !launchedHidden.contains(pid) else { continue }
            let windows: [AXUIElement] = attribute(appElement(pid), kAXWindowsAttribute) ?? []
            for window in windows where Self.isOutOfSight(window) {
                var movable = DarwinBoolean(false)  // Finder's desktop on a display is a window too, and stays
                AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
                guard movable.boolValue, let frame = Self.frame(of: window), frame.height > 60,
                      !shown.contains("\(pid) \(Int(frame.minX)) \(Int(frame.minY))") else { continue }
                var display: CGDirectDisplayID = 0, count: UInt32 = 0
                let on = CGGetDisplaysWithPoint(frame.origin, 1, &display, &count) == .success && count > 0
                let corner = on ? CGDisplayBounds(display).origin : CGPoint(x: frame.minX - 120, y: frame.minY - 120)
                move(window, to: CGPoint(x: max(frame.minX - corner.x, 0), y: max(frame.minY - corner.y, 30)))
                log("a window of \(app.localizedName ?? "?") was out of the user's sight, where an agent's desktop is "
                    + "or was: it has a place on their screen again")
            }
        }
    }

    // A window of the chat's own can still be on the desktop, in a browser it works in, when the server stopped before
    // hiding it. Hiding its app would hide the user's windows too, so it goes to the Dock. Only the chat's own: a
    // window of the user's that macOS moved here went back to their screen just before, and is never sent to the Dock.
    func tuckAway() -> Bool {
        guard let area = desktop.bounds else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let owners = Set(list.compactMap { window -> pid_t? in
            guard let pid = (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), parked[pid] == nil,
                  pid != getpid(), (window[kCGWindowLayer as String] as? Int) == 0,
                  area.intersects(bounds(of: window)),
                  NSRunningApplication(processIdentifier: pid).map(isOwn) ?? false else { return nil }  // never the user's
            return pid
        })
        var tucked = false
        for pid in owners {
            let list: [AXUIElement] = attribute(appElement(pid), kAXWindowsAttribute) ?? []
            for window in list where Self.frame(of: window).map(area.intersects) ?? false {  // not another chat's
                tucked = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                    == .success || tucked
            }
        }
        return tucked
    }

    func handle(_ command: [String: Any]) {
        if let hex = command["cursor"] as? String { cursor.color = color(hex) }
        if let name = command["who"] as? String { who = name.split(separator: " ").joined(separator: "-") }
        if command["rest"] != nil {
            resting = true
            restIfDone()
        }
        if command["turnEnded"] != nil { cursor.rest() }
        if let point = command["cursorTo"] as? [Double], point.count == 2 {
            driven = watched.compactMap(running)
            cursor.move(to: CGPoint(x: point[0], y: point[1]), over: driven) { [self] in Date() < busyUntil }
        }
        if let names = command["watch"] as? [String] {
            watched.formUnion(names.map(key))
            if command["own"] as? Bool == true { own.formUnion(names.map(key)) }
            driven = watched.compactMap(running)
        }
        if let name = command["ours"] as? String, let app = running(name) {
            oursUntil[app.processIdentifier] = Date() + Self.oursGrace
        }
        if let name = command["allow"] as? String, let app = running(name) {
            allowed = app.processIdentifier
            allowedUntil = Date() + Self.allowGrace  // only for the call that asked: later it can't come forward again
            keptHidden.remove(app.processIdentifier)
            bringBack(app)
            log("\(app.localizedName ?? "?") came to the user at the agent's request")
        }
        if let busy = command["busy"] as? Bool {
            busyUntil = Date() + (busy ? Self.longestCall : Self.quietTail)  // no end comes if the server crashes
            guardUntil = Date() + (busy ? Self.longestCall : Self.guardTail)
            if busy {
                resting = false
                busySince = Date()
                front = NSWorkspace.shared.frontmostApplication
                driven = watched.compactMap(running)
                scan()
            }
        }
        if let name = command["open"] as? String {
            open(name, deny: command["deny"] as? [String] ?? [], id: command["id"] ?? NSNull(),
                 desktopFirst: command["desktopFirst"] as? Bool ?? false)
        }
        if let names = command["show"] as? [String] { show(names, id: command["id"]) }
        if command["situation"] != nil, let id = command["id"] {
            // Where the user is. After every call the server asks only for what tells it of a change, which no
            // app has to answer. For `list_windows` it asks for the line that goes with the list, `detail` being
            // the app listed or "*", and for that app's windows on Spaces the user isn't looking at. This helper
            // answers in half a millisecond, where the `list` command, started anew each time, took 55 ms more.
            let layout = Spaces.layout()
            var reply: [String: Any] = ["id": id, "doing": userActivity()]
            if let app = NSWorkspace.shared.frontmostApplication { reply["app"] = app.localizedName ?? "an app" }
            if let layout { reply["fullscreen"] = !layout.showing.isDisjoint(with: layout.fullScreen) }
            if let detail = command["detail"] as? String {
                let deny = (command["deny"] as? [String]).map { Set($0.map(key)) }
                let windows = (layout?.all.count ?? 0) > 1 ? allWindows() : []
                reply["line"] = userLine(deny: deny, layout: layout, windows: windows)
                reply["screens"] = screens()
                if let layout, !windows.isEmpty {
                    let apps = detail == "*" ? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                                             : [running(detail)].compactMap { $0 }
                    reply["elsewhere"] = apps.filter { !isDenied($0, by: deny) }
                        .flatMap { windowsElsewhere(of: $0, layout: layout, windows: windows) }
                }
            }
            emit(reply)
        }
        if let names = command["park"] as? [String] {
            park(names, onlyHidden: command["onlyHidden"] as? Bool ?? false, id: command["id"])
        }
        if let name = command["borrow"] as? String, let id = command["id"] {
            borrow(name, window: command["window"] as? String ?? "", wait: command["wait"] as? Double ?? 8,
                   pointerOnly: command["pointerOnly"] as? Bool ?? false, id: id)
        }
        if command["quiet"] != nil, let id = command["id"] {
            // Before a window is brought to the user: whether they have stopped typing, waited for as a step that
            // takes the keyboard waits. Six characters went to a window handed over two seconds into a pause.
            let until = Date() + (command["wait"] as? Double ?? 0)
            func check() {
                if Self.secondsSince(.keyDown) >= Self.lendQuiet { return emit(["id": id, "quiet": true]) }
                if Date() >= until { return emit(["id": id, "quiet": false]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
            }
            check()
        }
        if command["giveBack"] != nil { giveBack(id: command["id"]) }
        if command["front"] != nil, let id = command["id"] {
            if lent != nil { keepLending() }
            if let was = lent, was.mode == "borrowed",
               Self.secondsSince(.keyDown) < -was.started.timeIntervalSinceNow { lent?.userTyped = true }
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            var reply: [String: Any] = ["id": id, "front": name]
            if lent?.userTyped == true { reply["typed"] = true }  // the server stops here, and gives the front back
            if let at = command["at"] as? [Double], at.count == 2 {  // and which window a click at this place reaches
                reply["top"] = Self.topWindow(at: CGPoint(x: at[0], y: at[1]))?.number ?? 0
            }
            emit(reply)
        }
        if let name = command["atWork"] as? String, let id = command["id"] {
            // Whether the user is at work in this app right now: in it, and typing, clicking or scrolling.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let inIt = running(name).map { $0.processIdentifier == front } ?? false
            emit(["id": id, "atWork": inIt && Self.userIsActive(within: Self.lendIdle)])
        }
        if command["rest"] != nil { giveBack(id: nil) }  // a turn never ends with the user's screen still lent
        if let text = command["ask"] as? String {
            // The window is the one named, or the one the agent has just brought to the user, which the app is in.
            let app = (command["app"] as? String).flatMap(running)
            let element = app.map { appElement($0.processIdentifier) }
            let named = key(command["window"] as? String ?? "")
            let windows: [AXUIElement] = element.flatMap { attribute($0, kAXWindowsAttribute) } ?? []
            let window = (named.isEmpty ? nil : windows.first { key(title($0)).contains(named) })
                ?? element.flatMap { attribute($0, kAXFocusedWindowAttribute) }
                ?? element.flatMap { attribute($0, kAXMainWindowAttribute) }
            if !text.isEmpty, let app, let window {
                let name = app.localizedName ?? "?"
                ask.show(text, on: app, window: window, color: cursor.color) { [self] clicked in
                    if clicked { emit(["event": "done", "app": name]) }
                    restIfDone()
                }
            } else {
                ask.hide()
                restIfDone()
            }
        }
        if command["desktop"] != nil, let id = command["id"] {
            withDesktop { area in
                let bounds = area.map { [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] }
                emit(["id": id, "bounds": bounds as Any])
            }
        }
    }

    // MARK: lending the front

    // Some steps can't be made behind the user's windows: a scroll or a drag at a place takes the real pointer, and
    // some apps, such as one that shows another computer's screen, take input only while they are in front. For
    // those the app comes to the front, but only once the user has done nothing for a moment, and when the steps are
    // done their app and the pointer are as they were. That also happens by itself when the server stops saying
    // it is at its steps, so one that crashed can't leave the user's screen taken.
    //
    // A window stays where it is. One on an agent's desktop takes the real pointer there, where the user sees none
    // of it: brought to their screen it slides across it, is made to fit there, and ends up under their own windows
    // of that app, which then get the agent's steps. One on their screen is raised over the others for the steps.
    // Only a window on no screen at all comes into sight, and goes back.
    //
    // A user who clicks a window of the app meanwhile has taken it over: it stays as they left it. One who goes to
    // another app stays there, and nothing comes to the front over them.
    struct Lent {
        let app: NSRunningApplication, previous: NSRunningApplication?, pointer: CGPoint?
        let stray: AXUIElement?, strayFrame: CGRect?  // a window that was on no screen, and where it was
        let userWindow: AXUIElement?  // the window of the same app the user was in
        let knownWindow: AXUIElement?  // the window of the app that was known as the user's, for giveKeyboardBack
        let wasHidden: Bool, wasKept: Bool
        // "borrowed": the app came to the front. "front": the user was in that window already. "pointer": the window
        // is on an agent's desktop and only the pointer goes to it. In the last two nothing changed but the pointer.
        let mode: String
        var light: Bool { mode != "borrowed" }
        let started: Date
        var timer: Timer?, userTookIt = false, userActed = false
        // A key pressed while the app is in front is the user's, typing on into a window that came over theirs: the
        // agent's own keys go to its app's process alone, and the HID state this reads doesn't count them. The steps
        // stop at the next one.
        var userTyped = false
    }

    // The keyboard goes with the front, and the user types in bursts: two characters went to a window that came
    // forward two seconds into a pause of theirs. So an app takes the keyboard only after a longer pause in their
    // typing than in the rest of what they do. Four seconds is twice that one pause, and no more than that.
    static let lendIdle = 1.5, lendQuiet = 4.0, lendLimit = 20.0, lendSettle = 2.5, lendNudge = 0.3, lendStill = 0.15
    var lent: Lent?
    var userMonitor: Any?

    func borrow(_ query: String, window named: String, wait: Double, pointerOnly: Bool, id: Any) {
        guard let app = running(query) else { return emit(["id": id, "state": "unknown"]) }
        let pid = app.processIdentifier
        if let lent {  // one app at a time: a second would forget whose turn it is to come back
            if lent.app.processIdentifier != pid {
                return emit(["id": id, "state": "lent", "front": lent.app.localizedName ?? "?"])
            }
            keepLending()
            return emit(["id": id, "state": lent.mode])
        }
        let element = appElement(pid)
        let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
        let wanted = named.isEmpty ? nil : windows.first { key(title($0)).contains(key(named)) }
        let window = wanted ?? attribute(element, kAXMainWindowAttribute) ?? windows.first
        // Whether the user is in that very window: the agent then works there with them, and nothing moves.
        func isTheirs() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let window,
                  let focused: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(window, focused) && !Self.isOutOfSight(window)
        }
        let until = Date() + wait
        func attempt() {
            if lent != nil { return emit(["id": id, "state": "lent", "front": lent?.app.localizedName ?? "?"]) }
            // A scroll goes to the window under the pointer, in front or not. So for a window on an agent's desktop
            // the pointer alone goes there, and the user's app keeps the keyboard.
            let onDesktop = window.map { !app.isHidden && Self.isOnAgentDesktop($0) } ?? false
            let mode = pointerOnly && onDesktop ? "pointer" : isTheirs() ? "front" : "borrowed"
            let typing = mode == "borrowed" && Self.secondsSince(.keyDown) < Self.lendQuiet
            // Wherever the window is, the real pointer is about to move: never while the user types, clicks or
            // scrolls, least of all in that window.
            if !Self.userIsActive(within: Self.lendIdle), !typing {
                // A browser the chat works in with a window of its own has the user's windows too. Bringing it to
                // the front for a moment brings those over the user's app, and takes their keyboard to a window
                // they can't see, which ucu then gives back to theirs in the middle of the steps. So it isn't done.
                if mode == "borrowed", isOwn(app) { return emit(["id": id, "state": "own"]) }
                guard mode != "borrowed" else { return lend(app, window: window, id: id) }
                lent = Lent(app: app, previous: nil, pointer: CGEvent(source: nil)?.location, stray: nil,
                            strayFrame: nil, userWindow: nil, knownWindow: nil, wasHidden: false, wasKept: false,
                            mode: mode, started: Date())
                watchUser()
                keepLending()
                return emit(["id": id, "state": mode])
            }
            if Date() >= until {
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
                return emit(["id": id, "state": "busy", "front": front])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt() }
        }
        attempt()
    }

    func lend(_ app: NSRunningApplication, window: AXUIElement?, id: Any) {
        let pid = app.processIdentifier, name = app.localizedName ?? "?", element = appElement(pid)
        let previous = NSWorkspace.shared.frontmostApplication
        let sameApp = previous?.processIdentifier == pid
        // On no screen at all. A hidden app's windows keep their places, and one on an agent's desktop stays there.
        let stray = window.flatMap { !app.isHidden && Self.isOutOfSight($0) && !Self.isOnAgentDesktop($0) ? $0 : nil }
        lent = Lent(app: app, previous: previous, pointer: CGEvent(source: nil)?.location, stray: stray,
                    strayFrame: stray.flatMap(Self.frame(of:)),
                    userWindow: sameApp ? attribute(element, kAXFocusedWindowAttribute) : nil,
                    knownWindow: userWindows[pid], wasHidden: app.isHidden, wasKept: keptHidden.contains(pid),
                    mode: "borrowed", started: Date())
        allowed = pid
        allowedUntil = Date() + Self.lendLimit + 1  // it stays in front until it is given back
        keptHidden.remove(pid)
        if app.isHidden { app.unhide() }
        if let stray { bringIntoSight(stray) }
        func raise() {
            guard let window else { return }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        raise()
        // Activating brings the app's main window forward and leaves its others behind the user's app. Asking the app
        // itself to be frontmost brings them all, so that is kept for an app that macOS doesn't activate.
        app.activate()
        watchUser()
        keepLending()
        log("\(name) is in front for steps of the agent's that can't be made behind: "
            + (sameApp ? "the window the user was in" : previous?.localizedName ?? "the user's app")
            + " comes back after them")
        final class Settling {
            var cameForward = false, nudged = false, frame: CGRect?, stillSince = Date()
        }
        let asked = Date(), settling = Settling()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] timer in
            let waited = -asked.timeIntervalSinceNow
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                if waited > Self.lendNudge, !settling.nudged {
                    settling.nudged = true
                    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
                guard waited > Self.lendSettle else { return }
                timer.invalidate()
                giveBack(id: nil)
                return emit(["id": id, "state": "failed"])
            }
            if !settling.cameForward {
                settling.cameForward = true
                raise()  // the app came forward with the window that was its main one, which may be another
            }
            // A window that has just come into sight, or to the front, may still be on its way.
            let frame = window.flatMap(Self.frame(of:))
            if frame != settling.frame {
                settling.frame = frame
                settling.stillSince = Date()
            }
            let still = -settling.stillSince.timeIntervalSinceNow >= Self.lendStill
            guard still || waited > Self.lendSettle else { return }
            timer.invalidate()
            emit(["id": id, "state": "borrowed"])
        }
    }

    // The server says it is still at its steps, each time it asks which app is in front. When it stops saying so,
    // the user's app comes back by itself.
    func keepLending() {
        lent?.timer?.invalidate()
        lent?.timer = Timer.scheduledTimer(withTimeInterval: Self.lendLimit, repeats: false) { [self] _ in
            let name = lent?.app.localizedName ?? "?"
            log("\(name) was not given back in \(Int(Self.lendLimit)) seconds, so ucu gives the user's app back itself")
            giveBack(id: nil)
        }
    }

    // The window at a place that a click there reaches: the one in front, of those that apps show in the usual way.
    // An agent's cursor, this chat's or another's, is a window too, just above the one it works in: it takes no
    // clicks, so it doesn't count.
    static func topWindow(at point: CGPoint) -> (number: Int, pid: pid_t)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let helper = ProcessInfo.processInfo.processName
        let top = list.first {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerName as String] as? String) != helper
                && bounds(of: $0).contains(point)
        }
        guard let number = top?[kCGWindowNumber as String] as? Int,
              let pid = top?[kCGWindowOwnerPID as String] as? Int else { return nil }
        return (number, pid_t(pid))
    }

    // What the user does with the mouse while an app is lent. An agent's events carry the process that sent them.
    // A click on a window of the app that the user can see is theirs to keep it.
    func watchUser() {
        guard userMonitor == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]
        userMonitor = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [self] event in
            guard let app = lent?.app, event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == 0
            else { return }
            lent?.userActed = true
            if event.type != .mouseMoved, let pointer = CGEvent(source: nil)?.location, !AgentDesktop.holds(pointer),
               Self.topWindow(at: pointer)?.pid == app.processIdentifier {
                lent?.userTookIt = true
            }
        }
    }

    func giveBack(id: Any?) {
        guard let was = lent else {
            if let id { emit(["id": id, "state": "none"]) }
            return
        }
        lent = nil
        was.timer?.invalidate()
        let app = was.app, pid = app.processIdentifier, name = app.localizedName ?? "?"
        let spent = "\(name) was in front for the agent's steps for "
            + String(format: "%.1f", -was.started.timeIntervalSinceNow) + " s: "
        // The pointer goes back where the user had it, unless they have moved it since. From an agent's desktop it
        // always goes back: there they can't see it.
        func pointerBack() {
            guard let pointer = was.pointer else { return }
            if !was.userActed || CGEvent(source: nil).map({ AgentDesktop.holds($0.location) }) == true {
                CGWarpMouseCursorPosition(pointer)
            }
        }
        if was.light {  // nothing changed but where the pointer is
            pointerBack()
            if let id { emit(["id": id, "state": "returned", "taken": false]) }
            return
        }
        allowedUntil = .distantPast
        var settle = 0.0
        if was.userTookIt {
            if parked[pid] != nil || launchedHidden.contains(pid) {  // an app ucu kept out of sight is theirs now
                bringBack(app)
                rescueStranded(of: app)
            }
            log(spent + "the user took it over, so it stays as it is")
        } else {
            let stillFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            if let stray = was.stray, let frame = was.strayFrame, !app.isTerminated {
                var size = frame.size
                move(stray, to: frame.origin)
                if let value = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(stray, kAXSizeAttribute as CFString, value)
                }
                settle = Self.moveSettle + 0.4
            }
            if was.wasHidden {
                app.hide()
                if was.wasKept { keptHidden.insert(pid) }
            }
            // While it was in front, the window the agent worked in counted as the one the user has in that app,
            // which their keyboard goes back to. It is the one from before again.
            userWindows[pid] = was.knownWindow
            if !stillFront {
                log(spent + "the user went elsewhere meanwhile, and stays there")
            } else if let theirWindow = was.userWindow {
                AXUIElementSetAttributeValue(theirWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(theirWindow, kAXRaiseAction as CFString)
                log(spent + "the window the user was in is back")
            } else if let previous = was.previous, !previous.isTerminated {
                front = previous
                AXUIElementSetAttributeValue(appElement(previous.processIdentifier), kAXFrontmostAttribute as CFString,
                                             kCFBooleanTrue)
                log(spent + "\(previous.localizedName ?? "the user's app") is back")
            }
            pointerBack()
        }
        guard let id else { return }
        // A window on its way back to where it was is read only once it is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            emit(["id": id, "state": "returned", "taken": was.userTookIt])
        }
    }

    func running(_ query: String) -> NSRunningApplication? {
        if let app = known[key(query)], !app.isTerminated { return app }
        known[key(query)] = matching(query)
        return known[key(query)]
    }

    // MARK: quiet launches

    func open(_ query: String, deny: [String], id: Any, desktopFirst: Bool = false) {
        var app = running(query)
        guard let url = app?.bundleURL ?? applicationURL(query) else {
            emit(["id": id, "state": app == nil ? "unknown" : "running"])  // the engine may still find it
            return
        }
        let bundle = Bundle(url: url), info = bundle?.infoDictionary
        let names = [query, url.deletingPathExtension().lastPathComponent,
                     FileManager.default.displayName(atPath: url.path), bundle?.bundleIdentifier,
                     info?["CFBundleName"] as? String, info?["CFBundleDisplayName"] as? String]
        guard Set(names.compactMap { $0 }.map(key)).isDisjoint(with: deny.map(key)) else {
            emit(["id": id, "state": "denied"])
            return
        }
        // The name asked for may not be the one it runs under: "Visual Studio Code" runs as "Code".
        if app == nil, let identifier = bundle?.bundleIdentifier {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
            known[key(query)] = app
        }
        // Some apps show a window in spite of a hidden launch, where they last had one. For an app an agent used
        // before, that is on the agent's desktop, where it shows the user nothing, if the desktop is there by then.
        // Made after the app was open, as it used to be, the desktop came too late: the window, nearly as large as
        // the screen, was on the user's screen for a quarter of a second, and again for a fifth.
        func start(_ state: String, limit: Double) {
            guard desktopFirst else { return launch(url, id: id, state: state, limit: limit) }
            withDesktop { [self] _ in launch(url, id: id, state: state, limit: limit) }
        }
        if let app {
            if app.activationPolicy == .regular, !Self.hasWindows(app) {
                start("reopened", limit: 2)  // the engine needs a window to work on
                return
            }
            emit(["id": id, "state": "running", "active": app.isActive])
            return
        }
        start("opened", limit: Self.noWindowLimit)
    }

    func launch(_ url: URL, id: Any, state: String, limit: Double) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        opening.insert(url.standardizedFileURL)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            DispatchQueue.main.async { [self] in
                opening.remove(url.standardizedFileURL)
                if let app {
                    launchedHidden.insert(app.processIdentifier)
                    if state == "opened" { launchedFresh.insert(app.processIdentifier) }
                }
                keepHidden(app, id: id, state: state, limit: limit)
            }
        }
    }

    // Some apps ignore `hides` or show themselves once their window is up (Blender), and the engine needs that
    // window, so this hides the app until it has one, and for a moment after in case it shows itself again.
    func keepHidden(_ launched: NSRunningApplication?, id: Any?, state: String = "opened",
                    limit: Double = noWindowLimit) {
        func reply(_ state: String) { if let id { emit(["id": id, "state": state]) } }
        guard let app = launched else {
            reply("failed")
            return
        }
        let pid = app.processIdentifier, started = Date(), element = appElement(pid), trusted = AXIsProcessTrusted()
        var finished: Date?, replied: Date?
        keptHidden.insert(pid)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
            if app.isTerminated || !keptHidden.contains(pid) || (app.isActive && Self.userSwitched())
                || clickedDockIcon(of: app)
                || (replied.map { -$0.timeIntervalSinceNow > Self.hideGuard } ?? false) {
                if replied == nil { reply(state) }
                keptHidden.remove(pid)
                timer.invalidate()
                return
            }
            if !app.isHidden { app.hide() }
            if finished == nil, app.isFinishedLaunching { finished = Date() }
            guard replied == nil else { return }
            let list: [AXUIElement] = trusted ? attribute(element, kAXWindowsAttribute) ?? [] : []
            let waited = finished.map { -$0.timeIntervalSinceNow > limit } ?? false
            if (app.isHidden && !list.isEmpty) || (!trusted && finished != nil) || waited
                || -started.timeIntervalSinceNow > Self.openLimit {
                reply(state)
                replied = Date()
            }
        }
    }

    func show(_ names: [String], id: Any?) {
        let apps = names.compactMap(running)
        for app in apps {
            keptHidden.remove(app.processIdentifier)
            launchedHidden.remove(app.processIdentifier)
            if app.isHidden { app.unhide() }
        }
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if apps.allSatisfy({ !$0.isHidden && Self.isOnScreen($0) }) || -started.timeIntervalSinceNow > 2 {
                timer.invalidate()
                if let id { emit(["id": id]) }
            }
        }
    }

    // macOS takes a moment to put a new display in place, and a window moved before that stays where it was.
    func withDesktop(_ action: @escaping (CGRect?) -> Void) {
        let new = desktop.display == nil
        if new { noteUsersWindows() }
        guard desktop.open() else { return action(nil) }
        let started = Date()
        if desktop.isReady { return action(desktop.bounds) }
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] timer in
            if desktop.isReady || -started.timeIntervalSinceNow > 3 {
                timer.invalidate()
                if new { returnStrays() }  // before anything of the agent's goes there
                action(desktop.isReady ? desktop.bounds : nil)
            }
        }
    }

    func park(_ names: [String], onlyHidden: Bool, id: Any?) {
        withDesktop { [self] area in
            if let area {
                // An app that isn't hidden any more is one the user took back.
                let apps = names.compactMap(running).filter {
                    !onlyHidden || $0.isHidden || parked[$0.processIdentifier] != nil
                }
                moveToDesktop(apps, area: area, id: id)
            } else if let id {
                emit(["id": id, "state": "no desktop"])
            }
        }
    }

    // A window moved while its app shows slides there, across the user's screen. Moved while hidden, it is just there.
    func moveToDesktop(_ apps: [NSRunningApplication], area: CGRect, id: Any?) {
        let moved = apps.contains { parked[$0.processIdentifier] == nil }
        var targets = [(NSRunningApplication, CGPoint)]()
        for app in apps {
            if let place = parked[app.processIdentifier] {
                targets.append((app, place.target))
                continue
            }
            app.hide()
            keptHidden.remove(app.processIdentifier)
            let offset = CGFloat(parked.count * 40 + 30)
            let target = CGPoint(x: area.minX + offset, y: area.minY + offset)
            let list: [AXUIElement] = attribute(appElement(app.processIdentifier), kAXWindowsAttribute) ?? []
            var places = [(AXUIElement, CGPoint)]()
            for window in list {
                var origin = CGPoint.zero
                if let value: AXValue = attribute(window, kAXPositionAttribute) {
                    AXValueGetValue(value, .cgPoint, &origin)
                }
                places.append((window, origin))
                move(window, to: target)
            }
            parked[app.processIdentifier] = (app, places, target)
            watchNewWindows(of: app)
            targets.append((app, target))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (moved ? Self.moveSettle : 0)) {
            let started = Date()
            func placed() -> Bool { targets.allSatisfy { !$0.0.isHidden && Self.isOnScreen($0.0, at: $0.1) } }
            func finish() {
                if let id { emit(["id": id, "state": placed() ? "parked" : "no desktop", "moved": moved]) }
            }
            apps.filter(\.isHidden).forEach { $0.unhide() }
            if placed() { return finish() }
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                if placed() || -started.timeIntervalSinceNow > 2 {
                    timer.invalidate()
                    finish()
                }
            }
        }
    }

    func move(_ window: AXUIElement, to point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    // An app opens a new window where it likes, often on the user's screen, so a new window of a parked app joins the
    // others on the desktop as soon as it exists, and again once the app has placed it. Where the app put it is where
    // it goes when the user takes the app back.
    func watchNewWindows(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var made: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().windowCreated(element)
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let observer = made else { return }
        AXObserverAddNotification(observer, appElement(pid), kAXWindowCreatedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func stopWatchingWindows(of pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func windowCreated(_ window: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, parked[pid] != nil else { return }
        keepOnDesktop(window, of: pid)
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in keepOnDesktop(window, of: pid) }
        }
    }

    // As in moveToDesktop, the app hides while its window moves, so the window goes at once instead of sliding across
    // the user's screen.
    func keepOnDesktop(_ window: AXUIElement, of pid: pid_t) {
        guard let place = parked[pid], !Self.isOutOfSight(window) else { return }
        var origin = CGPoint.zero
        if let value: AXValue = attribute(window, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &origin) }
        if !place.places.contains(where: { CFEqual($0.0, window) }) { parked[pid]?.places.append((window, origin)) }
        place.app.hide()
        move(window, to: place.target)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveSettle) { [self] in
            if parked[pid] != nil, place.app.isHidden { place.app.unhide() }
        }
        log("a new window of \(place.app.localizedName ?? "?") joined it on the agent's desktop")
    }

    func bringBack(_ app: NSRunningApplication) {
        launchedHidden.remove(app.processIdentifier)
        guard let place = parked.removeValue(forKey: app.processIdentifier) else { return }
        stopWatchingWindows(of: app.processIdentifier)
        place.places.forEach { move($0.0, to: $0.1) }
        let opened: [AXUIElement] = attribute(appElement(app.processIdentifier), kAXWindowsAttribute) ?? []
        for window in opened where !place.places.contains(where: { CFEqual($0.0, window) }) {
            move(window, to: place.places.first?.1 ?? CGPoint(x: 100, y: 100))  // opened while it was on the desktop
        }
    }

    // AX leaves out windows on other Spaces, but the window server knows them.
    static func hasWindows(_ app: NSRunningApplication) -> Bool {
        let seen: [AXUIElement]? = attribute(appElement(app.processIdentifier), kAXWindowsAttribute)
        guard seen?.isEmpty == true else { return true }
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
                && ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
                && ($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0 > 60
        }
    }

    static func isOnScreen(_ app: NSRunningApplication, at point: CGPoint? = nil) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) else { return false }
            guard let point, let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return true }
            return abs((bounds["X"] ?? .infinity) - point.x) < 2 && abs((bounds["Y"] ?? .infinity) - point.y) < 2
        }
    }

    // The app whose window the user sees on top: the owner of the first ordinary window, front to back, that lies on
    // a screen of theirs. An agent's desktop is a screen for macOS too, and the windows of the app in front come first
    // wherever they are, so those are passed over. Only an app with a Dock icon is one to hand the keyboard to, and
    // not one whose place is the agent's desktop.
    func appInSight(besides skipped: [pid_t]) -> NSRunningApplication? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            let frame = bounds(of: window), bar = CGPoint(x: frame.midX, y: frame.minY + min(frame.height / 2, 20))
            guard frame.height > 60, (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  !AgentDesktop.isOutOfSight(bar),
                  let pid = (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), !skipped.contains(pid),
                  !isKept(pid), let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  !app.isHidden, !app.isTerminated else { continue }
            return app
        }
        return nil
    }

    // MARK: new windows

    func scan() {
        scanDialogs(reporting: true)
        driven.forEach(scanWindows)
    }

    // Windows are compared because an app only announces one once it is on screen, which never happens while the
    // app is hidden. Those already open the first time an app is seen aren't new.
    func scanWindows(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard let list: [AXUIElement] = attribute(appElement(pid), kAXWindowsAttribute) else { return }
        let current = list + list.flatMap { attribute($0, "AXSheets") as [AXUIElement]? ?? [] }
        defer { seenWindows[pid] = current }
        guard let before = seenWindows[pid] else { return }
        for window in current where !before.contains(where: { CFEqual($0, window) }) { appeared(window, in: app) }
    }

    // The window is read a moment later, once it has its content. Menus and tooltips have closed by then.
    func appeared(_ window: AXUIElement, in app: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowSettle) { [self] in
            guard let role: String = attribute(window, kAXRoleAttribute) else { return }
            let subrole: String = attribute(window, kAXSubroleAttribute) ?? ""
            guard role == kAXSheetRole || (role == kAXWindowRole && subrole != kAXUnknownSubrole) else { return }
            let main: AXUIElement? = attribute(appElement(app.processIdentifier), kAXMainWindowAttribute)
            let name = role == kAXSheetRole ? "sheet" : kind(of: window, in: app) ?? "window"
            report(window, owner: app.localizedName ?? "?", kind: name, main: main.map { CFEqual($0, window) } ?? false)
        }
    }

    func report(_ window: AXUIElement?, owner: String, kind: String, main: Bool = false) {
        var event: [String: Any] = ["event": "window", "app": owner, "kind": kind, "main": main]
        if let window {
            let found = contents(of: window)
            event["title"] = title(window)
            event["text"] = found.text == title(window) ? "" : found.text
            event["buttons"] = found.buttons
        }
        emit(event)
    }

    // Password and permission prompts come from system processes, not from the app that caused them, and those
    // processes can't be observed in advance. Their AX windows can still be read once they are on screen.
    func scanDialogs(reporting: Bool) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var told = Set<String>()
        for window in list {
            guard let owner = window[kCGWindowOwnerName as String] as? String, Self.dialogOwners.contains(owner),
                  let id = window[kCGWindowNumber as String] as? Int, seenDialogs.insert(id).inserted,
                  reporting, told.insert(owner).inserted,
                  let pid = window[kCGWindowOwnerPID as String] as? Int else { continue }
            let found: [AXUIElement] = attribute(appElement(pid_t(pid)), kAXWindowsAttribute) ?? []
            report(found.first, owner: owner, kind: "system dialog")
        }
    }

    // MARK: focus

    // The HID state only counts real input, not the events the engine sends to an app.
    static func secondsSince(_ type: CGEventType) -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
    }

    static let gesture = CGEventType(rawValue: 29)!  // trackpad gestures, and on some Macs key presses too

    // Whether the user did anything at all lately. An app takes seconds to start, so this is how a new one counts as
    // theirs: they may have opened it from Spotlight or a link.
    static func userIsActive(within seconds: Double = inputWindow) -> Bool {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel, gesture]
            .contains { secondsSince($0) < seconds }
    }

    // Whether the user may have just switched apps themselves: they clicked a window, a Dock icon or a link another app
    // opens, used a modifier key such as Command-Tab, or hold Return down in Spotlight or another launcher. Typing in
    // the app they are in switches nothing, so it doesn't count: that is when a stolen focus hurts most. Gesture events
    // can't tell a swipe to another Space, since key presses count as gestures too, and macOS's notice of a new Space
    // also comes when an agent's desktop is made, so a swipe is told by the user's app having gone out of sight.
    static func userSwitched() -> Bool {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains { secondsSince($0) < switchWindow }
            || secondsSince(.flagsChanged) < modifierWindow
            || [CGKeyCode(36), CGKeyCode(76)].contains { CGEventSource.keyState(.hidSystemState, key: $0) }
    }

    // Which Dock icon the user clicks is heard as they click. The seconds since the last click, which macOS counts,
    // only show a click half a second after it, so one made just before its app came forward looked like none at
    // all, and a busy app comes forward a second or more after the click. A click an agent sent names the process
    // that sent it, and isn't the user's. Only the Dock is asked, which always answers.
    func noteClick(_ event: NSEvent) {
        guard let click = event.cgEvent, click.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        var item: AXUIElement?
        AXUIElementCopyElementAtPosition(appElement(dock.processIdentifier), Float(click.location.x),
                                         Float(click.location.y), &item)
        let url: URL? = item.flatMap { attribute($0, kAXURLAttribute) }
        let ago = ProcessInfo.processInfo.systemUptime - event.timestamp
        dockClick = url.map { (Date() - ago, $0.standardizedFileURL) }
    }

    // Whether the user's last click, seconds ago at most, was on this app's icon in the Dock. It says which app they
    // asked for, so it holds for longer than a click's time alone, and whatever the agent does meanwhile.
    func clickedDockIcon(of app: NSRunningApplication) -> Bool {
        guard let click = dockClick, -click.at.timeIntervalSinceNow < Self.dockWindow else { return false }
        return click.app == app.bundleURL?.standardizedFileURL
    }

    func activated(_ app: NSRunningApplication) {
        let previous = front, pid = app.processIdentifier, launched = app.launchDate ?? .distantPast
        let isNew = launched > busySince && Date() < busyUntil  // started during the call that is running
        let ours = Date() < oursUntil[pid] ?? .distantPast
        let owned = launchedHidden.contains(pid), name = app.localizedName ?? "?"
        // An app ucu itself is opening is not one the user opened, whatever they do meanwhile. Taken for theirs
        // because they were typing as it started, Windows App kept the front for 6.7 seconds, out of sight on the
        // agent's desktop, and got what they typed. Their click on its Dock icon is still theirs.
        let opened = isNew && (owned || app.bundleURL.map { opening.contains($0.standardizedFileURL) } ?? false)
        // Whether the user came to it is settled here, once, before the app is asked anything: a busy app answers
        // seconds later, and by then their click is no longer new, so it would be undone.
        let onDock = clickedDockIcon(of: app)
        let theirs = onDock || (!ours && !opened && Self.userSwitched())
        // Once it has brought its app forward, the click holds for a moment more and no longer: if they leave the
        // app again, an agent's step that brings it forward seconds later isn't their doing.
        if onDock { dockClick?.at = Date() - Self.dockWindow + Self.switchWindow }
        front = app
        if theirs {  // its windows can't stay hidden, or out of sight
            let kept = owned || parked[pid] != nil
            keptHidden.remove(pid)
            bringBack(app)
            rescueStranded(of: app)
            if kept {  // the agent hears that the app is on the user's screen now, and whose it is
                let names = known.filter { $0.value.processIdentifier == pid }.map(\.key)
                emit(["event": "taken", "app": name, "names": names])
            }
        }
        guard let previous, previous.processIdentifier != pid, !(pid == allowed && Date() < allowedUntil)
        else { return }
        // An app that has quit can't have the front back, so the one macOS brings forward then is left alone. Unless
        // that one has no window in the user's sight: the front goes on to the app whose window they see on top.
        if previous.isTerminated {
            if isUnseen(app) { passOn(from: app, past: previous) }
            return
        }
        let over = "\(name) came forward over \(previous.localizedName ?? "?")"
        // A new app is held back while a call runs, unless the user did anything since just before it started.
        if isNew {
            guard !theirs, opened || !Self.userIsActive(within: -launched.timeIntervalSinceNow + Self.inputWindow)
            else { return log("\(over) as it started: left in front, as the user may have opened it") }
            putBack(previous, over: app, why: opened ? "ucu was opening it" : "it started while the agent worked")
            if parked[pid] == nil { keepHidden(app, id: nil) }
            return
        }
        // An app this chat drives can't come forward by itself while the chat works and for a while after, nor one ucu
        // opened, whose place is out of sight, while the chat runs. When the agent is bringing it forward, the user's
        // clicks elsewhere have nothing to do with it. The user's app must still be in sight: if it isn't, they went to
        // another Space themselves.
        // Nor can one whose windows the agent keeps on its desktop, while none of them is in the user's sight: in front,
        // it has their keyboard in a window they can't see.
        let unseen = parked[pid] != nil && !hasWindowInSight(app)
        guard (Date() < guardUntil && driven.contains(app)) || owned || ours || unseen else { return }
        // A click on the app's own window is the user's, even as the agent's step brings the app forward.
        if ours, Self.clicked(app) {
            giveKeyboardBack(in: app)
            return log("\(over): left in front, as the user clicked it")
        }
        // Where the agent works in a window of its own, ucu hears of each step of the agent's that brings the app
        // forward. At any other time it is the user who comes to it, to a window of theirs, and input doesn't tell
        // that well: a link they click opens its page seconds later, and a launcher takes only keys.
        if !ours, isOwn(app), hasWindowInSight(app) {
            giveKeyboardBack(in: app)
            return log("\(over): left in front, as no step of the agent's was bringing it forward")
        }
        if theirs {
            giveKeyboardBack(in: app)
            return log("\(over): left in front, as the user clicked \(onDock ? "its Dock icon" : "or switched apps")")
        }
        if isGone(previous) {
            // That holds for an app with a window on a Space of theirs. One with no window in their sight is on no
            // Space they could have gone to: macOS brought it because it was next in line, as when ucu hides the app in
            // front to move it to the agent's desktop. So the front goes to the app whose window they see on top.
            guard unseen else { return log("\(over): left in front, as the user's app was out of sight") }
            return passOn(from: app, past: previous)
        }
        putBack(previous, over: app, ours: ours, why: ours ? "the agent's step brought it" : "it came by itself")
        if owned, parked[pid] == nil { app.hide() }  // without a desktop, ucu's app goes back into hiding
    }

    func isOwn(_ app: NSRunningApplication) -> Bool {
        [app.localizedName, app.bundleIdentifier].contains { $0.map { own.contains(key($0)) } ?? false }
    }

    func hasWindowInSight(_ app: NSRunningApplication) -> Bool {
        let windows: [AXUIElement] = attribute(appElement(app.processIdentifier), kAXWindowsAttribute) ?? []
        return windows.contains { !Self.isOutOfSight($0) && !flag($0, kAXMinimizedAttribute) }
    }

    // Whether an app's windows are all where the agent keeps them, on its desktop, with none in the user's sight.
    func isUnseen(_ app: NSRunningApplication) -> Bool {
        parked[app.processIdentifier] != nil && !hasWindowInSight(app)
    }

    // Whether ucu keeps an app's windows on the agent's desktop while no request of the agent's has it in front.
    func isKept(_ pid: pid_t) -> Bool {
        parked[pid] != nil && !(pid == allowed && Date() < allowedUntil)
    }

    // Whether an app can't have the front back: it has quit, is hidden or shows no window, or its place is the
    // agent's desktop. One that ucu is moving there is hidden for the move, and says so itself a moment late.
    func isGone(_ app: NSRunningApplication) -> Bool {
        app.isTerminated || app.isHidden || !Self.isOnScreen(app) || isKept(app.processIdentifier)
    }

    // Whether the user's last click, a moment ago, was on a window of this app.
    static func clicked(_ app: NSRunningApplication) -> Bool {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(where: { secondsSince($0) < switchWindow }),
              let pointer = CGEvent(source: nil)?.location else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let top = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && bounds(of: $0).contains(pointer) }
        return (top?[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
    }

    // The front goes from an app with no window in the user's sight to the app whose window they see on top, when the
    // one it came forward over can't have it back. The windows on screen change while an app quits or hides, so with
    // no such app it looks again.
    func passOn(from app: NSRunningApplication, past lost: NSRunningApplication, tries: Int = putBackTries) {
        if let seen = appInSight(besides: [app.processIdentifier, lost.processIdentifier]) {
            let why = "neither has a window in the user's sight, so \(seen.localizedName ?? "?") has the front"
            return putBack(seen, over: app, past: lost, why: why)
        }
        guard tries > 1 else {
            return log("\(app.localizedName ?? "?") came forward over \(lost.localizedName ?? "?"): left in front, "
                       + "as the user's app was out of sight")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.putBackCheck) { [self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier, isUnseen(app)
            else { return }
            passOn(from: app, past: lost, tries: tries - 1)
        }
    }

    // The user's app comes back to the front. Asking it can fail while it is busy, so it is asked again. `lost` is the
    // app that was in front, when that one can't have the front back and another app of the user's gets it.
    func putBack(_ previous: NSRunningApplication, over app: NSRunningApplication, past lost: NSRunningApplication? = nil,
                 ours: Bool = false, why: String, tries: Int = putBackTries) {
        front = previous
        AXUIElementSetAttributeValue(appElement(previous.processIdentifier), kAXFrontmostAttribute as CFString,
                                     kCFBooleanTrue)
        if tries == Self.putBackTries {
            let over = (lost ?? previous).localizedName ?? "?"
            emit(["event": "focus", "app": app.localizedName ?? "?", "back": previous.localizedName ?? "?"])
            log("\(app.localizedName ?? "?") came forward over \(over), as \(why): put back")
        }
        guard tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.putBackCheck) { [self] in
            let stays = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            guard stays, ours ? !Self.clicked(app) : !Self.userSwitched() else { return }
            // The app that was asked may have gone since: it was on its way out as this one came forward.
            if isUnseen(app), isGone(previous) { return passOn(from: app, past: lost ?? previous) }
            if tries == 2 { log("\(app.localizedName ?? "?") stayed in front after ucu asked twice: asking once more") }
            putBack(previous, over: app, past: lost, ours: ours, why: why, tries: tries - 1)
        }
    }

    // A line in ~/Library/Logs/ucu/focus.log, so that "an app took my focus" can be checked. It names apps, never
    // window titles, and only those this chat drives.
    func log(_ text: String) {
        let path = NSHomeDirectory() + "/Library/Logs/ucu/focus.log", files = FileManager.default
        try? files.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        if let size = (try? files.attributesOfItem(atPath: path))?[.size] as? Int, size > Self.logLimit {
            try? files.removeItem(atPath: path + ".1")
            try? files.moveItem(atPath: path, toPath: path + ".1")
        }
        let line = Data("\(Self.stamp.string(from: Date())) \(who) \(text)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            files.createFile(atPath: path, contents: line)
        }
    }

    static let logLimit = 1_000_000
    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // In the app the user is in, a window out of their sight can get the keyboard, such as the agent's browser
    // window on its desktop when it shows or opens a popup, and their typing would go there. So their window gets it
    // back. Behind another app there is no keyboard to take, and the user's window gets it as they come to the app.
    func guardWindow() {
        for app in driven where app.isActive && !app.isTerminated && !app.isHidden
            && parked[app.processIdentifier] == nil {
            giveKeyboardBack(in: app)
        }
    }

    func giveKeyboardBack(in app: NSRunningApplication) {
        let pid = app.processIdentifier, element = appElement(pid)
        guard let current: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return }
        guard Self.isOutOfSight(current) else {
            userWindows[pid] = current
            return
        }
        // On no screen, it may be a window the user is moving. On an agent's desktop it is never theirs.
        if !Self.isOnAgentDesktop(current), Self.userSwitched() { return }
        let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
        let known = userWindows[pid].flatMap { mine in windows.first { CFEqual($0, mine) } }
        let inSight = windows.first { !Self.isOutOfSight($0) && !flag($0, kAXMinimizedAttribute) }
        guard let theirs = known ?? inSight else { return }
        AXUIElementSetAttributeValue(theirs, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(theirs, kAXRaiseAction as CFString)
        log("\(app.localizedName ?? "?") gave a window out of sight the keyboard: the user's window got it back")
        emit(["event": "focus", "app": app.localizedName ?? "?", "back": title(theirs), "window": true])
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let place: AXValue = attribute(window, kAXPositionAttribute), AXValueGetValue(place, .cgPoint, &origin)
        else { return nil }
        if let value: AXValue = attribute(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    // The middle of a window's title bar, which says what screen it is on.
    static func titleBar(of window: AXUIElement) -> CGPoint? {
        frame(of: window).map { CGPoint(x: $0.midX, y: $0.minY + min($0.height / 2, 20)) }
    }

    // Whether a window is where the user can't see it: on an agent's desktop, or on no screen.
    static func isOutOfSight(_ window: AXUIElement) -> Bool {
        titleBar(of: window).map(AgentDesktop.isOutOfSight) ?? false
    }

    static func isOnAgentDesktop(_ window: AXUIElement) -> Bool {
        titleBar(of: window).map(AgentDesktop.holds) ?? false
    }
}

// Where a window goes when the user asked to see it and it was on an agent's desktop: the screen with the menu bar.
func bringIntoSight(_ window: AXUIElement) {
    guard let screen = NSScreen.screens.first else { return }
    let area = screen.visibleFrame, top = screen.frame.height - area.maxY  // windows count from the top, screens up
    var point = CGPoint(x: area.minX + 40, y: top + 40)
    if let value = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
}

// The menu item a shortcut such as "cmd+shift+t" stands for, and its menu path. Menus give their shortcut's key as a
// character, or as a key code for keys such as Return, and their modifiers as bits: 1 Shift, 2 Option, 4 Control, and
// 8 when Command isn't one of them.
func menuItem(for shortcut: String, in element: AXUIElement) -> (AXUIElement, String)? {
    let parts = shortcut.lowercased().split(separator: "+").map(String.init)
    guard let key = parts.last, !key.isEmpty, let bar: AXUIElement = attribute(element, kAXMenuBarAttribute) else {
        return nil
    }
    let held = Set(parts.dropLast())
    let bits = (held.contains("shift") ? 1 : 0) | (held.isDisjoint(with: ["alt", "option", "opt"]) ? 0 : 2)
        | (held.isDisjoint(with: ["ctrl", "control"]) ? 0 : 4)
        | (held.isDisjoint(with: ["cmd", "command", "meta"]) ? 8 : 0)
    let codes = ["return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53,
                 "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116,
                 "pagedown": 121, "forwarddelete": 117, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
                 "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111]
    var queue: [(AXUIElement, String)] = [(bar, "")], visited = 0
    while visited < queue.count, visited < 4000 {
        let (node, path) = queue[visited]
        visited += 1
        let name: String = attribute(node, kAXTitleAttribute) ?? ""
        let here = name.isEmpty ? path : (path.isEmpty ? name : "\(path) > \(name)")
        if (attribute(node, kAXRoleAttribute) as String?) == kAXMenuItemRole,
           (attribute(node, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0 == bits,
           (attribute(node, kAXEnabledAttribute) as Bool?) ?? false {
            let char: String? = attribute(node, kAXMenuItemCmdCharAttribute)
            let code: Int? = attribute(node, kAXMenuItemCmdVirtualKeyAttribute)
            if char.map({ $0.lowercased() == key }) ?? false || (codes[key] != nil && code == codes[key]) {
                return (node, here)
            }
        }
        queue += (attribute(node, kAXChildrenAttribute) as [AXUIElement]? ?? []).map { ($0, here) }
    }
    return nil
}

// Choose the menu command at a path such as "File > New Window". A path that ends at a menu, or goes wrong, fails
// with what that menu holds, which is how an agent finds a command it doesn't know the name of.
func chooseMenuItem(at path: String, in element: AXUIElement) -> Never {
    func plain(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    func items(of node: AXUIElement) -> [AXUIElement] {
        let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) ?? []
        let menu = children.first { (attribute($0, kAXRoleAttribute) as String?) == kAXMenuRole }
        return menu.map { attribute($0, kAXChildrenAttribute) ?? [] } ?? children
    }
    func names(_ list: [AXUIElement]) -> String {
        let all = list.compactMap { attribute($0, kAXTitleAttribute) as String? }.filter { !$0.isEmpty }
        return all.prefix(40).joined(separator: ", ") + (all.count > 40 ? ", and \(all.count - 40) more" : "")
    }
    guard let bar: AXUIElement = attribute(element, kAXMenuBarAttribute) else { fail("The app has no menu bar.") }
    var level = Array(items(of: bar).dropFirst()), here = "The menu bar", found: AXUIElement?  // without the Apple menu
    for part in path.split(separator: ">").map({ plain(String($0)) }) where !part.isEmpty {
        guard let next = level.first(where: { plain(attribute($0, kAXTitleAttribute) ?? "") == part }) else {
            fail("\(here) has no \"\(part)\". It has: \(names(level)).", 2)
        }
        found = next
        here = attribute(next, kAXTitleAttribute) ?? part
        level = items(of: next)
    }
    guard let item = found else { fail("The menu bar has: \(names(level)).", 2) }
    guard level.isEmpty else { fail("\(here) is a menu. It has: \(names(level)).", 2) }
    guard (attribute(item, kAXEnabledAttribute) as Bool?) ?? false else { fail("\(here) is disabled right now.", 5) }
    let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard pressed == .success else { fail("\(here) didn't take the press (\(pressed.rawValue)).", 5) }
    print("chose \(here)")
    exit(0)
}

let watcher = Watcher()
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: ucu-window list [app] | focus <app> <title> [--unfullscreen] [--activate] | "
        + "unfullscreen <app> <title> | press <app> <shortcut> | menu <app> <path> | watch")
}
if command == "watch" { watcher.run() }
if command == "list", args.count == 1 {
    requireTrust()
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let (element, list) = windows(of: app)
        if !list.isEmpty { printWindows(of: app, element: element, list: list) }
    }
    exit(0)
}
guard args.count >= 2 else { fail("usage: ucu-window \(command) <app>") }
let app = runningApp(args[1])
let (element, list) = windows(of: app)

switch command {
case "list":
    printWindows(of: app, element: element, list: list)
case "focus", "unfullscreen":
    guard args.count >= 3 else { fail("usage: ucu-window \(command) <app> <title substring>") }
    let window = find(args[2], in: list)
    if command == "unfullscreen" || args.contains("--unfullscreen") { leaveFullScreen(window) }
    if command == "focus" {
        if flag(window, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if args.contains("--activate") {
            if Watcher.isOutOfSight(window) { bringIntoSight(window) }  // the user asked to see it
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            app.unhide()
            // macOS doesn't activate every app it is asked to, and says nothing of it: a program run from a terminal
            // stayed behind while its window was reported as main. The app itself, asked to be in front, comes.
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate()
            for _ in 0..<50 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                usleep(10_000)
            }
        }
        for _ in 0..<20 where !isMain(window, of: element) { usleep(10_000) }
    }
    var main = isMain(window, of: element)
    // Brought to the user, a window is in front of them once its app is in front and it is in their sight, whether
    // or not it is the app's main window, so that alone is no failure. The app is asked itself whether it is in
    // front, and given a moment: the server moves its windows to the user's screen meanwhile. It can come forward
    // with another of its windows as the one the user is in, over the one asked for, so that one is raised again
    // once the app is there. If they still aren't in it, the result says so: a label shows only once they are.
    var shown = false, elsewhere = false
    if command == "focus", !main, args.contains("--activate") {
        func arrived() -> Bool { flag(element, kAXFrontmostAttribute) && !Watcher.isOutOfSight(window) }
        func userIsInIt() -> Bool {
            guard let current: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(current, window) || AskLabel.isSheet(current, of: window)
        }
        for _ in 0..<250 where !arrived() { usleep(10_000) }
        shown = arrived()
        if shown, !userIsInIt() {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            for _ in 0..<15 where !userIsInIt() { usleep(10_000) }
            if !userIsInIt() {  // raised, and another window still has the keyboard
                AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                for _ in 0..<15 where !userIsInIt() { usleep(10_000) }
            }
            main = isMain(window, of: element)
        }
        let current = (attribute(element, kAXFocusedWindowAttribute) as AXUIElement?)
            ?? attribute(element, kAXMainWindowAttribute)
        elsewhere = shown && !AskLabel.belongs(current, to: window)
    }
    let sheet = args.contains("--activate") && AskLabel.hasSheet(window)  // which the user must answer first
    print("\"\(title(window))\" main=\(main) fullscreen=\(flag(window, "AXFullScreen")) frame=\(frame(window))"
          + (sheet ? " under=sheet" : "") + (elsewhere ? " user=elsewhere" : ""))
    exit(command == "focus" && !main && !shown ? 4 : 0)
case "press":
    guard args.count >= 3 else { fail("usage: ucu-window press <app> <shortcut>") }
    guard let (item, path) = menuItem(for: args[2], in: element) else {
        fail("No menu item of \(app.localizedName ?? "the app") has the shortcut \(args[2]).", 2)
    }
    let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard pressed == .success else { fail("\(path) didn't take the press (\(pressed.rawValue)).", 5) }
    print("pressed \(path)")
case "menu":
    guard args.count >= 3 else { fail("usage: ucu-window menu <app> <path>") }
    chooseMenuItem(at: args[2], in: element)
default:
    fail("unknown command \(command)")
}
