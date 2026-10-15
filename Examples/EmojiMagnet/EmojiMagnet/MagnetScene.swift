import AppKit
import CoreText
import SpriteKit

/// Positions for the gathered matches and for the static pile.
enum MagnetLayout {
    /// The side of each emoji sprite, in points.
    static let itemSize: CGFloat = 56
    /// Used only if the glyph has no visible pixels for a polygonal body.
    static let fallbackCollisionRadius: CGFloat = itemSize * 0.35
    /// The distance between the centers of neighboring gathered items.
    static let gatherSpacing: CGFloat = 86
    /// The distance between the centers of neighboring items in the static pile.
    static let pileSpacing: CGFloat = 62
    static let margin: CGFloat = 20

    /// Fits the full catalog and reserves a row for separating matches from the pile.
    static func itemScale(count: Int, in size: CGSize) -> CGFloat {
        guard count > 0 else { return 1 }
        let width = max(1, size.width - 2 * margin)
        let height = max(1, size.height - 2 * margin)
        let spacing = (1 ... count).map { columns in
            let rows = (count + columns - 1) / columns + 1
            return min(width / CGFloat(columns), height / CGFloat(rows))
        }.max() ?? itemSize
        return min(1, spacing / itemSize)
    }

    /// Returns spaced positions directly below the text field, in rows from the top of the scene.
    ///
    /// Each row is centered. Items fill a row before the next row starts.
    /// Dense catalogs use smaller sprites and shorter spacing.
    static func gatherTargets(
        count: Int, in size: CGSize, scale: CGFloat? = nil, spacing: CGFloat? = nil
    ) -> [CGPoint] {
        let spacing = spacing ?? fittingGatherSpacing(count: count, in: size, scale: scale)
        return rows(count: count, width: size.width, spacing: spacing).map { row, column, rowCount in
            CGPoint(
                x: centeredX(column: column, rowCount: rowCount, width: size.width, spacing: spacing),
                y: size.height - margin - spacing / 2 - CGFloat(row) * spacing
            )
        }
    }

    static func fittingGatherSpacing(count: Int, in size: CGSize, scale: CGFloat? = nil) -> CGFloat {
        fittingSpacing(count: count, in: size, preferred: gatherSpacing, scale: scale)
    }

    private static func fittingSpacing(count: Int, in size: CGSize, preferred: CGFloat, scale: CGFloat?) -> CGFloat {
        let scale = scale ?? itemScale(count: count, in: size)
        let minimum = itemSize * scale
        var spacing = preferred * scale
        while spacing > minimum {
            let columns = columns(width: size.width, spacing: spacing)
            let rows = (count + columns - 1) / columns
            if margin + CGFloat(rows) * spacing <= size.height { break }
            spacing -= 2 * scale
        }
        return max(spacing, minimum)
    }

    /// Returns tidy positions in rows from the bottom of the scene, for Reduce Motion.
    static func pilePositions(
        count: Int, in size: CGSize, scale: CGFloat? = nil, spacing: CGFloat? = nil
    ) -> [CGPoint] {
        let spacing = spacing ?? fittingSpacing(count: count, in: size, preferred: pileSpacing, scale: scale)
        return rows(count: count, width: size.width, spacing: spacing).map { row, column, rowCount in
            CGPoint(
                x: centeredX(column: column, rowCount: rowCount, width: size.width, spacing: spacing),
                y: margin / 2 + spacing / 2 + CGFloat(row) * spacing
            )
        }
    }

    static func columns(width: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width - 2 * margin) / spacing))
    }

    private static func rows(count: Int, width: CGFloat, spacing: CGFloat) -> [(Int, Int, Int)] {
        let columns = columns(width: width, spacing: spacing)
        return (0 ..< count).map { index in
            let row = index / columns
            return (row, index % columns, min(columns, count - row * columns))
        }
    }

    private static func centeredX(column: Int, rowCount: Int, width: CGFloat, spacing: CGFloat) -> CGFloat {
        width / 2 + (CGFloat(column) - CGFloat(rowCount - 1) / 2) * spacing
    }
}

