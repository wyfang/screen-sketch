import AppKit

@main struct ImageToneChecks {
    enum Failure: Error { case check(String) }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    static func fixture(width: Int = 96, height: Int = 128,
                        _ sample: (Int, Int) -> UInt8) -> CGImage {
        let values = (0..<(width * height)).map { sample($0 % width, $0 / width) }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(values) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height))
    }

    static func fingerprints(_ plan: DrawingPlan) -> (UInt64, UInt64) {
        func mix(_ value: UInt64, into hash: inout UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                hash = (hash ^ ((value >> shift) & 255)) &* 1_099_511_628_211
            }
        }
        var geometry: UInt64 = 14_695_981_039_346_656_037
        mix(UInt64(plan.strokes.count), into: &geometry)
        for stroke in plan.strokes {
            mix(UInt64(stroke.points.count), into: &geometry)
            for point in stroke.points {
                mix(Double(point.x).bitPattern, into: &geometry)
                mix(Double(point.y).bitPattern, into: &geometry)
            }
        }
        var preview: UInt64 = 14_695_981_039_346_656_037
        mix(UInt64(plan.preview.width), into: &preview)
        mix(UInt64(plan.preview.height), into: &preview)
        for value in pixels(plan.preview) { preview = (preview ^ UInt64(value)) &* 1_099_511_628_211 }
        return (geometry, preview)
    }

    static func neutralFixture() -> CGImage {
        fixture { x, y in
            if x < 10 || x > 85 || y < 12 || y > 115 { return 255 }
            if (x - 48) * (x - 48) + (y - 42) * (y - 42) < 18 * 18 { return 80 }
            if y > 70 && x > 20 && x < 75 { return UInt8(40 + (x - 20) * 3) }
            if abs(y - x) < 3 { return 0 }
            return 240
        }
    }

    static func main() throws {
        setbuf(stdout, nil)
        let source = neutralFixture()
        let physical = ProcessingSettings(lineWidth: 1, minimumMovement: 2,
            canvasSize: CGSize(width: 100, height: 132), backingScale: 1,
            minimumSpacingX: 2, minimumSpacingY: 2)
        let compatible = ProcessingSettings(maxDimension: 128, lineWidth: 1,
            canvasAspect: 0.75, minimumMovement: 2)

        #if TONE_BASELINE
        for (name, settings) in [("physical", physical), ("compatible", compatible)] {
            for mode in DrawingMode.allCases {
                let plan = try ImageProcessor.makePlan(image: source, mode: mode, settings: settings)
                let hashes = fingerprints(plan)
                print("\(name)-\(mode.rawValue): (\(hashes.0), \(hashes.1)), strokes \(plan.strokes.count)")
            }
        }
        #else
        // Captured from the unmodified 1.7.10 processor with this exact fixture.
        let baseline: [String: (UInt64, UInt64)] = [
            "physical-outline": (17_202_582_683_864_333_925, 5_073_571_777_681_620_060),
            "physical-halftone": (14_180_903_515_884_102_951, 756_346_680_297_190_953),
            "physical-sketch": (4_094_936_463_018_112_446, 12_532_601_425_364_914_015),
            "physical-solid": (1_696_793_182_474_628_290, 952_512_187_998_311_079),
            "compatible-outline": (7_667_747_960_946_723_250, 17_375_263_305_814_102_564),
            "compatible-halftone": (1_327_938_657_816_713_755, 11_157_967_174_419_693_254),
            "compatible-sketch": (7_808_426_701_134_134_049, 7_928_213_371_748_511_700),
            "compatible-solid": (325_232_916_490_799_300, 3_722_918_344_998_734_649)
        ]
        for (name, settings) in [("physical", physical), ("compatible", compatible)] {
            for mode in DrawingMode.allCases {
                let plan = try ImageProcessor.makePlan(image: source, mode: mode, settings: settings)
                let hashes = fingerprints(plan)
                let key = "\(name)-\(mode.rawValue)"
                let expected = baseline[key]!
                try check(hashes.0 == expected.0 && hashes.1 == expected.1,
                          "Neutral adjustment changed existing \(key) geometry or preview")
            }
        }

        let identity = ImageProcessor.grayscaleToneLUT(exposure: 0, contrast: 1, shadowLift: 0)
        try check(identity == (0...255).map(UInt8.init), "Neutral tone LUT is not exact identity")
        for exposure in [-2.0, 0, 2] {
            for contrast in [0.5, 1, 1.8] {
                for shadow in [0.0, 0.5, 1] {
                    let lut = ImageProcessor.grayscaleToneLUT(exposure: exposure, contrast: contrast,
                                                              shadowLift: shadow)
                    try check(lut.first == 0 && lut.last == 255, "Tone adjustment changed paper or solid black")
                    try check(zip(lut, lut.dropFirst()).allSatisfy { $0 <= $1 },
                              "Tone adjustment reversed brightness ordering")
                }
            }
        }
        let brighter = ImageProcessor.grayscaleToneLUT(exposure: 1, contrast: 1, shadowLift: 0)
        let darker = ImageProcessor.grayscaleToneLUT(exposure: -1, contrast: 1, shadowLift: 0)
        let contrast = ImageProcessor.grayscaleToneLUT(exposure: 0, contrast: 1.8, shadowLift: 0)
        let shadows = ImageProcessor.grayscaleToneLUT(exposure: 0, contrast: 1, shadowLift: 1)
        try check(brighter[96] > 96 && darker[96] < 96, "Exposure directions are reversed")
        try check(contrast[64] < 64 && contrast[192] > 192, "Contrast does not separate light and dark")
        try check(shadows[64] > 64 && shadows[230] - 230 < shadows[64] - 64,
                  "Shadow lift does not preferentially open dark tones")

        // Tone settings must affect executable paths, including the legacy
        // uncalibrated canvas, rather than merely post-processing preview pixels.
        for settings in [physical, compatible] {
            var lighter = settings; lighter.exposure = 1
            var deeper = settings; deeper.exposure = -1
            let lightPlan = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: lighter)
            let neutralPlan = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: settings)
            let darkPlan = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: deeper)
            try check(lightPlan.strokeLength < neutralPlan.strokeLength && neutralPlan.strokeLength < darkPlan.strokeLength,
                      "Exposure was not applied to raster before drawing plans")
        }

        let paper = fixture { _, _ in 255 }
        for mode in DrawingMode.allCases {
            for settings in [physical, compatible] {
                var tone = settings
                tone.exposure = -2; tone.contrast = 0.5; tone.shadowLift = 1; tone.inkThresholdOffset = 64
                let plan = try ImageProcessor.makePlan(image: paper, mode: mode, settings: tone)
                try check(plan.strokes.isEmpty && pixels(plan.preview).allSatisfy { $0 == 255 },
                          "Adjusted white paper acquired ink in \(mode.rawValue)")
            }
        }

        for mode in DrawingMode.allCases {
            for original in [physical, compatible] {
                var tone = original
                tone.canvasSize = original.canvasSize == nil ? nil : CGSize(width: 192, height: 132)
                tone.canvasAspect = 2
                tone.exposure = -2; tone.contrast = 0.5; tone.shadowLift = 1; tone.inkThresholdOffset = 64
                let plan = try ImageProcessor.makePlan(image: source, mode: mode, settings: tone)
                let raster = pixels(plan.preview)
                let border = plan.preview.width / 6
                for y in 0..<plan.preview.height {
                    for x in 0..<border {
                        try check(raster[y * plan.preview.width + x] == 255
                            && raster[y * plan.preview.width + plan.preview.width - x - 1] == 255,
                            "Tone adjustment painted letterbox margins in \(mode.rawValue)")
                    }
                }
            }
        }

        let faceDetails = fixture { x, y in
            if x > 20 && x < 76 && y > 78 && y < 116 { return 0 }
            if ((x > 32 && x < 43) || (x > 53 && x < 64)) && y > 37 && y < 43 { return 170 }
            if x > 46 && x < 50 && y > 47 && y < 58 { return 170 }
            if x > 37 && x < 60 && y > 63 && y < 67 { return 170 }
            return 255
        }
        var detail = physical; detail.inkThresholdOffset = 64
        let normalFill = try ImageProcessor.makePlan(image: faceDetails, mode: .solid, settings: physical)
        let detailFill = try ImageProcessor.makePlan(image: faceDetails, mode: .solid, settings: detail)
        let normalPoints = normalFill.strokes.flatMap(\.points).filter { $0.y < 76 }
        let detailPoints = detailFill.strokes.flatMap(\.points).filter { $0.y < 76 }
        print("pale facial marks", normalPoints.count, "->", detailPoints.count)
        try check(detailPoints.count > normalPoints.count + 20, "Black threshold did not retain pale facial details")
        var blackOnly = physical; blackOnly.inkThresholdOffset = -64
        let darkFill = try ImageProcessor.makePlan(image: fixture { _, _ in 0 }, mode: .solid, settings: blackOnly)
        let darkPixels = pixels(darkFill.preview)
        var retainedBlack = 0.0
        for y in 32..<100 { for x in 25..<75 {
            retainedBlack += 1 - Double(darkPixels[y * darkFill.preview.width + x]) / 255
        }}
        try check(retainedBlack / (68 * 50) > 0.97, "Lower black threshold removed pure black ink")
        for mode in [DrawingMode.outline, .halftone, .sketch] {
            let unchanged = try ImageProcessor.makePlan(image: source, mode: mode, settings: physical)
            let offset = try ImageProcessor.makePlan(image: source, mode: mode, settings: detail)
            try check(fingerprints(unchanged) == fingerprints(offset), "Fill threshold leaked into \(mode.rawValue)")
        }
        for settings in [physical, compatible] {
            let invalid: [(String, (inout ProcessingSettings) -> Void)] = [
                ("exposure NaN", { $0.exposure = .nan }), ("exposure range", { $0.exposure = 2.1 }),
                ("contrast infinity", { $0.contrast = .infinity }), ("contrast range", { $0.contrast = 0.4 }),
                ("shadow NaN", { $0.shadowLift = .nan }), ("shadow range", { $0.shadowLift = -0.1 }),
                ("threshold infinity", { $0.inkThresholdOffset = -.infinity }),
                ("threshold range", { $0.inkThresholdOffset = 65 })
            ]
            for (name, mutate) in invalid {
                var value = settings; mutate(&value)
                var rejected = false
                do { _ = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: value) }
                catch { rejected = true }
                try check(rejected, "Accepted invalid \(name)")
            }
        }
        print("PASS neutral exact geometry / preview; tone order / endpoints / directions; executable exposure; paper; fill details / mode isolation; invalid settings")
        #endif
    }
}
