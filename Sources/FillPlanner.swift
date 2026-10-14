import CoreGraphics
import Foundation

/// Physical inward offsets of a binary ink region. Loops are joined only if
/// the entire brush capsule fits in ink; holes are never connection shortcuts.
enum FillPlanner {
    enum Failure: Error { case budget }
    struct Result {
        var paths: [[CGPoint]]
        var skippedSmallPaths: Int
        var layers: Int
    }
    private struct Node {
        let point: CGPoint
        var neighbors: [Int]
    }

    static func make(mask: [Bool], width: Int, height: Int, origin: CGPoint,
                     pitch: CGSize, brush: Double, minimumMovement: Double) throws -> Result {
        guard width >= 3, height >= 3, mask.count == width * height,
              pitch.width > 0, pitch.height > 0, brush > 0 else {
            return Result(paths: [], skippedSmallPaths: 0, layers: 0)
        }
        if !mask.contains(true) { return Result(paths: [], skippedSmallPaths: 0, layers: 0) }
        let distances = distanceField(mask: mask, width: width, height: height, pitch: pitch)
        let radius = brush / 2
        let allowance = brush * 0.025
        func segmentInside(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / (min(pitch.width, pitch.height) * 0.4))))
            for step in 0...count {
                let t = Double(step) / Double(count)
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                if sample(field: distances, width: width, height: height,
                          point: p, origin: origin, pitch: pitch) < radius + allowance * 0.15 { return false }
            }
            return true
        }
        let maximum = distances.max() ?? 0
        let spacing = max(brush * 0.7, min(pitch.width, pitch.height) * 0.7)
        let layerCount = max(0, Int(ceil((maximum - radius - allowance) / spacing)))
        guard layerCount <= 2048 else { throw Failure.budget }
        var paths: [[CGPoint]] = []
        var points = 0
        if layerCount > 0 {
            for layer in 0..<layerCount {
                let level = radius + allowance + Double(layer) * spacing
                let loops = try contours(field: distances, width: width, height: height,
                                         level: level, origin: origin, pitch: pitch)
                for loop in loops {
                    let compact = simplify(loop, tolerance: brush * 0.12, safe: segmentInside)
                    if compact.count >= 2 {
                        paths.append(compact); points += compact.count
                        guard points <= 240_000, paths.count <= 36_000 else { throw Failure.budget }
                    }
                }
            }
        }

        // Inward loops can collapse to a medial strip narrower than one loop
        // interval. Add only skeleton portions not already painted by loops.
        var painted = [Bool](repeating: false, count: mask.count)
        mark(paths: paths, mask: &painted, width: width, height: height,
             origin: origin, pitch: pitch, radius: radius * 0.94)
        var skeleton = mask
        thin(mask: &skeleton, width: width, height: height)
        var residual = [Bool](repeating: false, count: mask.count)
        for index in skeleton.indices where skeleton[index] && !painted[index] {
            residual[index] = distances[index] >= radius + allowance
        }
        let medialCandidates = SkeletonTracing.polylines(mask: residual, width: width, height: height)
            .map { $0.map { CGPoint(x: origin.x + $0.x * pitch.width,
                                    y: origin.y + $0.y * pitch.height) } }
        var medial: [[CGPoint]] = []
        for candidate in medialCandidates {
            var chain: [CGPoint] = []
            for (a, b) in zip(candidate, candidate.dropFirst()) {
                if segmentInside(a, b) {
                    if chain.isEmpty { chain.append(a) }
                    chain.append(b)
                } else {
                    if chain.count >= 2 { medial.append(chain) }
                    chain = []
                }
            }
            if chain.count >= 2 { medial.append(chain) }
        }
        paths += medial.filter { $0.count >= 2 }
        points += medial.reduce(0) { $0 + $1.count }
        guard points <= 240_000, paths.count <= 36_000 else { throw Failure.budget }

        // The nearest point alone is insufficient. Every sampled connector
        // position must clear half a pen width in the distance field.
        func safeConnection(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length <= max(brush * 2.2, max(pitch.width, pitch.height) * 2.2) else { return false }
            return segmentInside(a, b)
        }
        // Include tiny medial remnants as waypoints on an existing fill path.
        // They need no independent short down/up stroke: an ink-safe excursion
        // from an offset loop covers the remnant and returns to that same loop.
        var medialPaint = painted
        mark(paths: medial, mask: &medialPaint, width: width, height: height,
             origin: origin, pitch: pitch, radius: radius * 0.95)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                if residual[index] && !medialPaint[index] {
                    let p = CGPoint(x: origin.x + (Double(x) + 0.5) * pitch.width,
                                    y: origin.y + (Double(y) + 0.5) * pitch.height)
                    paths.append([p, p])
                    // Avoid adding a waypoint for every adjacent residual pixel.
                    mark(paths: [[p, p]], mask: &medialPaint, width: width, height: height,
                         origin: origin, pitch: pitch, radius: radius * 0.9)
                }
            }
        }
        guard paths.reduce(0, { $0 + $1.count }) <= 240_000 else { throw Failure.budget }
        var joined: [[CGPoint]] = []
        var joinWork = 0
        for var path in paths {
            if joinWork >= 6_000_000 { joined.append(path); continue }
            var bestParent: Int?
            var bestIndex = 0
            var reverse = false
            var bestDistance = Double.infinity
            let closed = path.first == path.last
            search: for index in joined.indices {
                guard let end = joined[index].last else { continue }
                for candidate in path.indices {
                    joinWork += 1
                    if joinWork >= 6_000_000 { break search }
                    if !closed && candidate != 0 && candidate != path.count - 1 { continue }
                    let distance = hypot(end.x - path[candidate].x, end.y - path[candidate].y)
                    if distance < bestDistance, safeConnection(end, path[candidate]) {
                        bestDistance = distance; bestParent = index; bestIndex = candidate
                        reverse = !closed && candidate == path.count - 1
                    }
                }
            }
            if let parent = bestParent {
                if closed {
                    let ring = Array(path.dropLast())
                    let index = min(bestIndex, ring.count - 1)
                    path = Array(ring[index...]) + Array(ring[..<index]) + [ring[index]]
                } else if reverse { path.reverse() }
                joined[parent] += path
            } else { joined.append(path) }
        }
        // A small remaining path might be close to the middle of a long loop
        // but far from its arbitrary endpoint. Splice it into a safely nearby
        // vertex; return along the same ink-safe connector, preserving holes.
        var merged = [Bool](repeating: false, count: joined.count)
        let parents = joined.indices.sorted { joined[$0].count > joined[$1].count }
        for parent in parents where !merged[parent] {
            if joinWork >= 12_000_000 { break }
            for child in joined.indices where child != parent && !merged[child] {
                if joinWork >= 12_000_000 { break }
                if joined[child].count > 64 { continue }
                let path = joined[child], closed = path.first == path.last
                var best: (Int, Int)?
                var shortest = Double.infinity
                search: for i in joined[parent].indices {
                    for j in path.indices {
                        joinWork += 1
                        if joinWork >= 12_000_000 { break search }
                        if !closed && j != 0 && j != path.count - 1 { continue }
                        let a = joined[parent][i], b = path[j]
                        let distance = hypot(a.x - b.x, a.y - b.y)
                        if distance < shortest && safeConnection(a, b) { shortest = distance; best = (i, j) }
                    }
                }
                if let (i, j) = best {
                    let a = joined[parent][i]
                    var excursion: [CGPoint]
                    if closed && path.count > 2 {
                        let ring = Array(path.dropLast()), offset = min(j, path.count - 2)
                        excursion = Array(ring[offset...]) + Array(ring[..<offset]) + [ring[offset], a]
                    } else {
                        let part = j == 0 ? path : Array(path.reversed())
                        excursion = part + Array(part.dropLast().reversed()) + [a]
                    }
                    joined[parent].insert(contentsOf: excursion, at: i + 1)
                    merged[child] = true
                }
            }
        }
        joined = joined.indices.filter { !merged[$0] }.map { joined[$0] }
        var skipped = 0
        joined = joined.filter { path in
            let length = zip(path, path.dropFirst()).reduce(0.0) {
                $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }
            if length + 0.000001 < minimumMovement { skipped += 1; return false }
            return length > 0
        }
        guard joined.reduce(0, { $0 + $1.count }) <= 240_000 else { throw Failure.budget }
        return Result(paths: joined, skippedSmallPaths: skipped, layers: layerCount)
    }

    /// Exact separable Euclidean transform, in physical point units.
    private static func distanceField(mask: [Bool], width: Int, height: Int, pitch: CGSize) -> [Double] {
        let infinity = 1.0e20
        var field = mask.map { $0 ? infinity : 0.0 }
        for y in 0..<height {
            let begin = y * width
            let row = transform(Array(field[begin..<(begin + width)]), scale: pitch.width)
            field.replaceSubrange(begin..<(begin + width), with: row)
        }
        for x in 0..<width {
            let column = transform((0..<height).map { field[$0 * width + x] }, scale: pitch.height)
            for y in 0..<height { field[y * width + x] = column[y] }
        }
        let halfCell = min(pitch.width, pitch.height) / 2
        return field.map { sqrt(max(0, $0)) - halfCell }
    }
    private static func transform(_ input: [Double], scale: Double) -> [Double] {
        let count = input.count, weight = scale * scale
        var sites = [Int](repeating: 0, count: count)
        var boundaries = [Double](repeating: .infinity, count: count + 1)
        boundaries[0] = -.infinity
        var last = 0
        for q in 1..<count {
            var intersection = 0.0
            while true {
                let p = sites[last]
                intersection = ((input[q] - input[p]) / weight + Double(q * q - p * p)) / Double(2 * (q - p))
                if intersection > boundaries[last] || last == 0 { break }
                last -= 1
            }
            last += 1; sites[last] = q; boundaries[last] = intersection; boundaries[last + 1] = .infinity
        }
        var result = [Double](repeating: 0, count: count)
        var site = 0
        for q in 0..<count {
            while boundaries[site + 1] < Double(q) { site += 1 }
            let delta = Double(q - sites[site])
            result[q] = input[sites[site]] + delta * delta * weight
        }
        return result
    }

    private static func contours(field: [Double], width: Int, height: Int, level: Double,
                                 origin: CGPoint, pitch: CGSize) throws -> [[CGPoint]] {
        var nodes: [Int: Node] = [:]
        var segments = 0
        func edge(_ x: Int, _ y: Int, vertical: Bool) -> Int {
            let first = y * width + x
            let next = first + (vertical ? width : 1)
            let key = first * 2 + (vertical ? 1 : 0)
            if nodes[key] == nil {
                let a = field[first], b = field[next]
                let fraction = abs(b - a) > 1e-12 ? min(1, max(0, (level - a) / (b - a))) : 0.5
                let p = CGPoint(x: origin.x + (Double(x) + 0.5 + (vertical ? 0 : fraction)) * pitch.width,
                                y: origin.y + (Double(y) + 0.5 + (vertical ? fraction : 0)) * pitch.height)
                nodes[key] = Node(point: p, neighbors: [])
            }
            return key
        }
        func connect(_ a: Int, _ b: Int) {
            nodes[a]!.neighbors.append(b); nodes[b]!.neighbors.append(a); segments += 1
        }
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = y * width + x
                let code = (field[i] >= level ? 1 : 0) | (field[i + 1] >= level ? 2 : 0)
                    | (field[i + width + 1] >= level ? 4 : 0) | (field[i + width] >= level ? 8 : 0)
                if code == 0 || code == 15 { continue }
                func top() -> Int { edge(x, y, vertical: false) }
                func right() -> Int { edge(x + 1, y, vertical: true) }
                func bottom() -> Int { edge(x, y + 1, vertical: false) }
                func left() -> Int { edge(x, y, vertical: true) }
                switch code {
                case 1, 14: connect(top(), left())
                case 2, 13: connect(top(), right())
                case 3, 12: connect(left(), right())
                case 4, 11: connect(right(), bottom())
                case 5: connect(top(), left()); connect(right(), bottom())
                case 6, 9: connect(top(), bottom())
                case 7, 8: connect(left(), bottom())
                case 10: connect(top(), right()); connect(bottom(), left())
                default: break
                }
                if segments > 240_000 { throw Failure.budget }
            }
        }
        var visited = Set<Int>()
        var result: [[CGPoint]] = []
        for start in nodes.keys.sorted() where !visited.contains(start) {
            var current = start, previous = -1
            var path: [CGPoint] = []
            for _ in 0...(nodes.count + 1) {
                guard let node = nodes[current] else { break }
                path.append(node.point); visited.insert(current)
                guard let next = node.neighbors.first(where: { $0 != previous }) else { break }
                if next == start { path.append(nodes[start]!.point); break }
                if visited.contains(next) { break }
                previous = current; current = next
            }
            if path.count >= 2 { result.append(path) }
        }
        return result
    }

    private static func sample(field: [Double], width: Int, height: Int, point: CGPoint,
                               origin: CGPoint, pitch: CGSize) -> Double {
        let x = (point.x - origin.x) / pitch.width - 0.5
        let y = (point.y - origin.y) / pitch.height - 0.5
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return -1 }
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let i = iy * width + ix
        return (field[i] * (1 - fx) + field[i + 1] * fx) * (1 - fy)
            + (field[i + width] * (1 - fx) + field[i + width + 1] * fx) * fy
    }
    private static func mark(paths: [[CGPoint]], mask: inout [Bool], width: Int, height: Int,
                             origin: CGPoint, pitch: CGSize, radius: Double) {
        for path in paths {
            for (a, b) in zip(path, path.dropFirst()) {
                let left = max(0, Int(floor((min(a.x, b.x) - radius - origin.x) / pitch.width)))
                let right = min(width - 1, Int(ceil((max(a.x, b.x) + radius - origin.x) / pitch.width)))
                let top = max(0, Int(floor((min(a.y, b.y) - radius - origin.y) / pitch.height)))
                let bottom = min(height - 1, Int(ceil((max(a.y, b.y) + radius - origin.y) / pitch.height)))
                guard right >= left, bottom >= top else { continue }
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                for y in top...bottom {
                    for x in left...right {
                        let px = origin.x + (Double(x) + 0.5) * pitch.width - a.x
                        let py = origin.y + (Double(y) + 0.5) * pitch.height - a.y
                        let fraction = length > 0 ? min(1, max(0, (px * dx + py * dy) / length)) : 0
                        if hypot(px - fraction * dx, py - fraction * dy) <= radius { mask[y * width + x] = true }
                    }
                }
            }
        }
    }
    private static func simplify(_ points: [CGPoint], tolerance: Double,
                                  safe: (CGPoint, CGPoint) -> Bool) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var pending = [(0, points.count - 1)]
        while let (first, last) = pending.popLast() {
            let a = points[first], b = points[last], dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            var greatest = tolerance, split = first
            if last <= first + 1 { continue }
            for index in (first + 1)..<last {
                let px = points[index].x - a.x, py = points[index].y - a.y
                let fraction = length > 0 ? min(1, max(0, (px * dx + py * dy) / length)) : 0
                let distance = hypot(px - fraction * dx, py - fraction * dy)
                if distance > greatest { greatest = distance; split = index }
            }
            if split == first && !safe(a, b) { split = (first + last) / 2 }
            if split != first { keep[split] = true; pending += [(first, split), (split, last)] }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }
    private static func thin(mask: inout [Bool], width: Int, height: Int) {
        for _ in 0..<max(width, height) {
            var changed = false
            for phase in 0..<2 {
                var removed: [Int] = []
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) {
                        let i = y * width + x
                        if !mask[i] { continue }
                        let p = [mask[i - width], mask[i - width + 1], mask[i + 1], mask[i + width + 1],
                                 mask[i + width], mask[i + width - 1], mask[i - 1], mask[i - width - 1]]
                        let count = p.filter { $0 }.count
                        guard count >= 2, count <= 6 else { continue }
                        let transitions = (0..<8).filter { !p[$0] && p[($0 + 1) % 8] }.count
                        if transitions != 1 { continue }
                        let a = phase == 0 ? p[0] && p[2] && p[4] : p[0] && p[2] && p[6]
                        let b = phase == 0 ? p[2] && p[4] && p[6] : p[0] && p[4] && p[6]
                        if !a && !b { removed.append(i) }
                    }
                }
                if !removed.isEmpty { changed = true }
                for i in removed { mask[i] = false }
            }
            if !changed { return }
        }
    }
}