/// The physics scene: a pile of emoji that rise toward the field when they match.
///
/// Matches follow a damped spring toward their gathering positions,
/// passing through other items so they cannot support or trap nonmatches.
/// Everything else falls under gravity.
/// With Reduce Motion, the scene places items directly and runs no physics.
final class MagnetScene: SKScene {
    private let items: [EmojiItem]
    private var sprites: [EmojiItem.ID: SKSpriteNode] = [:]
    private var collisionDistances: [EmojiItem.ID: CGFloat] = [:]
    private var attractedIDs: Set<EmojiItem.ID> = []
    private var targets: [EmojiItem.ID: CGPoint] = [:]
    private var reducesMotion = false
    private var hasPlacedItems = false
    private var drag: Drag?
    private var lastUpdateTime: TimeInterval?
    private var needsLayout = true
    private var itemScale: CGFloat = 1
    private var pendingAttractedIDs: Set<EmojiItem.ID>?
    private var pendingReducesMotion: Bool?
    private var quietTime: TimeInterval = 0
    private var frameDuration: TimeInterval = 0
    private var pileIsSettled = false
    /// Called when the user presses Escape while the scene has keyboard focus.
    var onCancel: (() -> Void)?

    private let itemCategory: UInt32 = 0x1
    private let wallCategory: UInt32 = 0x2
    private let attractedCategory: UInt32 = 0x4

    /// Spring stiffness and damping for attraction, per second squared and per second.
    private let stiffness: CGFloat = 45
    private let damping: CGFloat = 11
    private let maximumAttractionSpeed: CGFloat = 1_400
    private let maximumDragSpeed: CGFloat = 3_000
    private let maximumTossSpeed: CGFloat = 1_600

    private struct Drag {
        var id: EmojiItem.ID
        var point: CGPoint
        var samples: [(time: TimeInterval, point: CGPoint)]
    }

