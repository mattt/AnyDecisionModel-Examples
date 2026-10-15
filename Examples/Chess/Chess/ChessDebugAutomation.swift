#if DEBUG
import AppKit

/// Debug-only launch options for inspecting the interface without system permissions.
///
/// - `-ChessAppearance light|dark|contrastLight|contrastDark` sets the app appearance.
/// - `-ChessWindowSize 900x620` resizes the window, and `-ChessFullScreen YES` enters full screen.
/// - `-ChessKeys "tab,right,return"` posts key events to the app's own window.
///   Tokens are `up`, `down`, `left`, `right`, `return`, `space`, `escape`, `tab`,
///   a letter with modifiers such as `cmd+shift+f`, and `wait` for a one-second pause.
/// - `-ChessSnapshot name` writes `name.png`, `name-menus.txt`, and `name-accessibility.txt`
///   to the app container's temporary directory and then quits.
@MainActor
enum ChessDebugAutomation {
    static func run() async {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "ChessAppearance") {
            NSApp.appearance = switch name {
            case "dark": NSAppearance(named: .darkAqua)
            case "contrastLight": NSAppearance(named: .accessibilityHighContrastAqua)
            case "contrastDark": NSAppearance(named: .accessibilityHighContrastDarkAqua)
            default: NSAppearance(named: .aqua)
            }
        }
        let keys = defaults.string(forKey: "ChessKeys")
        let snapshot = defaults.string(forKey: "ChessSnapshot")
        let size = defaults.string(forKey: "ChessWindowSize")
        let fullScreen = defaults.bool(forKey: "ChessFullScreen")
        guard keys != nil || snapshot != nil || size != nil || fullScreen else { return }

        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if let size {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                var frame = window.frame
                frame.size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: parts[0], height: parts[1])).size
                window.setFrame(frame, display: true)
            }
        }
        if fullScreen {
            window.toggleFullScreen(nil)
            try? await Task.sleep(for: .seconds(2))
        }
        for token in keys?.split(separator: ",").map(String.init) ?? [] {
            if token == "wait" {
                try? await Task.sleep(for: .seconds(1))
            } else {
                post(token, to: window)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let snapshot else { return }
        try? await Task.sleep(for: .seconds(1))
        let directory = FileManager.default.temporaryDirectory
        capture(window, to: directory.appending(path: "\(snapshot).png"))
        try? describeMenus().write(
            to: directory.appending(path: "\(snapshot)-menus.txt"),
            atomically: true,
            encoding: .utf8
        )
        try? describeAccessibility(of: window).write(
            to: directory.appending(path: "\(snapshot)-accessibility.txt"),
            atomically: true,
            encoding: .utf8
        )
        NSApp.terminate(nil)
    }

    private static func post(_ token: String, to window: NSWindow) {
        let parts = token.split(separator: "+").map(String.init)
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let key = parts.last ?? ""
        let (characters, keyCode): (String, UInt16) = switch key {
        case "up": (String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), 126)
        case "down": (String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125)
        case "left": (String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), 123)
        case "right": (String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), 124)
        case "return": ("\r", 36)
        case "space": (" ", 49)
        case "escape": ("\u{1B}", 53)
        case "tab": ("\t", 48)
        default: (key, letterKeyCodes[key] ?? 0)
        }
        if [123, 124, 125, 126].contains(keyCode) {
            flags.insert([.numericPad, .function])
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static let letterKeyCodes: [String: UInt16] = [
        "a": 0, "b": 11, "f": 3, "i": 34, "n": 45, "r": 15,
    ]

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        try? representation.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func describeMenus() -> String {
        var lines: [String] = []
        func visit(_ menu: NSMenu, depth: Int) {
            menu.update()
            for item in menu.items {
                let indent = String(repeating: "  ", count: depth)
                if item.isSeparatorItem {
                    lines.append("\(indent)---")
                    continue
                }
                var shortcut = ""
                if !item.keyEquivalent.isEmpty {
                    let modifiers = item.keyEquivalentModifierMask
                    if modifiers.contains(.control) { shortcut += "⌃" }
                    if modifiers.contains(.option) { shortcut += "⌥" }
                    if modifiers.contains(.shift) { shortcut += "⇧" }
                    if modifiers.contains(.command) { shortcut += "⌘" }
                    shortcut += item.keyEquivalent == String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
                        ? "→"
                        : item.keyEquivalent.uppercased()
                }
                let state = item.state == .on ? "✓ " : ""
                let enabled = item.isEnabled ? "" : " (disabled)"
                lines.append("\(indent)\(state)\(item.title) \(shortcut)\(enabled)")
                if let submenu = item.submenu {
                    visit(submenu, depth: depth + 1)
                }
            }
        }
        if let menu = NSApp.mainMenu {
            visit(menu, depth: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func describeAccessibility(of window: NSWindow) -> String {
        var lines: [String] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40, let element = element as? any NSAccessibilityProtocol else { return }
            let role = element.accessibilityRole()?.rawValue ?? "?"
            let label = element.accessibilityLabel() ?? ""
            let value = element.accessibilityValue().map { "\($0)" } ?? ""
            let title = element.accessibilityTitle() ?? ""
            let text = [title, label, value].filter { !$0.isEmpty }.joined(separator: " | ")
            lines.append(String(repeating: "  ", count: depth) + "\(role) \(text)")
            for child in element.accessibilityChildren() ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(window, depth: 0)
        return lines.joined(separator: "\n")
    }
}
#endif
