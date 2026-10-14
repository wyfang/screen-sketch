import AppKit
import CoreGraphics
import Foundation

/// Geometric quality checks use independent analytic source curves rather than
/// comparing a preview against the processor's own intermediate raster.
@main
struct OutlineQualityChecks {
    private enum Failure: Error { case check(String) }
    private struct Segment {
        let a: CGPoint
        let b: CGPoint
        var length: Double { hypot(Double(b.x - a.x), Double(b.y - a.y)) }
    }
    private struct Fixture {
        let name: String
        let image: CGImage
        let curves: [[CGPoint]]
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }

    private static func segments(_ curves: [[CGPoint]]) -> [Segment] {
        curves.flatMap { curve in
            zip(curve, curve.dropFirst()).map { Segment(a: $0.0, b: $0.1) }
        }
    }

    private static func distance(_ p: CGPoint, to segment: Segment) -> Double {
        let dx = Double(segment.b.x - segment.a.x)
        let dy = Double(segment.b.y - segment.a.y)
        let denominator = dx * dx + dy * dy
        if denominator == 0 { return hypot(Double(p.x - segment.a.x), Double(p.y - segment.a.y)) }
        let t = min(1, max(0, (Double(p.x - segment.a.x) * dx + Double(p.y - segment.a.y) * dy) / denominator))
        return hypot(Double(p.x - segment.a.x) - t * dx, Double(p.y - segment.a.y) - t * dy)
    }

    private static func samples(_ segments: [Segment], pitch: Double = 0.8) -> [CGPoint] {
        segments.flatMap { segment in
            let count = max(1, Int(ceil(segment.length / pitch)))
            return (0...count).map { index in
                let t = Double(index) / Double(count)
                return CGPoint(x: Double(segment.a.x) + Double(segment.b.x - segment.a.x) * t,
                               y: Double(segment.a.y) + Double(segment.b.y - segment.a.y) * t)
            }
        }
    }

    private static func nearFraction(_ points: [CGPoint], segments: [Segment], tolerance: Double) -> Double {
        guard !points.isEmpty, !segments.isEmpty else { return 0 }
        let count = points.reduce(0) { result, p in
            result + (segments.contains { distance(p, to: $0) <= tolerance } ? 1 : 0)
        }
        return Double(count) / Double(points.count)
    }

