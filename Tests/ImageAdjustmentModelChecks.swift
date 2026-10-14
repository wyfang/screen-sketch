import Foundation
import CoreGraphics
import ImageIO

private final class AdjustmentGate {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }; return entered
    }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        entered = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(4)
        while !released { precondition(condition.wait(until: deadline), "adjustment gate timed out") }
    }
    func open() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private struct AdjustmentVisit {
    let mode: DrawingMode
    let settings: ProcessingSettings
}

private final class AdjustmentVisits {
    private let lock = NSLock()
    private var entries: [AdjustmentVisit] = []
    func record(_ mode: DrawingMode, _ settings: ProcessingSettings) {
        lock.lock(); entries.append(AdjustmentVisit(mode: mode, settings: settings)); lock.unlock()
    }
    var snapshot: [AdjustmentVisit] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}

private func adjustmentFixture(_ width: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 20))
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    context.fill(CGRect(x: 3, y: 3, width: 6, height: 8))
    return context.makeImage()!
}

private func adjustmentPlan(_ image: CGImage, _ mode: DrawingMode,
                            _ settings: ProcessingSettings) -> DrawingPlan {
    DrawingPlan(mode: mode, strokes: [Stroke(points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])],
                preview: image, size: settings.canvasSize ?? CGSize(width: image.width, height: image.height),
                lineWidth: settings.lineWidth, minimumMovement: settings.minimumMovement,
                sampleSize: CGSize(width: image.width, height: image.height),
                resolutionNote: "\(settings.exposure)/\(settings.contrast)/\(settings.shadowLift)/\(settings.inkThresholdOffset)")
}

