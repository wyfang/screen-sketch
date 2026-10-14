import Foundation
import CoreGraphics
import ImageIO

/// Worker-only gates exercise the real scheduler without windows or input events.
private final class PreviewGate {
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
        while !released {
            precondition(condition.wait(until: deadline), "worker gate timed out")
        }
    }
    func open() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private struct PreviewVisit {
    let imageWidth: Int
    let mode: DrawingMode
}

private final class PreviewVisits {
    private let lock = NSLock()
    private var entries: [PreviewVisit] = []
    func record(_ image: CGImage, _ mode: DrawingMode) {
        lock.lock(); entries.append(PreviewVisit(imageWidth: image.width, mode: mode)); lock.unlock()
    }
    var snapshot: [PreviewVisit] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
}

private enum PreviewFixtureError: LocalizedError {
    case intentional
    var errorDescription: String? { "intentional per-mode failure" }
}

private func previewFixture(width: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: 24, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: Double(width) / 100, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
    return context.makeImage()!
}

private func fixturePlan(_ image: CGImage, _ mode: DrawingMode,
                         _ settings: ProcessingSettings) -> DrawingPlan {
    DrawingPlan(mode: mode, strokes: [Stroke(points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])],
                preview: image, size: settings.canvasSize ?? CGSize(width: image.width, height: image.height),
                lineWidth: settings.lineWidth, minimumMovement: settings.minimumMovement,
                sampleSize: CGSize(width: image.width, height: image.height))
}

@main @MainActor struct PreviewGenerationChecks {
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static func waitUntil(_ message: String, timeout: TimeInterval = 3,
                          _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        require(predicate(), message)
    }

    static func model() -> (AppModel, UserDefaults, String) {
        let suite = "com.wangyifang.screensketch.previewchecks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        return (AppModel(preferences: preferences, showsApplicationUI: false), preferences, suite)
    }

    static func stop(_ model: AppModel, _ preferences: UserDefaults, _ suite: String) {
        model.image = nil; model.scheduleProcessing()
        preferences.removePersistentDomain(forName: suite)
    }

    static func main() async throws {
        setbuf(stdout, nil)
        try await partialPublicationAndPriority()
        try await failureIsolation()
        try await replacementCancelsOldModes()
        try await rapidImportsDebounce()
        try await importedImagePublishesEarly()
        print("PreviewGenerationChecks passed: priority, partial publication, failure isolation, cancellation, debounce, imported image")
    }

    static func partialPublicationAndPriority() async throws {
        let (model, preferences, suite) = model()
        let gate = PreviewGate(), visits = PreviewVisits()
        defer { gate.open(); stop(model, preferences, suite) }
        model.selectedMode = .sketch
        model.testPlanBuilder = { image, mode, settings in
            visits.record(image, mode)
            if mode == .outline { gate.wait() }
            return fixturePlan(image, mode, settings)
        }
        model.plans[.sketch] = fixturePlan(previewFixture(width: 20), .sketch, ProcessingSettings())
        model.image = previewFixture(width: 21); model.scheduleProcessing()
        require(model.plans.isEmpty && model.busy && model.pendingPreviewModes.count == 4,
                "new generation clears previews and marks every mode pending immediately")
        try await waitUntil("selected preview publishes while second mode remains blocked") {
            gate.hasEntered && model.selectedPlan != nil && model.processingMode == .outline
        }
        require(visits.snapshot.map(\.mode) == [.sketch, .outline], "selected mode runs first")
        require(model.plans.count == 1 && model.busy && !model.pendingPreviewModes.contains(.sketch)
                && model.pendingPreviewModes.contains(.solid), "available selected preview does not wait for all modes")
        gate.open()
        try await waitUntil("all independent successes publish") { !model.busy }
        require(model.plans.count == 4 && model.previewErrors.isEmpty && model.processingMode == nil,
                "completed request has no pending modes or processing indicator")
        print("PASS selected mode first; available before blocked mode finishes")
    }

    static func failureIsolation() async throws {
        let (model, preferences, suite) = model()
        defer { stop(model, preferences, suite) }
        model.selectedMode = .outline
        model.testPlanBuilder = { image, mode, settings in
            if mode == .halftone { throw PreviewFixtureError.intentional }
            return fixturePlan(image, mode, settings)
        }
        model.image = previewFixture(width: 22); model.scheduleProcessing()
        try await waitUntil("request with one failed mode completes") { !model.busy }
        require(Set(model.plans.keys) == [.outline, .sketch, .solid]
                && Set(model.previewErrors.keys) == [.halftone]
                && model.previewErrors[.halftone] == "intentional per-mode failure"
                && model.pendingPreviewModes.isEmpty && model.selectedPlan != nil,
                "one mode failure preserves and publishes all other previews")
        print("PASS one failed mode preserves three successful previews")
    }

