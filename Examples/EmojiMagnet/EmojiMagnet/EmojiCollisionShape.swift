import CoreGraphics

/// A convex outline bounded by eight axis-aligned and diagonal support lines.
/// It encloses visible pixels without retaining every detail of the glyph.
struct EmojiCollisionShape {
    let vertices: [CGPoint]

    /// Reads an RGBA8 bitmap, with alpha in the last byte of each pixel.
    init?(bitmap: CGContext, size: CGSize) {
        guard bitmap.bitsPerPixel == 32, let data = bitmap.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let directions: [CGVector] = [
            CGVector(dx: 1, dy: 0), CGVector(dx: 1, dy: 1),
            CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 1),
            CGVector(dx: -1, dy: 0), CGVector(dx: -1, dy: -1),
            CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: -1),
        ]
        var limits = Array(repeating: -CGFloat.infinity, count: directions.count)
        let pixelWidth = size.width / CGFloat(bitmap.width)
        let pixelHeight = size.height / CGFloat(bitmap.height)
        for row in 0 ..< bitmap.height {
            let offset = row * bitmap.bytesPerRow
            let columns = 0 ..< bitmap.width
            // The row's endpoints bound all its pixels in each support direction.
            guard let first = columns.first(where: { bytes[offset + $0 * 4 + 3] >= 77 }),
                  let last = columns.last(where: { bytes[offset + $0 * 4 + 3] >= 77 })
            else { continue }
            let left = CGFloat(first) * pixelWidth - size.width / 2
            let right = CGFloat(last + 1) * pixelWidth - size.width / 2
            // Bitmap rows start at the top; SpriteKit coordinates start at the bottom.
            let bottom = CGFloat(bitmap.height - row - 1) * pixelHeight - size.height / 2
            let top = bottom + pixelHeight
            for (index, direction) in directions.enumerated() {
                let x = direction.dx >= 0 ? right : left
                let y = direction.dy >= 0 ? top : bottom
                limits[index] = max(limits[index], direction.dx * x + direction.dy * y)
            }
        }
        guard limits.allSatisfy(\.isFinite) else { return nil }

        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        var polygon = [
            CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: -halfWidth, y: halfHeight),
        ]
        for (direction, limit) in zip(directions, limits) {
            var clipped: [CGPoint] = []
            for index in polygon.indices {
                let start = polygon[index]
                let end = polygon[(index + 1) % polygon.count]
                let startDistance = direction.dx * start.x + direction.dy * start.y - limit
                let endDistance = direction.dx * end.x + direction.dy * end.y - limit
                if startDistance <= 0 { clipped.append(start) }
                if (startDistance < 0 && endDistance > 0) || (startDistance > 0 && endDistance < 0) {
                    let fraction = startDistance / (startDistance - endDistance)
                    clipped.append(CGPoint(
                        x: start.x + fraction * (end.x - start.x),
                        y: start.y + fraction * (end.y - start.y)
                    ))
                }
            }
            polygon = clipped
        }
        guard (3 ... 8).contains(polygon.count) else { return nil }
        vertices = polygon
    }

    var path: CGPath {
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }

    /// The narrowest distance between parallel supporting lines.
    /// Thin glyphs need precise collision detection at lower speeds.
    var minimumWidth: CGFloat {
        vertices.indices.map { index in
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            let length = hypot(end.x - start.x, end.y - start.y)
            let projections = vertices.map { point in
                ((point.x - start.x) * (start.y - end.y)
                    + (point.y - start.y) * (end.x - start.x)) / length
            }
            return (projections.max() ?? 0) - (projections.min() ?? 0)
        }.min() ?? 0
    }
}
