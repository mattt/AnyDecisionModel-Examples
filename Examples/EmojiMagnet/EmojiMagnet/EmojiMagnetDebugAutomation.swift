#if DEBUG
import AppKit
import SpriteKit

/// Debug-only launch options for inspecting the interface without system permissions.
///
/// - `-EmojiMagnetAppearance light|dark` sets the app appearance.
/// - `-EmojiMagnetWindowSize 1000x720` resizes the window.
/// - `-EmojiMagnetReduceMotion YES` uses the Reduce Motion layout.
/// - `-EmojiMagnetSteps "type:things you wear|settle|snap:clothing"` runs steps separated by `|`:
///   - `type:<phrase>` sets the phrase, as typing would.
///   - `settle` waits until the model finishes, then waits two seconds for the physics.
///   - `pause:<seconds>` waits.
///   - `key:escape` posts a key event to the window.
///   - `toss:<item>,<dx>,<dy>` drags an item by the offset in 0.15 seconds and releases it.
///   - `size:<width>x<height>` resizes the window.
///   - `snap:<name>` writes `<name>.png`, `<name>-accessibility.txt`, and `<name>-matches.txt`.
///   - `quit` ends the app.
///
/// Files go to the app container's temporary directory,
/// with a timing log in `EmojiMagnetSteps.log`.
@MainActor
enum EmojiMagnetDebugAutomation {
    static var reducesMotion: Bool {
        UserDefaults.standard.bool(forKey: "EmojiMagnetReduceMotion")
    }

    static func run(controller: EmojiMagnetController) async {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "EmojiMagnetAppearance") {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        let steps = defaults.string(forKey: "EmojiMagnetSteps")
        let size = defaults.string(forKey: "EmojiMagnetWindowSize")
        guard steps != nil || size != nil else { return }

        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if let size {
            resize(window, to: size)
        }
        var log = Log()
        var typedAt = ContinuousClock.now
        for step in steps?.split(separator: "|").map(String.init) ?? [] {
            let (command, argument) = step.firstIndex(of: ":").map {
                (String(step[..<$0]), String(step[step.index(after: $0)...]))
            } ?? (step, "")
            switch command {
            case "type":
                controller.setPhrase(argument)
                typedAt = .now
                log.append("type \"\(argument)\"")
            case "settle":
                // Wait for the debounce to start the evaluation, then for the model.
                let deadline = ContinuousClock.now + .seconds(5)
                while !controller.isEvaluating, controller.errorMessage == nil, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                while controller.isLoading || controller.isEvaluating {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                log.append("settled after \(typedAt.duration(to: .now).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))) with \(controller.attractedItems.map(\.id))")
                try? await Task.sleep(for: .seconds(2))
            case "pause":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "key":
                postKey(argument, to: window)
                try? await Task.sleep(for: .milliseconds(250))
            case "toss":
                await toss(argument, in: window)
            case "size":
                resize(window, to: argument)
                try? await Task.sleep(for: .seconds(1))
            case "snap":
                snapshot(argument, window: window, controller: controller)
                log.append("snapshot \(argument)")
            case "quit":
                log.write()
                NSApp.terminate(nil)
            default:
                log.append("unknown step \(step)")
            }
        }
        log.write()
    }

    private struct Log {
        var lines: [String] = []

        mutating func append(_ line: String) {
            lines.append("\(Date.now.formatted(.iso8601)) \(line)")
            write()
        }

        func write() {
            let url = FileManager.default.temporaryDirectory.appending(path: "EmojiMagnetSteps.log")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func resize(_ window: NSWindow, to size: String) {
        let parts = size.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        var frame = window.frame
        frame.size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: parts[0], height: parts[1])).size
        window.setFrame(frame, display: true)
    }

    private static func postKey(_ key: String, to window: NSWindow) {
        let (characters, keyCode): (String, UInt16) = switch key {
        case "escape": ("\u{1B}", 53)
        case "tab": ("\t", 48)
        case "return": ("\r", 36)
        default: (key, 0)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
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

    private static func toss(_ argument: String, in window: NSWindow) async {
        let parts = argument.split(separator: ",").map(String.init)
        guard parts.count == 3,
              let dx = Double(parts[1]),
              let dy = Double(parts[2]),
              let scene = MagnetScene.current,
              let view = scene.view,
              let position = scene.position(of: parts[0])
        else { return }
        let start = view.convert(scene.convertPoint(toView: position), to: nil)
        let steps = 10
        for step in 0 ... steps + 1 {
            let type: NSEvent.EventType = switch step {
            case 0: .leftMouseDown
            case steps + 1: .leftMouseUp
            default: .leftMouseDragged
            }
            let fraction = Double(min(step, steps)) / Double(steps)
            let point = NSPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func snapshot(_ name: String, window: NSWindow, controller: EmojiMagnetController) {
        let directory = FileManager.default.temporaryDirectory
        if let view = window.contentView?.superview,
           let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: representation)
            // SpriteKit draws with Metal, which `cacheDisplay` does not capture, so draw the scene on top.
            if let scene = MagnetScene.current, let skView = scene.view,
               let texture = skView.texture(from: scene, crop: CGRect(origin: .zero, size: scene.size)),
               let context = NSGraphicsContext(bitmapImageRep: representation)
            {
                let image = texture.cgImage()
                let frame = skView.convert(skView.bounds, to: view)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.draw(image, in: frame)
                NSGraphicsContext.restoreGraphicsState()
            }
            try? representation.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "\(name).png"))
        }
        try? describeAccessibility(of: window).write(
            to: directory.appending(path: "\(name)-accessibility.txt"),
            atomically: true,
            encoding: .utf8
        )
        let matches = controller.catalog.compactMap { item -> String? in
            guard let probability = controller.probabilities[item.id] else { return nil }
            let mark = controller.attractedIDs.contains(item.id) ? "match" : "     "
            return "\(mark) \(String(format: "%.3f", probability)) \(item.glyph) \(item.id)"
        }
        var geometry = ""
        if let scene = MagnetScene.current, let skView = scene.view {
            let coat = scene.position(of: "coat").map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "none"
            geometry = "scene: \(scene.size), view: \(skView.bounds.size), coat: \(coat), "
                + "first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"), "
                + "key window: \(window.isKeyWindow)"
        }
        let attraction = MagnetScene.current?.attractionReport() ?? []
        try? (["phrase: \(controller.phrase)", geometry] + attraction + matches).joined(separator: "\n").write(
            to: directory.appending(path: "\(name)-matches.txt"),
            atomically: true,
            encoding: .utf8
        )
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