    init(items: [EmojiItem]) {
        self.items = items
        // The view sets the real size. Items are placed when it does.
        super.init(size: .zero)
        scaleMode = .resizeFill
        backgroundColor = .clear
        physicsWorld.gravity = CGVector(dx: 0, dy: -12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMove(to view: SKView) {
        view.allowsTransparency = true
        needsLayout = true
        lastUpdateTime = nil
        #if DEBUG
        Self.current = self
        #endif
    }

    #if DEBUG
    /// The scene in the window, for debug automation.
    static weak var current: MagnetScene?

    func position(of id: EmojiItem.ID) -> CGPoint? {
        sprites[id]?.position
    }

    /// The distance of each attracted item from its target, and whether it passes through other items.
    func attractionReport() -> [String] {
        items.compactMap { item in
            guard let target = targets[item.id], let node = sprites[item.id], let body = node.physicsBody else {
                return nil
            }
            let distance = hypot(target.x - node.position.x, target.y - node.position.y)
            let speed = hypot(body.velocity.dx, body.velocity.dy)
            let passes = body.collisionBitMask == wallCategory ? " passes through" : ""
            return "\(item.id): \(Int(distance)) pt from target, \(Int(speed)) pt/s\(passes)"
        }
    }
    #endif

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        needsLayout = true
    }

    /// Queues SwiftUI changes for the next SpriteKit frame callback.
    func setAttracted(_ ids: Set<EmojiItem.ID>) {
        pendingAttractedIDs = ids
    }

    func setReducesMotion(_ reducesMotion: Bool) {
        pendingReducesMotion = reducesMotion
    }

    // MARK: - Layout

    private func applyPendingChanges() {
        let ids = pendingAttractedIDs ?? attractedIDs
        let motion = pendingReducesMotion ?? reducesMotion
        pendingAttractedIDs = nil
        pendingReducesMotion = nil
        let attractionChanged = ids != attractedIDs
        let motionChanged = motion != reducesMotion
        guard needsLayout || attractionChanged || motionChanged else { return }
        let previousIDs = attractedIDs
        let resetsBodies = needsLayout || motionChanged
        // Removing a supporting item must release the frozen pile above it.
        // Bodies already in motion can use SpriteKit's normal collision wake-up.
        wakePile()
        attractedIDs = ids
        reducesMotion = motion
        if motionChanged {
            if let drag { sprites[drag.id]?.zPosition = 0 }
            drag = nil
        }
        if needsLayout {
            itemScale = MagnetLayout.itemScale(count: items.count, in: size)
            // Solid walls give the solver room to recover from deep contacts
            // during a toss or resize. Their inner faces follow the scene edges.
            let thickness = MagnetLayout.itemSize
            let horizontal = CGSize(width: size.width + 2 * thickness, height: thickness)
            let vertical = CGSize(width: thickness, height: size.height)
            let boundary = SKPhysicsBody(bodies: [
                SKPhysicsBody(rectangleOf: horizontal, center: CGPoint(x: size.width / 2, y: -thickness / 2)),
                SKPhysicsBody(rectangleOf: horizontal, center: CGPoint(x: size.width / 2, y: size.height + thickness / 2)),
                SKPhysicsBody(rectangleOf: vertical, center: CGPoint(x: -thickness / 2, y: size.height / 2)),
                SKPhysicsBody(rectangleOf: vertical, center: CGPoint(x: size.width + thickness / 2, y: size.height / 2)),
            ])
            boundary.isDynamic = false
            boundary.friction = 0.6
            boundary.restitution = 0
            boundary.categoryBitMask = wallCategory
            boundary.collisionBitMask = itemCategory | attractedCategory
            physicsBody = boundary
            placeItemsIfNeeded()
            for node in sprites.values { node.setScale(itemScale) }
            keepItemsInside(afterResize: true)
            needsLayout = false
        }
        for (id, node) in sprites {
            guard let body = node.physicsBody else { continue }
            let attracted = attractedIDs.contains(id)
            guard resetsBodies || attracted != previousIDs.contains(id) else { continue }
            // Both sides must exclude the other category. A one-sided mask can
            // still let a falling item rest on a matching item.
            body.categoryBitMask = attracted ? attractedCategory : itemCategory
            body.collisionBitMask = attracted ? wallCategory : itemCategory | wallCategory
            body.affectedByGravity = !attracted && id != drag?.id
            body.isDynamic = !reducesMotion
            body.isResting = false
            if motionChanged {
                body.velocity = .zero
                body.angularVelocity = 0
            }
        }
        updateTargets()
    }

    private func placeItemsIfNeeded() {
        // The view can report small sizes while the window opens.
        // The smallest window gives a scene of about 720 × 430 points.
        guard !hasPlacedItems, size.width >= 600, size.height >= 300 else { return }
        hasPlacedItems = true
        // Start in loose rows across the top so that the items fall into a pile.
        // A fixed seed gives the same pile at every launch.
        var random = SeededRandom(seed: 7)
        let positions = MagnetLayout.gatherTargets(count: items.count, in: size, scale: itemScale)
        for (index, item) in items.enumerated() {
            let node = makeNode(for: item)
            // Fit every row in the window instead of stacking overflow rows
            // at the same height in a small window.
            node.position = CGPoint(
                x: positions[index].x + random.next(in: -4 ... 4) * itemScale,
                y: positions[index].y + random.next(in: -4 ... 4) * itemScale
            )
            node.zRotation = random.next(in: -0.6 ... 0.6)
            sprites[item.id] = node
            addChild(node)
        }
    }

    private func makeNode(for item: EmojiItem) -> SKSpriteNode {
        let (texture, shape) = Self.artwork(for: item.glyph)
        let size = CGSize(width: MagnetLayout.itemSize, height: MagnetLayout.itemSize)
        let node = SKSpriteNode(texture: texture, size: size)
        node.name = item.id
        let body: SKPhysicsBody
        if let shape {
            body = SKPhysicsBody(polygonFrom: shape.path)
            collisionDistances[item.id] = shape.minimumWidth / 2
        } else {
            body = SKPhysicsBody(circleOfRadius: MagnetLayout.fallbackCollisionRadius)
            collisionDistances[item.id] = MagnetLayout.fallbackCollisionRadius
        }
        body.friction = 0.6
        body.restitution = 0
        body.linearDamping = 0.5
        body.angularDamping = 0.8
        body.isDynamic = !reducesMotion
        body.categoryBitMask = itemCategory
        body.collisionBitMask = itemCategory | wallCategory
        node.physicsBody = body
        return node
    }

    /// Recomputes the gathering positions and, with Reduce Motion, moves every item into place.
    private func updateTargets() {
        let gathered = items.filter { attractedIDs.contains($0.id) }
        // A common spacing keeps the two static groups apart in a dense catalog.
        let spacing = reducesMotion && itemScale < 1 ? MagnetLayout.itemSize * itemScale : nil
        let gatheredSize = CGSize(
            width: size.width,
            height: size.height * max(0.3, CGFloat(gathered.count) / CGFloat(max(1, items.count)))
        )
        let gatheredPositions = MagnetLayout.gatherTargets(
            count: gathered.count, in: gatheredSize, scale: itemScale, spacing: spacing
        ).map { CGPoint(x: $0.x, y: $0.y + size.height - gatheredSize.height) }
        targets = Dictionary(uniqueKeysWithValues: zip(
            gathered.map(\.id),
            gatheredPositions
        ))
        guard reducesMotion else { return }
        let piled = items.filter { !attractedIDs.contains($0.id) }
        let pile = Dictionary(uniqueKeysWithValues: zip(
            piled.map(\.id),
            MagnetLayout.pilePositions(count: piled.count, in: size, scale: itemScale, spacing: spacing)
        ))
        for (id, node) in sprites {
            node.removeAllActions()
            node.position = targets[id] ?? pile[id] ?? node.position
            node.zRotation = 0
        }
    }

    /// Recovers an escaped center at the nearest edge without restarting its fall.
    ///
    /// The rotated sprite frame includes transparent corners and is not a physics bound.
    /// Normal edge contacts belong to SpriteKit; only escaped centers need recovery.
    private func keepItemsInside(afterResize: Bool = false) {
        for node in sprites.values {
            guard let body = node.physicsBody else { continue }
            // After a resize or escape, put the entire rotated sprite inside
            // the new wall. A body that straddles an edge can stick outside it.
            let insetX = min(node.frame.width / 2 + 1, size.width / 2)
            let insetY = min(node.frame.height / 2 + 1, size.height / 2)
            let marginX = afterResize ? insetX : 0
            let marginY = afterResize ? insetY : 0
            if node.position.x < marginX || node.position.x > size.width - marginX {
                node.position.x = min(max(node.position.x, insetX), size.width - insetX)
                if (node.position.x == insetX && body.velocity.dx < 0)
                    || (node.position.x == size.width - insetX && body.velocity.dx > 0)
                {
                    body.velocity.dx = 0
                }
            }
            if node.position.y < marginY || node.position.y > size.height - marginY {
                node.position.y = min(max(node.position.y, insetY), size.height - insetY)
                if (node.position.y == insetY && body.velocity.dy < 0)
                    || (node.position.y == size.height - insetY && body.velocity.dy > 0)
                {
                    body.velocity.dy = 0
                }
            }
        }
    }

    // MARK: - Simulation

    override func update(_ currentTime: TimeInterval) {
        let elapsed = currentTime - (lastUpdateTime ?? currentTime)
        lastUpdateTime = currentTime
        guard size.width > 0, size.height > 0 else { return }
        applyPendingChanges()
        guard !reducesMotion, hasPlacedItems else { return }
        let dt = CGFloat(min(max(elapsed, 1.0 / 240), 1.0 / 30))
        frameDuration = TimeInterval(dt)

        for (id, node) in sprites {
            guard let body = node.physicsBody else { continue }
            let collisionDistance = (collisionDistances[id] ?? MagnetLayout.fallbackCollisionRadius) * itemScale
            if let drag, drag.id == id {
                // Follow the pointer with a velocity so that the item still pushes others.
                let point = boundedDragPoint(drag.point)
                if !body.isDynamic { body.isDynamic = true }
                body.isResting = false
                let velocity = CGVector(
                    dx: (point.x - node.position.x) / dt,
                    dy: (point.y - node.position.y) / dt
                )
                body.velocity = velocity.clamped(to: maximumDragSpeed)
                updateCollisionPrecision(body, dt: dt, distance: collisionDistance)
                continue
            }
            guard let target = targets[id] else {
                updateCollisionPrecision(body, dt: dt, distance: collisionDistance)
                continue
            }
            let angle = atan2(sin(node.zRotation), cos(node.zRotation))
            let distance = hypot(target.x - node.position.x, target.y - node.position.y)
            if distance < 0.5, hypot(body.velocity.dx, body.velocity.dy) < 2,
               abs(angle) < 0.01, abs(body.angularVelocity) < 0.05
            {
                if body.isDynamic {
                    node.position = target
                    node.zRotation = 0
                    body.velocity = .zero
                    body.angularVelocity = 0
                    // Unsupported bodies do not stay asleep reliably.
                    // A gathered item needs no simulation until its target changes.
                    body.isDynamic = false
                }
                if body.usesPreciseCollisionDetection { body.usesPreciseCollisionDetection = false }
                continue
            }
            if !body.isDynamic { body.isDynamic = true }
            // A resting body ignores velocity changes until something wakes it.
            if body.isResting { body.isResting = false }
            var velocity = body.velocity
            velocity.dx += (stiffness * (target.x - node.position.x) - damping * velocity.dx) * dt
            velocity.dy += (stiffness * (target.y - node.position.y) - damping * velocity.dy) * dt
            body.velocity = velocity.clamped(to: maximumAttractionSpeed)
            // Turn the item upright as it settles.
            body.angularVelocity += (-20 * angle - 6 * body.angularVelocity) * dt
            updateCollisionPrecision(body, dt: dt, distance: collisionDistance)
        }
    }

    /// Uses continuous collision detection only when an item travels far in one frame.
    private func updateCollisionPrecision(_ body: SKPhysicsBody, dt: CGFloat, distance: CGFloat) {
        let needsPrecision = body.isDynamic && !body.isResting
            && hypot(body.velocity.dx, body.velocity.dy) * dt > distance
        if body.usesPreciseCollisionDetection != needsPrecision {
            body.usesPreciseCollisionDetection = needsPrecision
        }
    }

    override func didSimulatePhysics() {
        guard !reducesMotion, hasPlacedItems else { return }
        keepItemsInside()
        settlePileIfQuiet()
    }

    /// Stops residual solver motion once the whole falling pile is nearly still.
    /// Waiting for every body avoids leaving an item suspended over moving support.
    private func settlePileIfQuiet() {
        guard !pileIsSettled, drag == nil else { return }
        let bodies = sprites.compactMap { id, node in
            targets[id] == nil ? node.physicsBody : nil
        }
        // The limits are 12 points per second and about 17 degrees per second.
        guard !bodies.isEmpty, bodies.allSatisfy({
            hypot($0.velocity.dx, $0.velocity.dy) < 12 && abs($0.angularVelocity) < 0.3
        }) else {
            quietTime = 0
            return
        }
        quietTime += frameDuration
        guard quietTime >= 0.6 else { return }
        for body in bodies {
            body.velocity = .zero
            body.angularVelocity = 0
            body.isDynamic = false
        }
        pileIsSettled = true
    }

    /// Restores the frozen pile after interaction or layout changes.
    /// Gathered items resume simulation only when moved, dragged, or released.
    private func wakePile() {
        quietTime = 0
        guard pileIsSettled else { return }
        pileIsSettled = false
        for (id, node) in sprites where targets[id] == nil {
            node.physicsBody?.isDynamic = true
            node.physicsBody?.isResting = false
        }
    }

    // MARK: - Dragging

    private func boundedDragPoint(_ point: CGPoint) -> CGPoint {
        let inset = MagnetLayout.itemSize * itemScale / 2
        return CGPoint(
            x: min(max(point.x, inset), max(inset, size.width - inset)),
            y: min(max(point.y, inset), max(inset, size.height - inset))
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard !reducesMotion else { return }
        let point = event.location(in: self)
        guard let node = (physicsWorld.body(at: point)?.node ?? nodes(at: point).first) as? SKSpriteNode,
              let id = node.name,
              sprites[id] === node
        else { return }
        wakePile()
        drag = Drag(id: id, point: point, samples: [(event.timestamp, point)])
        node.physicsBody?.isDynamic = true
        node.physicsBody?.isResting = false
        node.physicsBody?.affectedByGravity = false
        node.zPosition = 1
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag else { return }
        drag.point = event.location(in: self)
        drag.samples.append((event.timestamp, drag.point))
        drag.samples.removeAll { event.timestamp - $0.time > 0.1 }
        self.drag = drag
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let node = sprites[drag.id] else { return }
        self.drag = nil
        node.zPosition = 0
        node.physicsBody?.affectedByGravity = !attractedIDs.contains(drag.id)
        // Toss with the pointer's recent velocity.
        if let first = drag.samples.first, let last = drag.samples.last, last.time - first.time > 0.01 {
            let duration = CGFloat(last.time - first.time)
            let velocity = CGVector(
                dx: (last.point.x - first.point.x) / duration,
                dy: (last.point.y - first.point.y) / duration
            )
            node.physicsBody?.velocity = velocity.clamped(to: maximumTossSpeed)
        } else {
            node.physicsBody?.velocity = .zero
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Textures

    /// Renders an Apple Color Emoji glyph at twice the sprite size.
    static func artwork(for glyph: String) -> (texture: SKTexture, collisionShape: EmojiCollisionShape?) {
        let points = MagnetLayout.itemSize
        let scale: CGFloat = 2
        let pixels = Int(points * scale)
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return (SKTexture(), nil) }
        context.scaleBy(x: scale, y: scale)
        let string = NSAttributedString(
            string: glyph,
            attributes: [.font: NSFont.systemFont(ofSize: points * 0.78)]
        )
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetImageBounds(line, context)
        guard !bounds.isNull, !bounds.isEmpty else { return (SKTexture(), nil) }
        // Center the glyph image around its baseline, not the text layout rectangle.
        // Leave two points of padding if a fallback glyph needs to scale down.
        let fit = min(1, (points - 4) / max(bounds.width, bounds.height))
        context.translateBy(x: points / 2, y: points / 2)
        context.scaleBy(x: fit, y: fit)
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return (SKTexture(), nil) }
        let shape = EmojiCollisionShape(bitmap: context, size: CGSize(width: points, height: points))
        return (SKTexture(cgImage: image), shape)
    }
}

private extension CGVector {
    func clamped(to maximum: CGFloat) -> CGVector {
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > maximum else { return self }
        return CGVector(dx: dx * maximum / length, dy: dy * maximum / length)
    }
}

/// A small linear congruential generator for a repeatable starting pile.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = CGFloat(state >> 11) / CGFloat(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