    private static func image(width: Int = 512, height: Int = 512,
                              sample: (Double, Double) -> Double) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8(min(255, max(0, sample(Double(x) + 0.5, Double(y) + 0.5))).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw Failure.check("Cannot create fixture") }
        return image
    }

    private static func grayPixels(_ image: CGImage) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw Failure.check("Cannot read real-image reference pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height))
    }

    private static func lineFixture(_ name: String, curves: [[CGPoint]],
                                    width: Double = 1.5, ink: Double = 0,
                                    paper: Double = 255) throws -> Fixture {
        let sourceSegments = segments(curves)
        let raster = try image { x, y in
            let p = CGPoint(x: x, y: y)
            let separation = sourceSegments.map { distance(p, to: $0) }.min() ?? .infinity
            let coverage = min(1, max(0, width / 2 + 0.5 - separation))
            return paper + (ink - paper) * coverage
        }
        return Fixture(name: name, image: raster, curves: curves)
    }

    private static func circle(center: CGPoint = CGPoint(x: 256, y: 256), radius: Double,
                               from: Double = 0, to: Double = 2 * .pi) -> [CGPoint] {
        let count = max(8, Int(ceil(abs(to - from) * radius / 1.5)))
        return (0...count).map { i in
            let angle = from + (to - from) * Double(i) / Double(count)
            return CGPoint(x: Double(center.x) + radius * cos(angle),
                           y: Double(center.y) + radius * sin(angle))
        }
    }

    private static func circularFixture(_ name: String, radius: Double,
                                        from: Double = 0, to: Double = 2 * .pi) throws -> Fixture {
        let curve = circle(radius: radius, from: from, to: to)
        let closed = abs(to - from - 2 * .pi) < 1e-6
        let first = curve.first!, last = curve.last!
        let raster = try image { x, y in
            let angle = atan2(y - 256, x - 256)
            let onArc = closed || (angle >= from && angle <= to)
            let separation = onArc ? abs(hypot(x - 256, y - 256) - radius)
                : min(hypot(x - Double(first.x), y - Double(first.y)),
                      hypot(x - Double(last.x), y - Double(last.y)))
            let coverage = min(1, max(0, 1.25 - separation))
            return 255 * (1 - coverage)
        }
        return Fixture(name: name, image: raster, curves: [curve])
    }

    private static func mappedCurves(_ fixture: Fixture, settings: ProcessingSettings) -> [[CGPoint]] {
        let canvas = settings.canvasSize!
        let margin = max(1, settings.lineWidth / 2 + 1) + settings.endExtension
        let inner = CGRect(origin: .zero, size: canvas).insetBy(dx: margin, dy: margin)
        let scale = min(Double(inner.width) / Double(fixture.image.width),
                        Double(inner.height) / Double(fixture.image.height))
        let origin = CGPoint(x: inner.midX - Double(fixture.image.width) * scale / 2,
                             y: inner.midY - Double(fixture.image.height) * scale / 2)
        return fixture.curves.map { curve in
            curve.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
        }
    }

    private static func validatePath(_ plan: DrawingPlan, settings: ProcessingSettings) throws {
        let margin = max(1, settings.lineWidth / 2 + 1) + settings.endExtension
        let safe = CGRect(origin: .zero, size: plan.size).insetBy(dx: margin, dy: margin)
        try require(plan.size == settings.canvasSize!, "Plan changed logical canvas size")
        try require(plan.lineWidth == settings.lineWidth, "Plan changed physical brush width")
        try require(plan.strokes.count <= 36_000 && plan.pointCount <= 240_000, "Complete plan exceeded path budget")
        for stroke in plan.strokes {
            try require(stroke.points.count >= 2, "Cannot execute a one-point stroke")
            for p in stroke.points {
                try require(p.x.isFinite && p.y.isFinite, "Non-finite mouse coordinate")
                try require(p.x >= safe.minX - 1e-6 && p.x <= safe.maxX + 1e-6 &&
                            p.y >= safe.minY - 1e-6 && p.y <= safe.maxY + 1e-6,
                            "Path escaped physical brush/endpoint safety margin")
            }
            let length = segments([stroke.points]).reduce(0.0) { $0 + $1.length }
            try require(length + 1e-6 >= settings.minimumMovement,
                        "An independent stroke is shorter than the measured visibility threshold")
        }
    }

    private static func check(_ fixture: Fixture, settings: ProcessingSettings,
                              minimumCoverage: Double = 0.95,
                              maximumStrokes: Int = 12,
                              lengthRatio: ClosedRange<Double> = 0.85...1.2) throws -> DrawingPlan {
        let plan = try ImageProcessor.makePlan(image: fixture.image, mode: .outline, settings: settings)
        try validatePath(plan, settings: settings)
        let expected = segments(mappedCurves(fixture, settings: settings))
        let actual = segments(plan.strokes.map(\.points))
        let margin = max(1, settings.lineWidth / 2 + 1) + settings.endExtension
        let inner = CGRect(origin: .zero, size: settings.canvasSize!).insetBy(dx: margin, dy: margin)
        let sourcePixel = min(Double(inner.width) / Double(fixture.image.width),
                              Double(inner.height) / Double(fixture.image.height))
        // Positional accuracy depends on pen width and source sampling, not
        // the visibility length of an isolated stroke.
        let tolerance = settings.lineWidth + sourcePixel / 2
        let coverage = nearFraction(samples(expected), segments: actual, tolerance: tolerance)
        let precision = nearFraction(samples(actual), segments: expected, tolerance: tolerance)
        let expectedLength = expected.reduce(0) { $0 + $1.length }
        let ratio = plan.strokeLength / expectedLength
        print(String(format: "%@: coverage=%.4f precision=%.4f lengthRatio=%.3f strokes=%d points=%d tolerance=%.2f",
                     fixture.name, coverage, precision, ratio, plan.strokes.count, plan.pointCount, tolerance))
        try require(coverage >= minimumCoverage, "\(fixture.name): lost continuous source ink (coverage \(coverage))")
        try require(precision >= 0.995, "\(fixture.name): introduced paths away from source ink (precision \(precision))")
        try require(lengthRatio.contains(ratio), "\(fixture.name): missing ink or double tracing (length ratio \(ratio))")
        try require(plan.strokes.count <= maximumStrokes, "\(fixture.name): a continuous curve became fragmented")
        return plan
    }

    static func main() throws {
        setbuf(stdout, nil)
        let settings = ProcessingSettings(maxDimension: 32, darkness: 1, lineWidth: 1.2,
                                          canvasAspect: 8, minimumMovement: 3,
                                          canvasSize: CGSize(width: 512, height: 512), backingScale: 2,
                                          minimumSpacingX: 6, minimumSpacingY: 6)
        var failures: [String] = []
        func inspect(_ fixture: Fixture, settings: ProcessingSettings,
                     minimumCoverage: Double = 0.95, maximumStrokes: Int = 12,
                     lengthRatio: ClosedRange<Double> = 0.85...1.2) -> DrawingPlan? {
            do {
                return try check(fixture, settings: settings, minimumCoverage: minimumCoverage,
                                 maximumStrokes: maximumStrokes, lengthRatio: lengthRatio)
            } catch {
                failures.append("\(fixture.name): \(error)")
                return nil
            }
        }
        let diagonal = try lineFixture("thin diagonal", curves: [[CGPoint(x: 52, y: 448), CGPoint(x: 448, y: 52)]])
        let diagonalPlan = try check(diagonal, settings: settings, minimumCoverage: 0.99, maximumStrokes: 2)
        _ = inspect(try circularFixture("closed circle", radius: 174),
                      settings: settings, minimumCoverage: 0.98, maximumStrokes: 4)
        _ = inspect(try circularFixture("open circular arc", radius: 170, from: -2.4, to: 0.75),
                      settings: settings, minimumCoverage: 0.97, maximumStrokes: 4)
        _ = inspect(try lineFixture("parallel pencil lines", curves: [
            [CGPoint(x: 247, y: 64), CGPoint(x: 247, y: 448)],
            [CGPoint(x: 265, y: 64), CGPoint(x: 265, y: 448)]
        ]), settings: settings, minimumCoverage: 0.99, maximumStrokes: 4)
        _ = inspect(try lineFixture("pale gray fine line", curves: diagonal.curves, ink: 190),
                      settings: settings, minimumCoverage: 0.98, maximumStrokes: 3)
        _ = inspect(try lineFixture("off-white paper", curves: diagonal.curves, ink: 48, paper: 246),
                      settings: settings, minimumCoverage: 0.98, maximumStrokes: 3)
        _ = inspect(try lineFixture("crossing strokes", curves: [
            [CGPoint(x: 72, y: 72), CGPoint(x: 440, y: 440)],
            [CGPoint(x: 72, y: 440), CGPoint(x: 440, y: 72)]
        ]), settings: settings, minimumCoverage: 0.97, maximumStrokes: 8)

        // These short right-angle ends are below the executable movement limit,
        // but exceed the geometry error allowance. Losing an impossible end may
        // not discard the long, otherwise drawable body of the same stroke.
        let hookedLine = try lineFixture("long line with short right-angle ends", curves: [[
            CGPoint(x: 64, y: 253.8), CGPoint(x: 64, y: 256),
            CGPoint(x: 448, y: 256), CGPoint(x: 448, y: 258.2)
        ]])
        let lineBody = Fixture(name: hookedLine.name, image: hookedLine.image, curves: [[
            CGPoint(x: 64, y: 256), CGPoint(x: 448, y: 256)
        ]])
        _ = inspect(lineBody, settings: settings, minimumCoverage: 0.985, maximumStrokes: 3)
        let spur = Segment(a: CGPoint(x: 430, y: 256), b: CGPoint(x: 432.2, y: 256))
        let circleWithSpur = try image { x, y in
            let separation = min(abs(hypot(x - 256, y - 256) - 174),
                                 distance(CGPoint(x: x, y: y), to: spur))
            return 255 * (1 - min(1, max(0, 1.25 - separation)))
        }
        _ = inspect(Fixture(name: "closed circle with short spur", image: circleWithSpur,
                            curves: [circle(radius: 174)]),
                    settings: settings, minimumCoverage: 0.98, maximumStrokes: 6)

        var movement = settings
        movement.minimumMovement = 7
        _ = inspect(diagonal, settings: movement, minimumCoverage: 0.98, maximumStrokes: 2)
        movement.minimumMovement = 8
        _ = inspect(try circularFixture("M8 smooth closed circle", radius: 174),
                    settings: movement, minimumCoverage: 0.98, maximumStrokes: 4)
        var wideSpacing = settings
        wideSpacing.minimumSpacingX = 18
        wideSpacing.minimumSpacingY = 24
        _ = inspect(diagonal, settings: wideSpacing, minimumCoverage: 0.98, maximumStrokes: 2)
        var standardScreen = settings
        standardScreen.backingScale = 1
        let standard = try ImageProcessor.makePlan(image: diagonal.image, mode: .outline, settings: standardScreen)
        try require(standard.strokes.map(\.points) == diagonalPlan.strokes.map(\.points),
                    "Retina changed mouse coordinates instead of preview pixels")
        try require(standard.preview.width == 512 && diagonalPlan.preview.width == 1024,
                    "Preview must use the display backing scale")
        var obsoleteControls = settings
        obsoleteControls.maxDimension = 640
        obsoleteControls.canvasAspect = 0.2
        let same = try ImageProcessor.makePlan(image: diagonal.image, mode: .outline, settings: obsoleteControls)
        try require(same.strokes.map(\.points) == diagonalPlan.strokes.map(\.points),
                    "Legacy detail/aspect controls changed a physical outline")

        let gap = try lineFixture("significant white gap", curves: [
            [CGPoint(x: 40, y: 256), CGPoint(x: 208, y: 256)],
            [CGPoint(x: 304, y: 256), CGPoint(x: 472, y: 256)]
        ])
        let gapRect = CGRect(x: 235, y: 240, width: 42, height: 32)
        if let separated = inspect(gap, settings: settings, minimumCoverage: 0.98, maximumStrokes: 4) {
            for p in samples(segments(separated.strokes.map(\.points))) {
                try require(!gapRect.contains(p), "Minimum movement simplification crossed a significant white hole")
            }
        }

        for paper in [255.0, 246.0] {
            let blank = try image { _, _ in paper }
            let plan = try ImageProcessor.makePlan(image: blank, mode: .outline, settings: settings)
            try require(plan.strokes.isEmpty, "Blank white or near-white paper became an outline")
        }

        // Most pixels are midtone, so this fixture exercises photo edge detection
        // rather than the sparse-ink line-art classification used above.
        let photoImage = try image { x, y in
            let background = 112 + 72 * x / 512
            return hypot(x - 256, y - 256) < 145 ? 24 : background
        }
        let photo = Fixture(name: "photo NMS disk boundary", image: photoImage, curves: [circle(radius: 145)])
        _ = inspect(photo, settings: settings, minimumCoverage: 0.96, maximumStrokes: 8, lengthRatio: 0.85...1.3)

        // Dense, repeated structure spans every quadrant. A budget reduction may
        // coarsen the complete image, but may not silently keep only its start.
        let dense = try image(width: 2048, height: 2048) { x, y in
            let ix = Int(x), iy = Int(y)
            let line = ix % 16 == 0 || iy % 16 == 0
            return line ? 0 : 255
        }
        var budgetSettings = settings
        budgetSettings.canvasSize = CGSize(width: 1800, height: 1800)
        budgetSettings.minimumMovement = 1.5
        let bounded = try ImageProcessor.makePlan(image: dense, mode: .outline, settings: budgetSettings)
        try validatePath(bounded, settings: budgetSettings)
        let quadrants = bounded.strokes.flatMap(\.points).reduce(into: Set<Int>()) { found, p in
            found.insert((p.x >= 900 ? 1 : 0) + (p.y >= 900 ? 2 : 0))
        }
        try require(quadrants.count == 4, "Budget handling silently truncated whole image quadrants")

        // Optional real-image statistics for local investigation. No user's file
        // path or exact photograph is baked into the reproducible regression.
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let source = try ImageProcessor.loadImage(url: url)
            let plan = try ImageProcessor.makePlan(image: source, mode: .outline, settings: settings)
            try validatePath(plan, settings: settings)
            print("Real image \(source.width)×\(source.height): strokes=\(plan.strokes.count), points=\(plan.pointCount), length=\(plan.strokeLength), sample=\(plan.sampleSize)")
            if CommandLine.arguments.contains("--cat-eyes") {
                // Explicit optional QA of the supplied cat drawing: measure the
                // source ink in both eyes independently, not overall path count.
                // Regions are normalized; no user-specific path is retained.
                var actualSettings = settings
                actualSettings.canvasSize = CGSize(width: 368, height: 364)
                actualSettings.lineWidth = 2
                actualSettings.minimumMovement = 2
                var zeroSettings = actualSettings
                zeroSettings.minimumMovement = 0
                let actual = try ImageProcessor.makePlan(image: source, mode: .outline, settings: actualSettings)
                let zero = try ImageProcessor.makePlan(image: source, mode: .outline, settings: zeroSettings)
                try validatePath(actual, settings: actualSettings)
                let actualSegments = segments(actual.strokes.map(\.points))
                let zeroSegments = segments(zero.strokes.map(\.points))
                let values = try grayPixels(source)
                let inner = CGRect(origin: .zero, size: actualSettings.canvasSize!).insetBy(dx: 2, dy: 2)
                let scale = min(Double(inner.width) / Double(source.width),
                                Double(inner.height) / Double(source.height))
                let origin = CGPoint(x: inner.midX - Double(source.width) * scale / 2,
                                     y: inner.midY - Double(source.height) * scale / 2)
                let areas: [(String, CGRect)] = [
                    ("upper eye", CGRect(x: 0.57, y: 0.24, width: 0.16, height: 0.20)),
                    ("lower eye", CGRect(x: 0.27, y: 0.57, width: 0.21, height: 0.23))
                ]
                for (name, normalized) in areas {
                    let area = CGRect(x: normalized.minX * Double(source.width),
                                      y: normalized.minY * Double(source.height),
                                      width: normalized.width * Double(source.width),
                                      height: normalized.height * Double(source.height))
                    var ink: [CGPoint] = []
                    for y in max(0, Int(area.minY))..<min(source.height, Int(ceil(area.maxY))) {
                        for x in max(0, Int(area.minX))..<min(source.width, Int(ceil(area.maxX))) {
                            if values[y * source.width + x] < 128 {
                                ink.append(CGPoint(x: origin.x + (Double(x) + 0.5) * scale,
                                                   y: origin.y + (Double(y) + 0.5) * scale))
                            }
                        }
                    }
                    let tolerance = actualSettings.lineWidth + scale / 2
                    let retained = nearFraction(ink, segments: actualSegments, tolerance: tolerance)
                    let reference = nearFraction(ink, segments: zeroSegments, tolerance: tolerance)
                    print(String(format: "Cat %@ at 368×364 pt, brush=2: sourcePixels=%d M=0 coverage=%.4f M=2 coverage=%.4f",
                                 name, ink.count, reference, retained))
                    try require(ink.count >= 20 && reference >= 0.97, "\(name): unreliable source-eye reference")
                    try require(retained >= 0.90, "\(name): minimum movement discarded visible eye ink")
                }
            }
        }
        try require(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS continuous curves / pale ink / photo NMS / no double tracing / white gap / movement / Retina / complete budget")
        print("All outline quality checks passed.")
    }
}
