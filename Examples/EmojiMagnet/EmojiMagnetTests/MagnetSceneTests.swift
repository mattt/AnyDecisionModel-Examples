import AppKit
import SpriteKit
import Testing

@testable import EmojiMagnet

@Suite("Magnet physics", .serialized)
@MainActor
struct MagnetSceneTests {
    private func makeScene(items: [EmojiItem] = EmojiCatalog.items) -> MagnetScene {
        let scene = MagnetScene(items: items)
        scene.size = CGSize(width: 1_000, height: 600)
        scene.update(0)
        return scene
    }

    private func present(_ scene: MagnetScene) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: scene.size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = SKView(frame: CGRect(origin: .zero, size: scene.size))
        window.contentView = view
        view.presentScene(scene)
        window.orderFront(nil)
        return window
    }

    private func close(_ window: NSWindow) {
        (window.contentView as? SKView)?.presentScene(nil)
        window.close()
    }

    @Test func transparentCornersDoNotRestartAFall() throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(1)))
        let node = try #require(scene.childNode(withName: "coat"))
        node.position = CGPoint(x: 200, y: 25)
        node.zRotation = .pi / 4
        node.physicsBody?.velocity = CGVector(dx: 10, dy: 0)
        scene.update(1.0 / 60)
        scene.didSimulatePhysics()
        #expect(node.position == CGPoint(x: 200, y: 25))
        #expect(abs(node.zRotation - .pi / 4) < 0.0001)
    }

    @Test func escapedItemsReturnToTheNearestEdge() throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(1)))
        let node = try #require(scene.childNode(withName: "coat"))
        node.position = CGPoint(x: -40, y: 150)
        node.physicsBody?.velocity = CGVector(dx: -500, dy: -50)
        scene.update(1.0 / 60)
        scene.didSimulatePhysics()
        #expect(node.position.x >= 0)
        #expect(node.position.y == 150)
        #expect(node.physicsBody?.velocity.dx == 0)
        #expect(node.physicsBody?.velocity.dy == -50)
    }

    @Test func resizingKeepsExistingNodesNearTheirPreviousPositions() throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(1)))
        let node = try #require(scene.childNode(withName: "coat"))
        node.position = CGPoint(x: 950, y: 150)
        scene.size = CGSize(width: 720, height: 429)
        scene.update(1.0 / 60)
        #expect(scene.childNode(withName: "coat") === node)
        #expect(node.position.x <= 720)
        #expect(node.position.y == 150)

        node.position = CGPoint(x: 710, y: 420)
        node.zRotation = .pi / 4
        scene.size = CGSize(width: 700, height: 400)
        scene.update(2.0 / 60)
        #expect(scene.frame.contains(node.frame))
    }

    @Test func queuedMatchesAndMotionSettingsApplyWhenItemsAreCreated() throws {
        let scene = MagnetScene(items: Array(EmojiCatalog.items.prefix(2)))
        scene.setAttracted(["coat"])
        scene.setReducesMotion(true)
        scene.size = CGSize(width: 720, height: 429)
        scene.update(0)
        let coat = try #require(scene.childNode(withName: "coat"))
        let scarf = try #require(scene.childNode(withName: "scarf"))
        #expect(coat.position == MagnetLayout.gatherTargets(count: 1, in: scene.size)[0])
        #expect(coat.physicsBody?.isDynamic == false)
        #expect(scarf.physicsBody?.isDynamic == false)

        scene.setReducesMotion(false)
        scene.update(1.0 / 60)
        let coatBody = try #require(coat.physicsBody)
        let scarfBody = try #require(scarf.physicsBody)
        // This item is already at its target after leaving Reduce Motion.
        #expect(!coatBody.isDynamic)
        #expect(!coatBody.affectedByGravity)
        #expect(scarfBody.affectedByGravity)
        #expect(coatBody.collisionBitMask & scarfBody.categoryBitMask == 0)
        #expect(scarfBody.collisionBitMask & coatBody.categoryBitMask == 0)

        scene.setAttracted([])
        scene.update(2.0 / 60)
        #expect(coatBody.isDynamic)
        #expect(coatBody.affectedByGravity)
        #expect(coatBody.collisionBitMask & scarfBody.categoryBitMask != 0)
        #expect(scarfBody.collisionBitMask & coatBody.categoryBitMask != 0)
    }

    @Test func initialRowsFitTheSmallestWindow() throws {
        let scene = MagnetScene(items: EmojiCatalog.items)
        scene.size = CGSize(width: 720, height: 429)
        scene.update(0)
        #expect(scene.children.count == EmojiCatalog.items.count)
        for (index, node) in scene.children.enumerated() {
            #expect(scene.frame.contains(node.position))
            for other in scene.children.dropFirst(index + 1) {
                let distance = hypot(node.position.x - other.position.x, node.position.y - other.position.y)
                #expect(distance > MagnetLayout.itemSize * node.xScale * 0.7)
            }
        }
    }

    @Test func reducedMotionKeepsDenseGroupsApart() throws {
        let scene = makeScene()
        scene.size = CGSize(width: 720, height: 429)
        scene.setReducesMotion(true)
        for count in [1, EmojiCatalog.animals.count, EmojiCatalog.items.count - 1] {
            let ids = Set(EmojiCatalog.items.prefix(count).map(\.id))
            scene.setAttracted(ids)
            scene.update(Double(count))
            let matched = scene.children.filter { ids.contains($0.name ?? "") }
            let piled = scene.children.filter { !ids.contains($0.name ?? "") }
            let lowestMatch = try #require(matched.map { $0.frame.minY }.min())
            let highestPile = try #require(piled.map { $0.frame.maxY }.max())
            #expect(lowestMatch > highestPile)
            #expect(scene.children.allSatisfy { scene.frame.contains($0.frame) })
        }
    }

    @Test func aLargeSelectionLeavesRoomForTheRemainingPile() async throws {
        let scene = makeScene()
        let window = present(scene)
        defer { close(window) }
        let ids = Set(EmojiCatalog.animals.map(\.id))
        scene.setAttracted(ids)
        try await Task.sleep(for: .seconds(5))
        let matched = scene.children.filter { ids.contains($0.name ?? "") }
        let piled = scene.children.filter { !ids.contains($0.name ?? "") }
        let lowestMatch = try #require(matched.map { $0.frame.minY }.min())
        let highestPile = try #require(piled.map { $0.frame.maxY }.max())
        #expect(lowestMatch > highestPile)
    }

    @Test func gatheredItemsRestAndWakeWhenTheirTargetChanges() throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(2)))
        scene.setAttracted(["coat"])
        scene.update(1.0 / 60)
        let coat = try #require(scene.childNode(withName: "coat"))
        let body = try #require(coat.physicsBody)
        coat.position = MagnetLayout.gatherTargets(count: 1, in: scene.size)[0]
        coat.zRotation = 0
        body.velocity = .zero
        body.angularVelocity = 0

        scene.update(2.0 / 60)
        #expect(!body.isDynamic)
        scene.update(3.0 / 60)
        #expect(!body.isDynamic)
        #expect(body.velocity == .zero)

        scene.setAttracted(["coat", "scarf"])
        scene.update(4.0 / 60)
        #expect(body.isDynamic)
        #expect(body.velocity.dx < 0)

        scene.setAttracted([])
        scene.update(5.0 / 60)
        #expect(body.isDynamic)
        #expect(body.affectedByGravity)
    }

    @Test func collisionPrecisionFollowsSpeed() throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(1)))
        let node = try #require(scene.childNode(withName: "coat"))
        let body = try #require(node.physicsBody)
        #expect(!body.usesPreciseCollisionDetection)

        body.velocity = CGVector(dx: 3_000, dy: 0)
        scene.update(1.0 / 60)
        #expect(body.usesPreciseCollisionDetection)

        body.velocity = CGVector(dx: 10, dy: 0)
        scene.update(2.0 / 60)
        #expect(!body.usesPreciseCollisionDetection)
    }

    @Test func collisionOutlineFitsAnOffsetOblong() throws {
        let bitmap = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        let size = CGSize(width: 100, height: 100)
        #expect(EmojiCollisionShape(bitmap: bitmap, size: size) == nil)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 10, y: 20, width: 70, height: 10))
        let shape = try #require(EmojiCollisionShape(bitmap: bitmap, size: size))
        #expect(shape.vertices.count == 4)
        #expect(shape.path.boundingBox == CGRect(x: -40, y: -30, width: 70, height: 10))
        #expect(abs(shape.minimumWidth - 10) < 0.001)
    }

    @Test func everyGlyphHasABoundedConvexCollisionOutline() throws {
        for item in EmojiCatalog.items {
            let shape = try #require(MagnetScene.artwork(for: item.glyph).collisionShape, "\(item.id)")
            #expect((3 ... 8).contains(shape.vertices.count), "\(item.id)")
            #expect(shape.minimumWidth.isFinite && shape.minimumWidth > 0, "\(item.id)")
            var twiceArea: CGFloat = 0
            for index in shape.vertices.indices {
                let a = shape.vertices[index]
                let b = shape.vertices[(index + 1) % shape.vertices.count]
                let c = shape.vertices[(index + 2) % shape.vertices.count]
                twiceArea += a.x * b.y - b.x * a.y
                let turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                #expect(turn >= -0.000_001, "\(item.id) must be convex")
            }
            #expect(twiceArea > 0, "\(item.id) must have counterclockwise winding")
        }
    }

    @Test func everyGlyphFitsWithinItsTexture() throws {
        for item in EmojiCatalog.items {
            let image = MagnetScene.artwork(for: item.glyph).texture.cgImage()
            let bitmap = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< image.width {
                #expect(bytes[column * 4 + 3] == 0, "\(item.id) must clear the top edge")
                #expect(bytes[(image.height - 1) * bitmap.bytesPerRow + column * 4 + 3] == 0,
                        "\(item.id) must clear the bottom edge")
            }
            for row in 0 ..< image.height {
                #expect(bytes[row * bitmap.bytesPerRow + 3] == 0, "\(item.id) must clear the left edge")
                #expect(bytes[row * bitmap.bytesPerRow + (image.width - 1) * 4 + 3] == 0,
                        "\(item.id) must clear the right edge")
            }
        }
    }

    @Test(arguments: [false, true])
    func frameRateAdaptsToPowerAndThermalState(lowPowerMode: Bool) {
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            #expect(MagnetFrameRate.preferred(lowPowerMode: lowPowerMode, thermalState: state)
                    == (lowPowerMode ? 60 : 120))
        }
        #expect(MagnetFrameRate.preferred(lowPowerMode: lowPowerMode, thermalState: .serious) == 60)
        #expect(MagnetFrameRate.preferred(lowPowerMode: lowPowerMode, thermalState: .critical) == 30)
    }

    @Test func nonmatchesFallThroughGatheredItems() async throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(2)))
        let window = present(scene)
        defer { close(window) }
        scene.setAttracted(["coat"])
        scene.update(1.0 / 60)
        let coat = try #require(scene.childNode(withName: "coat"))
        let scarf = try #require(scene.childNode(withName: "scarf"))
        let target = try #require(MagnetLayout.gatherTargets(count: 1, in: scene.size).first)
        coat.position = target
        coat.physicsBody?.velocity = .zero
        scarf.position = CGPoint(x: target.x, y: target.y + 40)
        scarf.physicsBody?.velocity = .zero
        try await Task.sleep(for: .seconds(2))
        #expect(scarf.position.y < 100)
        #expect(abs(coat.position.y - target.y) < 5)
        try await waitUntil { coat.physicsBody?.isDynamic == false }
        let position = coat.position
        try await Task.sleep(for: .milliseconds(100))
        #expect(coat.position == position)

        // A matched item with disabled physics must still respond to a drag.
        let view = try #require(scene.view)
        let start = view.convert(scene.convertPoint(toView: coat.position), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged].enumerated() {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: start.x - CGFloat(index) * 100, y: start.y),
                modifierFlags: [], timestamp: now + Double(index) * 0.02,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            if index == 0 {
                scene.mouseDown(with: event)
                #expect(coat.physicsBody?.isDynamic == true)
            } else {
                scene.mouseDragged(with: event)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coat.physicsBody?.isDynamic == true)
        #expect(coat.position.x < position.x - 20)
        let release = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: start.x - 100, y: start.y),
            modifierFlags: [], timestamp: now + 0.15,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
        scene.mouseUp(with: release)
        try await waitUntil { coat.physicsBody?.isDynamic == false }
        #expect(hypot(coat.position.x - target.x, coat.position.y - target.y) < 0.5)
    }

    @Test func quietPileStopsMovingAndDraggingWakesIt() async throws {
        let scene = makeScene(items: Array(EmojiCatalog.items.prefix(2)))
        let window = present(scene)
        defer { close(window) }
        let nodes = scene.children
        try await waitUntil(timeout: .seconds(10)) {
            nodes.allSatisfy { $0.physicsBody?.isDynamic == false }
        }
        #expect(nodes.allSatisfy { $0.physicsBody?.isDynamic == false })
        let positions = nodes.map(\.position)
        try await Task.sleep(for: .seconds(1))
        #expect(nodes.map(\.position) == positions)

        let node = try #require(scene.childNode(withName: "coat"))
        let view = try #require(scene.view)
        let point = view.convert(scene.convertPoint(toView: node.position), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        scene.mouseDown(with: event)
        #expect(nodes.allSatisfy { $0.physicsBody?.isDynamic == true })
        scene.mouseUp(with: event)
    }

    @Test func resizingACrowdedPileDoesNotTrapMatchesAtWalls() async throws {
        let scene = makeScene()
        let window = present(scene)
        defer { close(window) }
        try await Task.sleep(for: .seconds(1))
        window.setContentSize(CGSize(width: 720, height: 429))
        try await Task.sleep(for: .seconds(2))
        scene.setAttracted(Set(EmojiCatalog.items.map(\.id)))
        try await Task.sleep(for: .seconds(3))
        let targets = MagnetLayout.gatherTargets(count: EmojiCatalog.items.count, in: scene.size)
        for (index, item) in EmojiCatalog.items.enumerated() {
            let node = try #require(scene.childNode(withName: item.id))
            let distance = hypot(node.position.x - targets[index].x, node.position.y - targets[index].y)
            #expect(distance < 5, "\(item.id) must leave the wall and reach its target")
        }

        scene.setAttracted([])
        try await Task.sleep(for: .seconds(3))
        let topTarget = try #require(targets.first)
        for node in scene.children {
            #expect(scene.frame.contains(node.position))
            // Pile height depends on the collision shapes. The top gathering row must clear.
            #expect(node.position.y + MagnetLayout.itemSize * node.xScale < topTarget.y,
                    "\(node.name ?? "item") must return to the pile")
        }
    }
}