@main @MainActor struct ImageAdjustmentModelChecks {
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        require(predicate(), message)
    }
    static func makeModel() -> (AppModel, UserDefaults, String) {
        let suite = "com.wangyifang.screensketch.adjustmentchecks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        return (AppModel(preferences: preferences, showsApplicationUI: false), preferences, suite)
    }
    static func cancel(_ model: AppModel) {
        model.image = nil; model.scheduleProcessing()
    }
    static func fixtureFiles() throws -> (URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screensketch-adjustments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
        for (index, url) in urls.enumerated() {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, adjustmentFixture(24 + index), nil)
            require(CGImageDestinationFinalize(destination), "fixture PNG writes")
        }
        return (directory, urls[0], urls[1])
    }
    static func values(_ model: AppModel) -> [Double] {
        ImageAdjustment.allCases.map { model.imageAdjustmentValue($0) }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let started = ProcessInfo.processInfo.systemUptime
        try await validationAndReset()
        try await persistenceAndDefaults()
        try await dragCoalescingAndCancellation()
        try await drawingRejectsEdits()
        print(String(format: "ImageAdjustmentModelChecks passed in %.3fs", ProcessInfo.processInfo.systemUptime - started))
    }

    static func validationAndReset() async throws {
        let (model, preferences, suite) = makeModel()
        let (directory, first, _) = try fixtureFiles()
        defer {
            cancel(model); preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let visits = AdjustmentVisits()
        model.testPlanBuilder = { image, mode, settings in
            visits.record(mode, settings); return adjustmentPlan(image, mode, settings)
        }
        model.load(first)
        let raw = model.image!
        let bytes = raw.dataProvider!.data! as Data
        model.editImageAdjustments(true)
        for adjustment in ImageAdjustment.allCases {
            require(model.setImageAdjustment(-999, adjustment: adjustment), "finite low values accepted and clamped")
            require(model.imageAdjustmentValue(adjustment) == adjustment.range.lowerBound, "low value clamps to actual slider range")
            require(model.setImageAdjustment(999, adjustment: adjustment), "finite high values accepted and clamped")
            require(model.imageAdjustmentValue(adjustment) == adjustment.range.upperBound, "high value clamps to actual slider range")
            let previous = model.imageAdjustmentValue(adjustment)
            for invalid in [Double.nan, .infinity, -.infinity] {
                require(!model.setImageAdjustment(invalid, adjustment: adjustment), "nonfinite adjustment rejected")
                require(model.imageAdjustmentValue(adjustment) == previous, "rejected adjustment cannot change current value")
            }
        }
        require(!model.imageAdjustmentsAreNeutral, "adjusted flag reflects nonneutral values")
        try await Task.sleep(nanoseconds: 260_000_000)
        require(visits.snapshot.isEmpty, "drag edits never start a processor before release")
        require(model.image === raw && (model.image!.dataProvider!.data! as Data) == bytes,
                "adjustment setters retain the original image and raw pixels")
        model.editImageAdjustments(false)
        try await waitUntil("adjusted previews complete") { !model.busy }
        require(visits.snapshot.count == DrawingMode.allCases.count, "one release starts exactly one generation")
        model.resetImageAdjustments()
        require(model.imageAdjustmentsAreNeutral && values(model) == [0, 1, 0, 0], "one reset restores all neutral values")
        require(model.plans.isEmpty && model.busy, "reset immediately invalidates old adjusted plans")
        try await waitUntil("neutral previews complete") { !model.busy }
        require(visits.snapshot.count == 2 * DrawingMode.allCases.count
                && visits.snapshot.suffix(4).allSatisfy {
                    $0.settings.exposure == 0 && $0.settings.contrast == 1
                    && $0.settings.shadowLift == 0 && $0.settings.inkThresholdOffset == 0
                }, "reset sends neutral parameters to all four modes exactly once")
        require(model.image === raw && (model.image!.dataProvider!.data! as Data) == bytes,
                "processing and reset do not alter the original image")
        print("PASS clamping, invalid values, raw-image preservation and one-click reset")
    }

    static func persistenceAndDefaults() async throws {
        let (firstModel, preferences, suite) = makeModel()
        let (directory, first, second) = try fixtureFiles()
        var models = [firstModel]
        defer {
            models.forEach(cancel); preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        firstModel.load(first); firstModel.editImageAdjustments(true)
        let wanted = [-0.75, 1.25, 0.35, 12.0]
        for (adjustment, value) in zip(ImageAdjustment.allCases, wanted) {
            require(firstModel.setImageAdjustment(value, adjustment: adjustment), "valid adjustment accepted")
        }
        cancel(firstModel)
        let restored = AppModel(preferences: preferences, showsApplicationUI: false)
        models.append(restored)
        restored.testPlanBuilder = adjustmentPlan
        require(restored.imageName == first.lastPathComponent && values(restored) == wanted,
                "relaunch restores adjustments for the last imported file")
        restored.load(first)
        require(values(restored) == wanted, "reimporting the same file retains adjustment values")
        restored.load(second)
        require(restored.imageAdjustmentsAreNeutral, "another file starts at neutral settings")
        restored.load(first)
        require(values(restored) == wanted, "reopening stored adjusted file restores its values")
        cancel(restored)
        preferences.set(-900.0, forKey: "imageExposure")
        preferences.set(900.0, forKey: "imageContrast")
        preferences.set(Double.nan, forKey: "imageShadowLift")
        preferences.removeObject(forKey: "imageFillThreshold")
        let sanitized = AppModel(preferences: preferences, showsApplicationUI: false)
        models.append(sanitized)
        sanitized.testPlanBuilder = adjustmentPlan
        require(values(sanitized) == [-2, 1.8, 0, 0], "restored values clamp and invalid or missing values use neutral defaults")
        sanitized.resetImageAdjustments()
        require(sanitized.imageAdjustmentsAreNeutral, "reset restores all saved defaults")
        cancel(sanitized)
        let resetRestored = AppModel(preferences: preferences, showsApplicationUI: false)
        models.append(resetRestored)
        resetRestored.testPlanBuilder = adjustmentPlan
        require(resetRestored.imageAdjustmentsAreNeutral, "reset survives relaunch")
        print("PASS same-file persistence, new-file defaults and invalid stored-value recovery")
    }

    static func dragCoalescingAndCancellation() async throws {
        let (model, preferences, suite) = makeModel()
        let (directory, first, _) = try fixtureFiles()
        let gate = AdjustmentGate(), visits = AdjustmentVisits()
        defer {
            gate.open(); cancel(model); preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        model.selectedMode = .solid
        model.testPlanBuilder = { image, mode, settings in
            visits.record(mode, settings)
            if settings.exposure == 0 { gate.wait() }
            return adjustmentPlan(image, mode, settings)
        }
        model.load(first)
        try await waitUntil("old tone request enters selected mode") { gate.hasEntered }
        model.editImageAdjustments(true)
        require(model.plans.isEmpty && model.busy && model.pendingPreviewModes.count == 4,
                "slider drag clears stale plans immediately")
        for exposure in [-0.2, -0.4, -0.6, -0.8] {
            require(model.setImageAdjustment(exposure, adjustment: .exposure), "drag exposure accepted")
        }
        _ = model.setImageAdjustment(1.2, adjustment: .contrast)
        _ = model.setImageAdjustment(0.4, adjustment: .shadows)
        _ = model.setImageAdjustment(10, adjustment: .fillThreshold)
        try await Task.sleep(nanoseconds: 280_000_000)
        require(visits.snapshot.count == 1, "multiple slider edits cannot start interim tone generations")
        model.editImageAdjustments(false)
        model.editImageAdjustments(false)
        try await waitUntil("final tone finishes without waiting for obsolete worker") { !model.busy }
        let finished = visits.snapshot
        require(finished.count == 5 && finished.dropFirst().map(\.mode) == [.solid, .outline, .halftone, .sketch],
                "release schedules one generation with selected mode first")
        require(finished.dropFirst().allSatisfy {
            $0.settings.exposure == -0.8 && $0.settings.contrast == 1.2
            && $0.settings.shadowLift == 0.4 && $0.settings.inkThresholdOffset == 10
        }, "every final preview uses the last values of all sliders")
        require(model.plans.count == 4 && model.plans.values.allSatisfy { $0.resolutionNote == "-0.8/1.2/0.4/10.0" },
                "all published plans belong to the final tone")
        gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        require(visits.snapshot.count == 5 && model.plans.count == 4
                && model.plans.values.allSatisfy { $0.resolutionNote == "-0.8/1.2/0.4/10.0" }
                && model.previewErrors.isEmpty && !model.busy,
                "late old tone cannot publish or process remaining modes")
        print("PASS drag coalescing, selected-mode priority and stale-tone cancellation")
    }

    static func drawingRejectsEdits() async throws {
        let (model, preferences, suite) = makeModel()
        let (directory, first, second) = try fixtureFiles()
        defer {
            model.running = false; cancel(model); preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let visits = AdjustmentVisits()
        model.testPlanBuilder = { image, mode, settings in
            visits.record(mode, settings); return adjustmentPlan(image, mode, settings)
        }
        model.load(first)
        _ = model.setImageAdjustment(-0.25, adjustment: .exposure)
        try await waitUntil("drawing guard baseline preview completes") { !model.busy }
        let raw = model.image!, before = values(model), name = model.imageName
        let storedPath = preferences.string(forKey: "lastImagePath")
        let count = visits.snapshot.count
        model.running = true
        for adjustment in ImageAdjustment.allCases {
            require(!model.setImageAdjustment(adjustment.range.upperBound, adjustment: adjustment),
                    "drawing rejects every adjustment")
        }
        model.editImageAdjustments(true); model.resetImageAdjustments()
        model.load(second); model.loadDemo()
        require(values(model) == before && model.image === raw && model.imageName == name
                && preferences.string(forKey: "lastImagePath") == storedPath,
                "drawing retains imported image, settings and persistence")
        try await Task.sleep(nanoseconds: 260_000_000)
        require(visits.snapshot.count == count && model.plans.count == 4 && !model.busy,
                "rejected edits cannot clear previews or start processing")
        model.running = false
        require(model.setImageAdjustment(-0.5, adjustment: .exposure), "adjustment resumes after drawing stops")
        try await waitUntil("post-drawing adjustment processes without stuck editing state") { !model.busy }
        require(visits.snapshot.count == count + 4, "rejected drag did not leave the model in edit mode")
        print("PASS active drawing rejects imports and tone edits without disturbing previews")
    }
}