    static func replacementCancelsOldModes() async throws {
        let (model, preferences, suite) = model()
        let gate = PreviewGate(), visits = PreviewVisits()
        defer { gate.open(); stop(model, preferences, suite) }
        model.selectedMode = .outline
        model.testPlanBuilder = { image, mode, settings in
            visits.record(image, mode)
            if image.width == 31 { gate.wait() }
            return fixturePlan(image, mode, settings)
        }
        model.image = previewFixture(width: 31); model.scheduleProcessing()
        try await waitUntil("old image has entered its first processor") { gate.hasEntered }
        model.image = previewFixture(width: 32); model.scheduleProcessing()
        require(model.plans.isEmpty && model.previewErrors.isEmpty && model.pendingPreviewModes.count == 4,
                "replacement cannot display old image previews")
        try await waitUntil("new image completes without waiting for obsolete worker") { !model.busy }
        require(model.plans.values.allSatisfy { $0.sampleSize.width == 32 }, "every new preview belongs to new image")
        gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        require(visits.snapshot.filter { $0.imageWidth == 31 }.map(\.mode) == [.outline],
                "cancelled worker skips remaining old modes")
        require(model.plans.count == 4 && model.plans.values.allSatisfy { $0.sampleSize.width == 32 }
                && model.previewErrors.isEmpty && !model.busy, "late old result cannot overwrite new image")
        print("PASS replacement rejects stale result and skips remaining obsolete modes")
    }

    static func rapidImportsDebounce() async throws {
        let (model, preferences, suite) = model()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screensketch-preview-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { stop(model, preferences, suite); try? FileManager.default.removeItem(at: directory) }
        let visits = PreviewVisits()
        model.selectedMode = .solid
        model.testPlanBuilder = { image, mode, settings in
            visits.record(image, mode); return fixturePlan(image, mode, settings)
        }
        for width in [41, 42, 43] {
            let url = directory.appendingPathComponent("image-\(width).png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, previewFixture(width: width), nil)
            require(CGImageDestinationFinalize(destination), "PNG fixture writes")
            model.load(url)
            require(model.plans.isEmpty && model.busy, "each import clears old previews synchronously")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await waitUntil("last rapid import completes") { !model.busy }
        require(visits.snapshot.count == 4 && visits.snapshot.allSatisfy { $0.imageWidth == 43 }
                && visits.snapshot.first?.mode == .solid, "debounce only processes newest imported image with selected mode first")
        require(model.imageName == "image-43.png" && model.plans.values.allSatisfy { $0.sampleSize.width == 43 }
                && preferences.string(forKey: "lastImagePath") == directory.appendingPathComponent("image-43.png").path,
                "newest file name, image and preferences stay consistent")
        print("PASS three rapid imports process only final file")
    }

    static func importedImagePublishesEarly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screensketch-preview-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url: URL
        if let path = ProcessInfo.processInfo.environment["SCREEN_SKETCH_TEST_IMAGE"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = directory.appendingPathComponent("demo.png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, DemoImage.make(), nil)
            require(CGImageDestinationFinalize(destination), "demo PNG fixture writes")
        }
        let (model, preferences, suite) = model()
        let gate = PreviewGate()
        defer { gate.open(); stop(model, preferences, suite) }
        model.selectedMode = .outline
        _ = model.setBrushWidth(1); _ = model.setMinimumMovement(8)
        _ = model.setMinimumSpacing(2.25, axis: .x); _ = model.setMinimumSpacing(2.25, axis: .y)
        model.testPlanBuilder = { image, mode, settings in
            // Geometry/performance suites cover fill planning. This controlled
            // slow fourth mode makes publication assertions deterministic.
            if mode == .solid { gate.wait(); return fixturePlan(image, mode, settings) }
            return try ImageProcessor.makePlan(image: image, mode: mode, settings: settings)
        }
        let started = ProcessInfo.processInfo.systemUptime
        model.load(url)
        require(model.error == nil && model.plans.isEmpty && model.imageName == url.lastPathComponent,
                "imported image loads and old previews are cleared")
        try await waitUntil("real image outline publishes while other previews are pending", timeout: 20) {
            model.selectedPlan != nil
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        require(model.selectedPlan!.mode == .outline && !model.selectedPlan!.strokes.isEmpty
                && model.busy && model.pendingPreviewModes.contains(.solid),
                "real outline preview is useful before slow solid mode completes")
        try await waitUntil("real image reaches held solid mode", timeout: 20) {
            gate.hasEntered && model.processingMode == .solid
        }
        require(model.plans.count == 3 && model.processingMode == .solid && model.busy,
                "three real image previews remain usable during slow fill processing")
        gate.open()
        try await waitUntil("released fill mode finishes scheduler") { !model.busy }
        require(model.plans.count == 4 && model.previewErrors.isEmpty, "real image generation finishes without stale plans")
        print(String(format: "PASS imported image: real outline appears in %.3fs before held fill mode", elapsed))
    }
}
