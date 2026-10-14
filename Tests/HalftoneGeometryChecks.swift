import AppKit
import CoreGraphics
import Foundation

@main
struct HalftoneGeometryChecks {
    enum Failure: Error { case check(String) }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    static func image(width: Int, height: Int, value: (Double, Double) -> UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = value((Double(x) + 0.5) / Double(width),
                                              (Double(y) + 0.5) / Double(height))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent) else {
            throw Failure.check("Cannot create independent fixture")
        }
        return result
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw Failure.check("Cannot read preview")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height))
    }

    static func meanGray(_ plan: DrawingPlan, in rect: CGRect) throws -> Double {
        let values = try pixels(plan.preview)
        let scaleX = Double(plan.preview.width) / Double(plan.size.width)
        let scaleY = Double(plan.preview.height) / Double(plan.size.height)
        let left = max(0, Int(ceil(rect.minX * scaleX)))
        let right = min(plan.preview.width, Int(floor(rect.maxX * scaleX)))
        let top = max(0, Int(ceil(rect.minY * scaleY)))
        let bottom = min(plan.preview.height, Int(floor(rect.maxY * scaleY)))
        try require(right > left && bottom > top, "Empty independent preview inspection area")
        var total = 0.0
        for y in top..<bottom {
            for x in left..<right { total += Double(values[y * plan.preview.width + x]) }
        }
        return total / Double((right - left) * (bottom - top)) / 255
    }

    static func safeRect(_ settings: ProcessingSettings) -> CGRect {
        let margin = max(1, settings.lineWidth / 2 + 1) + settings.endExtension
        return CGRect(origin: .zero, size: settings.canvasSize!).insetBy(dx: margin, dy: margin)
    }

    static func validate(_ plan: DrawingPlan, settings: ProcessingSettings) throws {
        let safe = safeRect(settings)
        try require(plan.size == settings.canvasSize! && plan.lineWidth == settings.lineWidth,
                    "Physical units changed while generating halftone")
        try require(plan.strokes.count <= 36_000 && plan.pointCount <= 240_000,
                    "Complete-image plan exceeds its path budget")
        try require(plan.effectiveSpacingX > 0 && plan.effectiveSpacingY > 0 &&
                    plan.sampleSize.width > 0 && plan.sampleSize.height > 0,
                    "The extraction raster has invalid physical spacing")
        // Variable pulse lengths are allowed; a pulse remains one straight
        // drag, without extra vertices, replayed paths or artificial cell fills.
        var seen = Set<String>()
        for stroke in plan.strokes {
            try require(stroke.points.count == 2, "One mark became a zigzag or multi-pass filled block")
            let a = stroke.points[0], b = stroke.points[1]
            try require(a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite,
                        "A mouse coordinate is not finite")
            let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
            try require(dx < 1e-8 || dy < 1e-8, "A mark is not one horizontal or vertical drag")
            let length = hypot(dx, dy)
            try require(length + 1e-8 >= settings.minimumMovement && length > 0,
                        "A halftone drag does not reach the measured minimum movement")
            if dy < 1e-8 {
                let row = (Double(a.y) - safe.minY) / plan.effectiveSpacingY - 0.5
                try require(abs(row - row.rounded()) < 1e-7 && row >= -1e-7 &&
                            row < plan.sampleSize.height,
                            "An artificial sub-row was added to fill a synthetic black cell")
            }
            let first = a.x < b.x || (a.x == b.x && a.y < b.y) ? a : b
            let last = first == a ? b : a
            let key = "\(first.x),\(first.y):\(last.x),\(last.y)"
            try require(seen.insert(key).inserted, "The identical mouse mark was replayed more than once")
            for point in stroke.points {
                try require(point.x >= safe.minX - 1e-8 && point.x <= safe.maxX + 1e-8 &&
                            point.y >= safe.minY - 1e-8 && point.y <= safe.maxY + 1e-8,
                            "A path escaped the brush/endpoint safety margin")
            }
        }
    }

    static func horizontal(_ plan: DrawingPlan) -> [Stroke] {
        plan.strokes.filter { abs($0.points[0].y - $0.points[1].y) < 1e-8 }
    }

    static func medianFootprint(_ plan: DrawingPlan, settings: ProcessingSettings, left: Bool) -> Double {
        let safe = safeRect(settings)
        let positions = horizontal(plan).filter {
            $0.points[0].y > safe.minY + 20 && $0.points[0].y < safe.maxY - 20
        }.map { stroke in
            left ? min(stroke.points[0].x, stroke.points[1].x) - settings.lineWidth / 2
                 : max(stroke.points[0].x, stroke.points[1].x) + settings.lineWidth / 2
        }.sorted()
        return positions.isEmpty ? .infinity : positions[positions.count / 2]
    }

    static func main() throws {
        setbuf(stdout, nil)
        let settings = ProcessingSettings(maxDimension: 32, darkness: 1, lineWidth: 1,
                                          canvasAspect: 9, minimumMovement: 8,
                                          canvasSize: CGSize(width: 240, height: 180), backingScale: 2,
                                          minimumSpacingX: 2.25, minimumSpacingY: 2.25,
                                          endExtension: 0.5)
        let safe = safeRect(settings)
        let inspection = safe.insetBy(dx: 10, dy: 10)
        // Independent source dimensions match the safe canvas aspect. They
        // never depend on the algorithm's grid, so a coarse grid cannot pass
        // just because its fixture was constructed from that same coarse grid.
        let sourceWidth = 236, sourceHeight = 176
        let blackImage = try image(width: sourceWidth, height: sourceHeight) { _, _ in 0 }
        let black = try ImageProcessor.makePlan(image: blackImage, mode: .halftone, settings: settings)
        try validate(black, settings: settings)
        try require(black.effectiveSpacingX <= 0.6,
                    "Minimum drag length unnecessarily quantized start/end sampling")
        try require(black.effectiveSpacingY >= settings.lineWidth && black.effectiveSpacingY < 1.02,
                    "Independent-stroke spacing incorrectly limits connected dark-region density")
        try require(black.strokes.count >= Int(black.sampleSize.height) - 2 &&
                    black.strokes.count <= Int(black.sampleSize.height) + 2,
                    "A solid source must use approximately one continuous drag per pen-width row")
        for stroke in black.strokes {
            try require(abs(stroke.points[1].x - stroke.points[0].x) >= safe.width * 0.98,
                        "A continuous black row was split into repeated short cell fills")
        }
        try require(try meanGray(black, in: inspection) < 0.02,
                    "A full-black source became pale separated dashes")
        print("PASS solid black: dense pen-width rows, one continuous drag each")

        var half: DrawingPlan?
        for tone in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            let fixture = try image(width: sourceWidth, height: sourceHeight) { _, _ in
                UInt8((tone * 255).rounded())
            }
            let plan = try ImageProcessor.makePlan(image: fixture, mode: .halftone, settings: settings)
            try validate(plan, settings: settings)
            let actual = try meanGray(plan, in: inspection)
            try require(abs(actual - tone) < 0.03,
                        "Physical preview tone \(actual) does not reproduce source gray \(tone)")
            if tone == 0.5 { half = plan }
            if tone == 1 {
                let values = try pixels(plan.preview)
                try require(plan.strokes.isEmpty && values.allSatisfy { $0 == 255 },
                            "A pure white source acquired ink")
            }
            print("PASS source gray \(tone): preview gray \(String(format: "%.4f", actual))")
        }
        let halfLengths = half!.strokes.map { hypot($0.points[1].x - $0.points[0].x,
                                                  $0.points[1].y - $0.points[0].y) }
        let blackLengths = black.strokes.map { abs($0.points[1].x - $0.points[0].x) }
        try require((blackLengths.min() ?? 0) > (halfLengths.max() ?? 0) * 5,
                    "Continuous ink and gray pulses are still forced into one fixed-length cell")

        func band(_ shift: Double) throws -> CGImage {
            try image(width: sourceWidth * 4, height: sourceHeight * 4) { x, _ in
                let physicalX = x * safe.width
                return physicalX >= 37.25 + shift && physicalX < 101.75 + shift ? 0 : 255
            }
        }
        let firstBand = try ImageProcessor.makePlan(image: band(0), mode: .halftone, settings: settings)
        let shiftedBand = try ImageProcessor.makePlan(image: band(2), mode: .halftone, settings: settings)
        try validate(firstBand, settings: settings)
        try validate(shiftedBand, settings: settings)
        for left in [true, false] {
            let expected = safe.minX + (left ? 37.25 : 101.75)
            let initial = medianFootprint(firstBand, settings: settings, left: left)
            let shifted = medianFootprint(shiftedBand, settings: settings, left: left)
            try require(abs(initial - expected) < 1.25 && abs(shifted - initial - 2) < 0.75,
                        "A 2-point source-boundary shift was rounded to the 8-point minimum drag")
        }
        var longerSettings = settings
        longerSettings.minimumMovement = 18
        let longer = try ImageProcessor.makePlan(image: blackImage, mode: .halftone, settings: longerSettings)
        try validate(longer, settings: longerSettings)
        try require(longer.sampleSize == black.sampleSize,
                    "Minimum whole-stroke length changed fine start/end observations")
        print("PASS fine physical start/end placement, independent of whole-stroke minimum")

        let gapImage = try image(width: sourceWidth * 2, height: sourceHeight * 2) { x, _ in
            x > 0.35 && x < 0.65 ? 255 : 0
        }
        let gap = try ImageProcessor.makePlan(image: gapImage, mode: .halftone, settings: settings)
        try validate(gap, settings: settings)
        let coreLeft = safe.minX + safe.width * 0.40
        let coreRight = safe.minX + safe.width * 0.60
        for stroke in gap.strokes {
            try require(max(stroke.points[0].x, stroke.points[1].x) + settings.lineWidth / 2 < coreLeft ||
                        min(stroke.points[0].x, stroke.points[1].x) - settings.lineWidth / 2 > coreRight,
                        "An executable minimum drag crossed an entirely white source gap")
        }
        try require(try meanGray(gap, in: CGRect(x: coreLeft, y: inspection.minY,
                                               width: coreRight - coreLeft, height: inspection.height)) > 0.99,
                    "Rendered ink invaded the broad white source gap")
        try require(gap.strokes.contains { $0.points[0].x < coreLeft } &&
                    gap.strokes.contains { $0.points[0].x > coreRight },
                    "One side of a separated dark source was discarded")

        // Preserve a one-source-pixel vertical line with a vertical drag. It
        // cannot be represented by an 8-point horizontal mark without widening.
        let thinImage = try image(width: sourceWidth, height: sourceHeight) { x, y in
            Int(x * Double(sourceWidth)) == 118 && y >= 0.25 && y < 0.75 ? 0 : 255
        }
        let thin = try ImageProcessor.makePlan(image: thinImage, mode: .halftone, settings: settings)
        try validate(thin, settings: settings)
        let vertical = thin.strokes.filter { abs($0.points[0].x - $0.points[1].x) < 1e-8 }
        try require(vertical.contains { abs($0.points[1].y - $0.points[0].y) > 70 },
                    "A long thin vertical source disappeared because it is narrower than horizontal M")
        try require(thin.strokes.count <= 4, "Thin source ink was synthesized from many widened short marks")
        let lineX = safe.minX + 118.5
        for stroke in thin.strokes {
            for point in stroke.points {
                try require(abs(point.x - lineX) <= 1.5,
                            "Thin vertical ink was widened outside its actual source neighborhood")
            }
        }
        print("PASS broad white gap and thin vertical source retention")

        // Tiny black source pixels on faint gray paper contribute their area;
        // no individual pixel may force a complete minimum-length pulse.
        // Here 0.5-by-1-point black pixels repeat at 20-by-4-point intervals.
        let sparse = try image(width: sourceWidth * 2, height: sourceHeight * 2) { x, y in
            let ix = Int(x * Double(sourceWidth * 2))
            let iy = Int(y * Double(sourceHeight * 2))
            return ix % 40 == 20 && iy % 8 < 2 ? 0 : 252
        }
        let sparsePlan = try ImageProcessor.makePlan(image: sparse, mode: .halftone, settings: settings)
        try validate(sparsePlan, settings: settings)
        let sparseInk = 1 - (try meanGray(sparsePlan, in: inspection))
        let sourceInk = (1 - 252.0 / 255) * (1 - 1.0 / 160) + 1.0 / 160
        try require(abs(sparseInk - sourceInk) < 0.03 && sparseInk < 0.07,
                    "Sparse black pixels on 0.99-gray paper expanded into excessive ink: \(sparseInk)")
        print("PASS sparse high-contrast pixels: ink fraction \(String(format: "%.4f", sparseInk))")

        for movement in [0.0, 0.05, 8.0] {
            var fine = settings
            fine.canvasSize = CGSize(width: 64, height: 72)
            fine.lineWidth = 0.25
            fine.minimumMovement = movement
            fine.minimumSpacingX = 0.1
            fine.minimumSpacingY = 0.1
            fine.backingScale = 1
            let fixture = try image(width: 247, height: 279) { _, _ in 128 }
            let first = try ImageProcessor.makePlan(image: fixture, mode: .halftone, settings: fine)
            try validate(first, settings: fine)
            fine.backingScale = 2
            let second = try ImageProcessor.makePlan(image: fixture, mode: .halftone, settings: fine)
            try validate(second, settings: fine)
            try require(first.sampleSize == second.sampleSize &&
                        first.strokes.map(\.points) == second.strokes.map(\.points) &&
                        first.effectiveSpacingX == second.effectiveSpacingX &&
                        first.effectiveSpacingY == second.effectiveSpacingY,
                        "Retina changed the physical mouse geometry")
            try require(second.preview.width == first.preview.width * 2 &&
                        second.preview.height == first.preview.height * 2,
                        "Retina must change preview pixels while preserving mouse paths")
        }
        print("PASS Retina-independent subpixel paths including M0 and M8")

        // An extremely fine pen may reduce the budget to one source column.
        // That physical column can still contain a full-length drag; do not
        // require two samples and silently turn a black image into blank paper.
        var tiny = settings
        tiny.lineWidth = 0.0001
        let reduced = try ImageProcessor.makePlan(image: blackImage, mode: .halftone, settings: tiny)
        try validate(reduced, settings: tiny)
        try require(!reduced.strokes.isEmpty && reduced.resolutionNote?.contains("预算") == true &&
                    reduced.sampleSize.width * reduced.sampleSize.height <= 1_000_000,
                    "Single-column budget degradation silently lost the whole black image")
        print("PASS single-column extreme-brush budget, complete nonempty image")

        var ending = settings
        ending.endExtension = 10
        let reserved = try ImageProcessor.makePlan(image: blackImage, mode: .halftone, settings: ending)
        try validate(reserved, settings: ending)
        var impossible = settings
        impossible.minimumMovement = 1000
        do {
            _ = try ImageProcessor.makePlan(image: blackImage, mode: .halftone, settings: impossible)
            throw Failure.check("A minimum movement wider than the canvas must be rejected")
        } catch let error as Failure { throw error }
        catch { }
        print("All dense halftone geometry checks passed.")
    }
}
