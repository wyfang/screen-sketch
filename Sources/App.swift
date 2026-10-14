import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApplicationServices

// DispatchWorkItem cancellation cannot stop a closure that is already running.
// A synchronized request flag also lets it abandon remaining modes after a
// newer image or calibration has superseded it.
private final class PreviewProcessingRequest {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum ImageAdjustment: CaseIterable {
    case exposure, contrast, shadows, fillThreshold
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -2...2
        case .contrast: return 0.5...1.8
        case .shadows: return 0...1
        case .fillThreshold: return -64...64
        }
    }
    var title: String {
        switch self {
        case .exposure: return "曝光"
        case .contrast: return "对比度"
        case .shadows: return "阴影提亮"
        case .fillThreshold: return "填充黑白阈值"
        }
    }
}

@MainActor final class AppModel: NSObject, ObservableObject {
    @Published var image: CGImage?
    @Published var imageName = "内置演示图"
    @Published var plans: [DrawingMode: DrawingPlan] = [:]
    @Published var selectedMode = DrawingMode.allCases[1]
    @Published private(set) var imageExposure = 0.0
    @Published private(set) var imageContrast = 1.0
    @Published private(set) var imageShadowLift = 0.0
    @Published private(set) var imageFillThreshold = 0.0
    private var editingImageAdjustments = false
    @Published private(set) var brushWidth = 2.5
    @Published var speed = 450.0 { didSet { engine.speed = speed; preferences.set(speed, forKey: "drawingSpeed") } }
    @Published private(set) var minimumMovement = 3.0
    @Published private(set) var minimumSpacingX: Double?
    @Published private(set) var minimumSpacingY: Double?
    @Published private(set) var pressDelay = 0.12
    @Published private(set) var releaseDelay = 0.12
    @Published private(set) var endExtension = 0.0
    @Published var unifiedNote = "尚未联合校准"
    @Published var spacingNote = "横向、纵向尚未校准；暂按笔宽估算"
    @Published var calibrationNote = "尚未校准，建议先测试"
    @Published var region: CGRect?
    @Published var transport: DrawingTransport = .foreground
    @Published var targetPID: pid_t?
    @Published var targetName = "尚未选择"
    @Published var busy = false
    @Published private(set) var pendingPreviewModes = Set<DrawingMode>()
    @Published private(set) var previewErrors: [DrawingMode: String] = [:]
    @Published private(set) var processingMode: DrawingMode?
    @Published var running = false
    @Published var paused = false
    @Published var progress = 0.0
    @Published var status = "导入图片，或用演示图比较四种效果"
    @Published var error: String?
    @Published var overlayVisible = false
    @Published var backgroundConfirmed = false
    @Published var showBackgroundCheck = false
    @Published var inputGuardNote = ""
    @Published var autoMinimizeOnRun = true {
        didSet { preferences.set(autoMinimizeOnRun, forKey: "autoMinimizeOnRun") }
    }
    @Published private(set) var penButton: CGPoint?
    @Published private(set) var eraserButton: CGPoint?
    @Published private(set) var toolTargetIdentity: String?
    @Published private(set) var toolTargetName = "尚未定位"
    @Published var autoClearCalibration = true {
        didSet {
            preferences.set(autoClearCalibration, forKey: "autoClearCalibration")
            calibration.automaticCleanup = autoClearCalibration
            spacingCalibration.automaticCleanup = autoClearCalibration
            unifiedCalibration.automaticCleanup = autoClearCalibration
        }
    }
    let engine = DrawingEngine()
    let picker = ScreenRegionPicker()
    let overlay = CanvasPreviewOverlay()
    let calibration = MovementCalibration()
    let spacingCalibration = SpacingCalibration()
    let unifiedCalibration = UnifiedCalibration()
    let pointPicker = ScreenPointPicker()
    let calibrationAutomation = CalibrationAutomation()
    weak var mainWindow: NSWindow?
    private var generation = 0
    private var originalImageURL: URL?
    private var pending: DispatchWorkItem?
    private var previewRequest: PreviewProcessingRequest?
    #if ENGINE_TESTS
    // Deterministic processing delays/failures exercise the real publication
    // pipeline without posting input or depending on image complexity timing.
    var testPlanBuilder: ((CGImage, DrawingMode, ProcessingSettings) throws -> DrawingPlan)?
    #endif
    private var lastUpdate = 0.0
    private var wasProbe = false
    private var statusItem: NSStatusItem?
    private var pausePanel: NSPanel?
    private var calibrationWindow: NSWindow?
    private var calibrationPID: pid_t?
    private var calibrationTargetName = "当前画板"
    private var calibrationRunning = false
    private var spacingWindow: NSWindow?
    private var spacingPID: pid_t?
    private var spacingTargetName = "当前画板"
    private var spacingRunning = false
    private var spacingBrush: Double?
    private var spacingSpeed: Double?
    private var spacingMovement: Double?
    private var calibrationBrush: Double?
    private var calibrationSpeed: Double?
    private var toolSettingsWindow: NSWindow?
    private var toolTest: ToolButtonKind?
    private var toolTestPID: pid_t?
    private var cleanupOnly = false
    private var cleanupShowsSpacing = false
    private var cleanupShowsUnified = false
    private var unifiedWindow: NSWindow?
    private var unifiedPID: pid_t?
    private var unifiedTargetName = "当前画板"
    private var unifiedRunning = false
    private var unifiedSnapshot: [Double]?
    private let preferences: UserDefaults
    private let showsApplicationUI: Bool

    override convenience init() {
        self.init(preferences: .standard, showsApplicationUI: true)
    }
    init(preferences: UserDefaults, showsApplicationUI: Bool) {
        self.preferences = preferences
        self.showsApplicationUI = showsApplicationUI
        super.init()
        if let value = preferences.object(forKey: "pressDelay") as? Double { _ = setStrokeDelay(value, press: true) }
        if let value = preferences.object(forKey: "releaseDelay") as? Double { _ = setStrokeDelay(value, press: false) }
        if let value = preferences.object(forKey: "endExtension") as? Double { _ = setEndExtension(value) }
        if let note = preferences.string(forKey: "unifiedNote") { unifiedNote = note }
        if let saved = preferences.object(forKey: "autoClearCalibration") as? Bool { autoClearCalibration = saved }
        if let saved = preferences.object(forKey: "autoMinimizeOnRun") as? Bool { autoMinimizeOnRun = saved }
        toolTargetIdentity = preferences.string(forKey: "toolTargetIdentity")
        toolTargetName = preferences.string(forKey: "toolTargetName") ?? "尚未定位"
        penButton = restoredToolPoint("penButton")
        eraserButton = restoredToolPoint("eraserButton")
        calibration.automaticCleanup = autoClearCalibration
        spacingCalibration.automaticCleanup = autoClearCalibration
        unifiedCalibration.automaticCleanup = autoClearCalibration
        if let saved = preferences.object(forKey: "brushWidth") as? Double { _ = setBrushWidth(saved) }
        if let saved = preferences.object(forKey: "drawingSpeed") as? Double, saved.isFinite, saved > 0 { speed = saved }
        if let saved = preferences.object(forKey: "minimumMovement") as? Double { _ = setMinimumMovement(saved) }
        if let note = preferences.string(forKey: "calibrationNote") { calibrationNote = note }
        let savedSpacingNote = preferences.string(forKey: "spacingNote")
        if let saved = preferences.object(forKey: "minimumSpacingX") as? Double { _ = setMinimumSpacing(saved, axis: .x) }
        if let saved = preferences.object(forKey: "minimumSpacingY") as? Double { _ = setMinimumSpacing(saved, axis: .y) }
        if let note = savedSpacingNote { spacingNote = note; preferences.set(note, forKey: "spacingNote") }
        engine.speed = speed; engine.minimumMovement = minimumMovement
        engine.pressDelay = pressDelay; engine.releaseDelay = releaseDelay
        engine.onUpdate = { [weak self] value, label in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastUpdate > 0.09 || label.contains("暂停") || !self.engine.running {
                self.progress = value; self.status = label; self.paused = self.engine.paused
                self.lastUpdate = now
            }
        }
        engine.onFinish = { [weak self] complete in
            guard let self else { return }
            self.running = false; self.paused = false
            self.calibrationAutomation.finish(completed: complete)
            self.inputGuardNote = ""
            self.pausePanel?.orderOut(nil)
            self.engine.minimumMovement = self.minimumMovement
            self.statusItem?.menu = self.makeStatusMenu()
            if let tool = self.toolTest {
                self.toolTest = nil; self.toolTestPID = nil
                let name = tool == .pen ? "画笔" : "橡皮擦"
                self.status = complete ? "已发送 3 次\(name)按钮点击，请检查目标软件是否选中；未绘制或擦除画布。" : "工具切换测试已停止，请检查当前选中的工具。"
                self.toolSettingsWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if self.cleanupOnly {
                self.cleanupOnly = false
                if complete {
                    if self.cleanupShowsUnified { _ = self.unifiedCalibration.repeatRound() }
                    else if self.cleanupShowsSpacing, !self.spacingCalibration.finished { _ = self.spacingCalibration.repeatRound() }
                    else if !self.cleanupShowsSpacing, !self.calibration.finished { _ = self.calibration.repeatRound() }
                }
                self.status = complete ? "已沿原路径擦除测试笔迹，并切回画笔" : "清理已停止；再次清理会重放完整记录，当前工具可能仍是橡皮"
                if self.cleanupShowsUnified { self.unifiedWindow?.makeKeyAndOrderFront(nil) }
                else if self.cleanupShowsSpacing { self.spacingWindow?.makeKeyAndOrderFront(nil) }
                else { self.calibrationWindow?.makeKeyAndOrderFront(nil) }
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if self.unifiedRunning {
                self.unifiedRunning = false
                if complete { _ = self.unifiedCalibration.markDrawn(); self.status = "四项测试已完成，请分别选择三个组号中的合格组" }
                else { self.status = "联合测试已停止；重画会先清理已记录的测试路径" }
                self.unifiedWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if self.spacingRunning {
                self.spacingRunning = false
                if complete { _ = self.spacingCalibration.markDrawn(); self.status = "本轮间距测试已完成，请检查每组三对笔画" }
                else { self.status = "间距测试已停止；下一次绘制会自动清理记录的笔迹，当前工具可能仍是橡皮" }
                self.spacingWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if self.calibrationRunning {
                self.calibrationRunning = false
                if complete { _ = self.calibration.markDrawn(); self.status = "本轮测试已完成，请检查每一行的三条短线" }
                else { self.status = "校准绘制已停止；下一次绘制会自动清理记录的笔迹，当前工具可能仍是橡皮" }
                self.calibrationWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if self.transport == .foreground || self.wasProbe {
                self.mainWindow?.deminiaturize(nil)
                self.mainWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if self.transport == .background, complete {
                self.status = self.wasProbe ? "测试笔画已发送，请检查目标画板" : "笔画已发送完成，请检查目标画板"
            }
            if self.wasProbe, complete, self.transport == .background { self.showBackgroundCheck = true }
            self.wasProbe = false
        }
        engine.onPause = { [weak self] _ in self?.paused = true; self?.showPausePanel() }
        if showsApplicationUI {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "屏幕绘图器")
            statusItem?.menu = makeStatusMenu()
        }
        if let lastPath = preferences.string(forKey: "lastImagePath"), FileManager.default.fileExists(atPath: lastPath) { load(URL(fileURLWithPath: lastPath)) }
        else { loadDemo() }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "显示屏幕绘图器", action: #selector(showMain), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let pause = NSMenuItem(title: "暂停 / 继续", action: #selector(pauseDrawing), keyEquivalent: "")
        pause.target = self; pause.isEnabled = running; menu.addItem(pause)
        let stop = NSMenuItem(title: "停止绘制", action: #selector(stopDrawing), keyEquivalent: "")
        stop.target = self; stop.isEnabled = running; menu.addItem(stop)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        menu.autoenablesItems = false
        return menu
    }
    @objc func showMain() {
        guard showsApplicationUI else { return }
        if engine.running, !engine.paused, transport == .foreground || isCalibrating { engine.togglePause(); paused = true }
        mainWindow?.deminiaturize(nil); mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func pauseDrawing() {
        if engine.paused, transport == .foreground || isCalibrating {
            pausePanel?.orderOut(nil)
            prepareWindowsForRun()
            let pid = toolTestPID ?? ((unifiedRunning || (cleanupOnly && cleanupShowsUnified)) ? unifiedPID : ((spacingRunning || (cleanupOnly && cleanupShowsSpacing)) ? spacingPID : ((calibrationRunning || cleanupOnly) ? calibrationPID : targetPID)))
            if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.engine.resume(countdown: 1); self?.paused = self?.engine.paused ?? false
                if self?.engine.paused == true { self?.showPausePanel() }
            }
        } else if engine.paused { pausePanel?.orderOut(nil); engine.resume(countdown: 1); paused = engine.paused }
        else { engine.pause(reason: "已手动暂停"); paused = engine.paused }
    }
    @objc func stopDrawing() { engine.stop() }
    @objc func quit() { engine.stop(); NSApp.terminate(nil) }

    /// 绘制、校准、清理及继续操作共用窗口策略；关闭时保持窗口可见。
    private func prepareWindowsForRun() {
        guard autoMinimizeOnRun else { return }
        calibrationWindow?.orderOut(nil); spacingWindow?.orderOut(nil)
        unifiedWindow?.orderOut(nil); toolSettingsWindow?.orderOut(nil)
        mainWindow?.miniaturize(nil)
    }

    var selectedPlan: DrawingPlan? { plans[selectedMode] }
    var isCalibrating: Bool { calibrationRunning || spacingRunning || unifiedRunning || cleanupOnly || toolTest != nil }
    var unifiedVisible: Bool { unifiedWindow?.isVisible == true }
    var speedText: String { UnifiedCalibration.format(speed) }
    var aspect: Double {
        if let region { return region.width / region.height }
        if let image { return Double(image.width) / Double(image.height) }
        return 1
    }
    var targetRect: CGRect { region ?? CGRect(x: 0, y: 0, width: 640, height: 640 / aspect) }
    var canvasMetrics: CanvasMetrics? { region.flatMap { CanvasMetrics.current(for: $0) } }
    var previewScale: Double { canvasMetrics.map { Double($0.backingScale) } ?? 1 }
    var effectiveSpacingX: Double { max(minimumSpacingX ?? brushWidth * 1.25, brushWidth) }
    var effectiveSpacingY: Double { max(minimumSpacingY ?? brushWidth * 1.25, brushWidth) }
    func paths(_ plan: DrawingPlan) -> [[CGPoint]] {
        plan.strokes.map { $0.points.map { CGPoint(x: $0.x / plan.size.width, y: $0.y / plan.size.height) } }
    }
    var estimate: String {
        guard let plan = selectedPlan else { return "—" }
        let time = DrawingEngine.estimateSeconds(paths: paths(plan), rect: targetRect, brushWidth: brushWidth, speed: speed, minimumMovement: minimumMovement, pressDelay: pressDelay, releaseDelay: releaseDelay, endExtension: endExtension)
        guard time.isFinite, time < Double(Int.max - 1) else { return "耗时过长，请提高移动速度" }
        if time < 60 { return "约 \(Int(ceil(time))) 秒" }
        return "约 \(Int(ceil(time / 60))) 分钟"
    }
    var regionText: String {
        guard let region else { return "尚未框选画布" }
        let points = "\(MovementCalibration.format(region.width)) × \(MovementCalibration.format(region.height)) 屏幕点"
        if let metrics = canvasMetrics {
            return "\(points)\n\(Int(metrics.pixelSize.width)) × \(Int(metrics.pixelSize.height)) 像素 · 显示比例 \(MovementCalibration.format(metrics.backingScale))×\n\(metrics.displayName)"
        }
        return points + " · 显示器信息不可用，请重新选区"
    }
    var precisionText: String {
        guard let plan = selectedPlan else { return "根据画布与校准结果自动计算" }
        if plan.mode == .halftone {
            return "图像采样 \(Int(plan.sampleSize.width)) × \(Int(plan.sampleSize.height))\n笔宽 \(MovementCalibration.format(plan.lineWidth)) · 最短拖动 \(MovementCalibration.format(plan.minimumMovement)) 点\n每个墨点一笔，深色可连接成长线；最短拖动不等于图像像素大小\n采样步长 X/Y：\(MovementCalibration.format(plan.effectiveSpacingX)) / \(MovementCalibration.format(plan.effectiveSpacingY)) 点"
        }
        if plan.mode == .solid {
            return "黑色区域采样 \(Int(plan.sampleSize.width)) × \(Int(plan.sampleSize.height))\n笔宽 \(MovementCalibration.format(plan.lineWidth)) · 最短拖动 \(MovementCalibration.format(plan.minimumMovement)) 点\n按黑色区域逐层向内填充 · 按实际笔宽重叠 · 保留白孔"
        }
        return "提线采样 \(Int(plan.sampleSize.width)) × \(Int(plan.sampleSize.height))\n笔宽 \(MovementCalibration.format(plan.lineWidth)) · 最小位移 \(MovementCalibration.format(plan.minimumMovement)) 点"
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        // A drop's URL provider may complete after the user starts drawing.
        // Keep the image and preview aligned with that active drawing plan.
        guard !running else { return }
        do {
            let loaded = try ImageProcessor.loadImage(url: url)
            if originalImageURL?.standardizedFileURL != url.standardizedFileURL {
                restoreImageAdjustments(for: url)
            }
            editingImageAdjustments = false
            image = loaded
            originalImageURL = url
            imageName = url.lastPathComponent
            preferences.set(url.path, forKey: "lastImagePath")
            error = nil; backgroundConfirmed = false; scheduleProcessing()
        } catch { self.error = "图片读取失败：\(error.localizedDescription)" }
    }
    func loadDemo() {
        guard !running else { return }
        originalImageURL = nil; setNeutralImageAdjustments()
        editingImageAdjustments = false
        image = DemoImage.make(); imageName = "内置演示图"; scheduleProcessing()
    }

    var imageAdjustmentsAreNeutral: Bool {
        imageExposure == 0 && imageContrast == 1 && imageShadowLift == 0 && imageFillThreshold == 0
    }
    func imageAdjustmentValue(_ adjustment: ImageAdjustment) -> Double {
        switch adjustment {
        case .exposure: return imageExposure
        case .contrast: return imageContrast
        case .shadows: return imageShadowLift
        case .fillThreshold: return imageFillThreshold
        }
    }
    @discardableResult func setImageAdjustment(_ value: Double, adjustment: ImageAdjustment) -> Bool {
        guard !running, value.isFinite else { return false }
        let value = min(adjustment.range.upperBound, max(adjustment.range.lowerBound, value))
        guard imageAdjustmentValue(adjustment) != value else { return true }
        switch adjustment {
        case .exposure: imageExposure = value
        case .contrast: imageContrast = value
        case .shadows: imageShadowLift = value
        case .fillThreshold: imageFillThreshold = value
        }
        saveImageAdjustments()
        if !editingImageAdjustments { scheduleProcessing() }
        return true
    }
    func editImageAdjustments(_ editing: Bool) {
        guard !running, editingImageAdjustments != editing else { return }
        editingImageAdjustments = editing
        if editing {
            // Fill planning can be costly. Invalidate the old paths immediately,
            // then start one new request with the final values on mouse release.
            hideOverlay(); pending?.cancel(); previewRequest?.cancel(); generation += 1
            plans = [:]; previewErrors = [:]; processingMode = nil
            pendingPreviewModes = Set(DrawingMode.allCases); busy = true
            status = "正在调整图片，松开拉杆后更新预览"
        } else { scheduleProcessing() }
    }
    func resetImageAdjustments() {
        guard !running else { return }
        setNeutralImageAdjustments(); saveImageAdjustments(); scheduleProcessing()
    }
    private func setNeutralImageAdjustments() {
        imageExposure = 0; imageContrast = 1; imageShadowLift = 0; imageFillThreshold = 0
    }
    private func saveImageAdjustments() {
        guard let originalImageURL else { return }
        preferences.set(originalImageURL.standardizedFileURL.path, forKey: "imageAdjustmentPath")
        preferences.set(imageExposure, forKey: "imageExposure")
        preferences.set(imageContrast, forKey: "imageContrast")
        preferences.set(imageShadowLift, forKey: "imageShadowLift")
        preferences.set(imageFillThreshold, forKey: "imageFillThreshold")
    }
    private func restoreImageAdjustments(for url: URL) {
        setNeutralImageAdjustments()
        guard preferences.string(forKey: "imageAdjustmentPath") == url.standardizedFileURL.path else { return }
        func restored(_ key: String, adjustment: ImageAdjustment, fallback: Double) -> Double {
            guard let value = preferences.object(forKey: key) as? Double, value.isFinite else { return fallback }
            return min(adjustment.range.upperBound, max(adjustment.range.lowerBound, value))
        }
        imageExposure = restored("imageExposure", adjustment: .exposure, fallback: 0)
        imageContrast = restored("imageContrast", adjustment: .contrast, fallback: 1)
        imageShadowLift = restored("imageShadowLift", adjustment: .shadows, fallback: 0)
        imageFillThreshold = restored("imageFillThreshold", adjustment: .fillThreshold, fallback: 0)
    }

    func scheduleProcessing() {
        hideOverlay()
        pending?.cancel(); previewRequest?.cancel(); generation += 1
        plans = [:]; previewErrors = [:]; pendingPreviewModes = []; processingMode = nil
        guard let image else { busy = false; return }
        if region != nil, canvasMetrics == nil {
            busy = false; plans = [:]; error = "画布已不在同一块有效显示器内，请重新框选。"
            return
        }
        busy = true
        let modes = [selectedMode] + DrawingMode.allCases.filter { $0 != selectedMode }
        pendingPreviewModes = Set(modes)
        status = "正在为“\(imageName)”生成\(selectedMode.title)预览…"
        let stamp = generation
        let request = PreviewProcessingRequest()
        previewRequest = request
        let settings = ProcessingSettings(lineWidth: brushWidth, canvasAspect: aspect,
                                          minimumMovement: minimumMovement, canvasSize: targetRect.size,
                                          backingScale: previewScale, minimumSpacingX: effectiveSpacingX,
                                          minimumSpacingY: effectiveSpacingY, endExtension: endExtension,
                                          exposure: imageExposure, contrast: imageContrast,
                                          shadowLift: imageShadowLift, inkThresholdOffset: imageFillThreshold)
        let sourceURL = originalImageURL
        let decodeBudget = Int(min(8192, max(1, ceil(max(targetRect.width, targetRect.height) * previewScale))))
        #if ENGINE_TESTS
        let builder = testPlanBuilder ?? ImageProcessor.makePlan
        #else
        let builder = ImageProcessor.makePlan
        #endif
        let work = DispatchWorkItem { [weak self] in
            guard !request.isCancelled else { return }
            let processingImage: CGImage
            do {
                processingImage = try sourceURL.map { try ImageProcessor.loadImage(url: $0, maxPixelSize: decodeBudget) } ?? image
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == stamp else { return }
                    self.pendingPreviewModes = []; self.processingMode = nil; self.busy = false
                    self.previewErrors = Dictionary(uniqueKeysWithValues: modes.map { ($0, error.localizedDescription) })
                    if !self.running { self.status = "图片读取失败，请重新选择图片" }
                }
                return
            }
            for mode in modes {
                guard !request.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == stamp else { return }
                    self.processingMode = mode
                    if !self.running { self.status = "正在生成\(mode.title) · 已完成 \(self.plans.count + self.previewErrors.count) / \(modes.count) 种效果" }
                }
                let result = Result { try builder(processingImage, mode, settings) }
                guard !request.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.publishPreview(result, for: mode, generation: stamp)
                }
            }
        }
        pending = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func publishPreview(_ result: Result<DrawingPlan, Error>, for mode: DrawingMode, generation stamp: Int) {
        guard generation == stamp else { return }
        switch result {
        case .success(let plan): plans[mode] = plan
        case .failure(let error): previewErrors[mode] = error.localizedDescription
        }
        pendingPreviewModes.remove(mode)
        busy = !pendingPreviewModes.isEmpty
        if !busy {
            processingMode = nil
            if !running {
                status = previewErrors.isEmpty
                    ? (region == nil ? "示意预览：请先选定实际画布，以计算真实绘制精度" : "预览已按实际画布、笔宽与可执行笔迹更新")
                    : "已生成 \(plans.count) / \(DrawingMode.allCases.count) 种效果；未完成模式可重试"
            }
        }
    }

    func selectRegion(_ mode: ScreenRegionPicker.SelectionMode) {
        hideOverlay(); mainWindow?.orderOut(nil)
        picker.begin(mode: mode) { [weak self] rect in
            guard let self else { return }
            if let rect {
                self.region = rect; self.backgroundConfirmed = false
                self.findTarget(rect)
                self.syncUnifiedCanvas()
                self.scheduleProcessing()
            }
            self.showMain()
        }
    }
    private func findTarget(_ rect: CGRect) {
        let target = targetAt(rect)
        targetPID = target?.0; targetName = target?.1 ?? "尚未选择"
    }
    private func targetAt(_ rect: CGRect) -> (pid_t, String)? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(center) else { continue }
            return (pid_t(pid), NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "进程 \(pid)")
        }
        return nil
    }
    var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    func setTarget(_ pid: pid_t) {
        targetPID = pid; targetName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "进程 \(pid)"
        backgroundConfirmed = false
        syncUnifiedCanvas()
    }
    func toggleOverlay() {
        guard let region, let plan = selectedPlan else { return }
        if overlayVisible { hideOverlay() }
        else { overlay.show(image: plan.preview, region: region, opacity: 0.48); overlayVisible = true }
    }
    func hideOverlay() { overlay.hide(); overlayVisible = false }
    enum ToolButtonKind { case pen, eraser }
    private func restoredToolPoint(_ key: String) -> CGPoint? {
        guard let values = preferences.array(forKey: key) as? [Double], values.count == 2,
              values.allSatisfy({ $0.isFinite }) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
    private func targetIdentity(_ pid: pid_t) -> String? {
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.bundleIdentifier ?? app?.executableURL?.path
    }
    var toolLocationsReady: Bool { penButton != nil && eraserButton != nil && toolTargetIdentity != nil }
    var automaticCleanupText: String {
        if !autoClearCalibration { return "自动清理已关闭，下轮前需手动清除测试笔迹" }
        return toolLocationsReady ? "下轮前沿记录的笔画擦除，再切回画笔" : "先指定画笔与橡皮按钮"
    }
    func toolPointText(_ point: CGPoint?) -> String {
        point.map { "(\(MovementCalibration.format($0.x)), \(MovementCalibration.format($0.y)))" } ?? "尚未指定"
    }
    @discardableResult
    func setStrokeDelay(_ value: Double, press: Bool) -> Bool {
        guard !running, value.isFinite, value >= 0, value <= 5 else { return false }
        if press {
            if pressDelay != value { pressDelay = value }
            engine.pressDelay = value; preferences.set(value, forKey: "pressDelay")
        } else {
            if releaseDelay != value { releaseDelay = value }
            engine.releaseDelay = value; preferences.set(value, forKey: "releaseDelay")
        }
        return true
    }
    @discardableResult
    func setEndExtension(_ value: Double) -> Bool {
        guard !running, value.isFinite, value >= 0, value <= 10_000 else { return false }
        if endExtension != value { endExtension = value }
        preferences.set(value, forKey: "endExtension")
        scheduleProcessing()
        return true
    }
    private var currentUnifiedSettings: [Double] { [brushWidth, pressDelay, releaseDelay, minimumMovement, endExtension] }
    /// 联合校准直接使用主界面的画布与目标；不维护另一个需要重复设置的选区。
    func syncUnifiedCanvas() {
        guard !running else { return }
        if unifiedPID != targetPID {
            unifiedCalibration.retest()
            unifiedSnapshot = nil
        }
        if unifiedCalibration.area != region || unifiedPID != targetPID {
            _ = unifiedCalibration.setArea(region)
        }
        unifiedPID = targetPID
        unifiedTargetName = targetName
    }
    var unifiedCleanupText: String {
        if !autoClearCalibration { return "下轮请手动清除测试线，保留 M/#/V/E 标题" }
        return toolLocationsReady ? "沿用主界面工具位置；下轮只擦测试线，保留固定标记" : "沿用主画布；请先在主界面设置画笔与橡皮按钮"
    }
    func openUnifiedCalibration() {
        guard !running else { return }
        hideOverlay(); error = nil
        unifiedCalibration.automaticCleanup = autoClearCalibration
        syncUnifiedCanvas()
        if unifiedWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "画笔联合校准"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1000, height: 820)
            window.contentView = NSHostingView(rootView: UnifiedCalibrationHostView(model: self))
            window.center(); unifiedWindow = window
        }
        unifiedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func closeUnifiedCalibration() {
        if unifiedRunning || (cleanupOnly && cleanupShowsUnified) { engine.stop() }
        unifiedWindow?.orderOut(nil); error = nil
    }
    func chooseUnifiedArea() {
        guard !running else { return }
        unifiedWindow?.orderOut(nil)
        showMain()
        status = "在主界面框选空白画布并设置工具位置，再打开联合校准。"
    }
    func drawUnifiedRound() {
        syncUnifiedCanvas()
        guard !running, let area = unifiedCalibration.area, let pid = unifiedPID else {
            error = "请先在主界面选定目标画板的空白画布；联合校准会自动沿用。"; return
        }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        guard validateCalibrationTools(area: area, pid: pid) else { return }
        if let snapshot = unifiedSnapshot, snapshot != currentUnifiedSettings { unifiedCalibration.retest() }
        do {
            let round = try unifiedCalibration.makeRound(brushWidth: brushWidth,
                                                         knownMovement: minimumMovement, releaseDelay: releaseDelay)
            guard round.batches.allSatisfy({ fullCompensationFits($0.paths, area: area, extension: $0.endExtension) }) else {
                error = "本轮末端补偿空间不足，不能按显示的候选距离完整测试。请在主界面选择更大的空白画布。"
                return
            }
            func footprint(_ paths: [[CGPoint]]) -> CalibrationFootprint {
                let actual = DrawingEngine.mapPaths(paths, to: area, brushWidth: brushWidth).map { path in
                    path.map { CGPoint(x: ($0.x - area.minX) / area.width, y: ($0.y - area.minY) / area.height) }
                }
                return CalibrationFootprint(paths: actual, area: area, brushWidth: brushWidth, targetPID: pid)
            }
            let tests = footprint(round.actualTestPaths)
            let annotations = footprint(round.annotationPaths)
            if autoClearCalibration {
                _ = try CalibrationCleanup.replay(footprint: tests)
                _ = try CalibrationCleanup.replay(footprint: annotations)
            }
            func action(_ batch: UnifiedCalibrationBatch) -> DrawingAction {
                DrawingAction.profiledStrokes(paths: batch.paths, rect: area, brushWidth: brushWidth,
                    minimumMovement: batch.minimumMovement, speed: batch.speed,
                    pressDelay: pressDelay, releaseDelay: batch.releaseDelay ?? releaseDelay,
                    endExtension: batch.endExtension)
            }
            let operation = try calibrationAutomation.prepare(newFootprint: tests, area: area, targetPID: pid,
                penButton: penButton, eraserButton: eraserButton,
                autoClear: autoClearCalibration,
                drawingActions: round.batches.filter { !$0.isAnnotation }.map(action),
                persistentAnnotations: annotations,
                annotationActions: round.batches.filter { $0.isAnnotation }.map(action))
            engine.speed = min(300, speed); unifiedRunning = true; wasProbe = false
            if engine.start(actions: operation.actions, transport: .foreground, targetPID: pid) {
                beginCalibrationOperation(operation)
                unifiedSnapshot = currentUnifiedSettings
                running = true; paused = false; progress = 0; error = nil
                inputGuardNote = engine.hasImmediateInputGuard ? "" : "兼容监听：不能保证拦截第一下手动输入。"
                statusItem?.menu = makeStatusMenu()
                prepareWindowsForRun()
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            } else { unifiedRunning = false; error = "联合测试无法开始，请检查权限和画板位置。" }
        } catch { self.error = error.localizedDescription }
    }
    func confirmAndApplyUnifiedCalibration() {
        guard !running else { return }
        guard let result = unifiedCalibration.resultForApplication() else {
            error = unifiedCalibration.message; return
        }
        applyUnifiedCalibration(result)
    }
    func applyUnifiedCalibration(_ result: UnifiedCalibrationResult) {
        guard !running else { return }
        if let snapshot = unifiedSnapshot, snapshot != currentUnifiedSettings {
            error = "笔宽、位移或等待时间已改变，请重新测量后采用。"; return
        }
        guard [result.movement, result.spacingX, result.spacingY, result.speed].allSatisfy({ $0.isFinite && $0 > 0 }),
              result.movement <= 10_000, result.spacingX <= 10_000, result.spacingY <= 10_000,
              result.releaseDelay.isFinite, result.releaseDelay >= 0, result.releaseDelay <= 5,
              result.endExtension.isFinite, result.endExtension >= 0, result.endExtension <= 10_000 else {
            error = "联合校准结果无效，请重新测量。"; return
        }
        _ = setMinimumMovement(result.movement)
        unifiedCalibration.acknowledgeAppliedMovement(result.movement)
        _ = setMinimumSpacing(result.spacingX, axis: .x); _ = setMinimumSpacing(result.spacingY, axis: .y)
        _ = setStrokeDelay(result.releaseDelay, press: false)
        _ = setEndExtension(result.endExtension)
        unifiedCalibration.acknowledgeAppliedEnding(releaseDelay: result.releaseDelay, endExtension: result.endExtension)
        speed = result.speed
        unifiedNote = "\(unifiedTargetName) · M \(UnifiedCalibration.format(result.movement)) / X \(UnifiedCalibration.format(result.spacingX)) / Y \(UnifiedCalibration.format(result.spacingY)) 点 · \(speedText) 点/秒 · 收笔 \(UnifiedCalibration.format(result.releaseDelay * 1000)) ms / \(UnifiedCalibration.format(result.endExtension)) 点"
        calibrationNote = unifiedNote; spacingNote = unifiedNote
        preferences.set(unifiedNote, forKey: "unifiedNote")
        preferences.set(calibrationNote, forKey: "calibrationNote"); preferences.set(spacingNote, forKey: "spacingNote")
        unifiedSnapshot = currentUnifiedSettings
        engine.speed = speed
        scheduleProcessing(); closeUnifiedCalibration(); showMain()
        status = "联合校准已结束，结果已应用。"
    }
    var hasUnifiedInk: Bool {
        guard let area = unifiedCalibration.area, let pid = unifiedPID else { return false }
        return calibrationAutomation.hasInk(in: area, targetPID: pid, includeAnnotations: false)
    }
    func clearUnifiedInk() {
        guard !running, let area = unifiedCalibration.area, let pid = unifiedPID else { return }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        guard validateCalibrationTools(area: area, pid: pid, requireTools: true) else { return }
        do {
            let operation = try calibrationAutomation.prepare(newFootprint: nil, area: area, targetPID: pid,
                penButton: penButton, eraserButton: eraserButton, autoClear: true,
                preserveAnnotations: true)
            engine.speed = min(300, speed); cleanupOnly = true; cleanupShowsUnified = true
            if engine.start(actions: operation.actions, transport: .foreground, targetPID: pid) {
                beginCalibrationOperation(operation)
                running = true; paused = false; progress = 0; error = nil
                statusItem?.menu = makeStatusMenu()
                prepareWindowsForRun()
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            } else { cleanupOnly = false; error = "无法开始清理。" }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func setToolButton(_ point: CGPoint, kind: ToolButtonKind, pid: pid_t) -> Bool {
        guard !running, point.x.isFinite, point.y.isFinite,
              let identity = targetIdentity(pid) else { return false }
        if toolTargetIdentity != identity {
            penButton = nil; eraserButton = nil
            preferences.removeObject(forKey: "penButton"); preferences.removeObject(forKey: "eraserButton")
        }
        toolTargetIdentity = identity
        toolTargetName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "目标画板"
        switch kind {
        case .pen: penButton = point; preferences.set([Double(point.x), Double(point.y)], forKey: "penButton")
        case .eraser: eraserButton = point; preferences.set([Double(point.x), Double(point.y)], forKey: "eraserButton")
        }
        preferences.set(identity, forKey: "toolTargetIdentity")
        preferences.set(toolTargetName, forKey: "toolTargetName")
        return true
    }
    func openToolSettings() {
        guard !running else { return }
        if toolSettingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "设置画笔与橡皮按钮"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ToolSettingsView(model: self))
            window.center(); toolSettingsWindow = window
        }
        toolSettingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func closeToolSettings() { toolSettingsWindow?.orderOut(nil) }
    func testToolButton(_ kind: ToolButtonKind) {
        guard !running else { return }
        guard let point = kind == .pen ? penButton : eraserButton,
              let hit = targetAt(CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1)),
              targetIdentity(hit.0) == toolTargetIdentity,
              region?.contains(point) != true else {
            error = "按钮位置已不可用，请重新定位当前画板的工具按钮。"; return
        }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        hideOverlay(); toolTest = kind; toolTestPID = hit.0; wasProbe = false
        if engine.start(actions: [.selectTool(point)], transport: .foreground, targetPID: hit.0) {
            running = true; paused = false; progress = 0; error = nil
            statusItem?.menu = makeStatusMenu()
            prepareWindowsForRun()
            NSRunningApplication(processIdentifier: hit.0)?.activate(options: [])
        } else { toolTest = nil; toolTestPID = nil; error = "无法测试工具切换，请检查权限与按钮位置。" }
    }
    func chooseToolButton(_ kind: ToolButtonKind) {
        guard !running else { return }
        hideOverlay()
        let showMain = mainWindow?.isVisible == true
        let showMovement = calibrationWindow?.isVisible == true
        let showSpacing = spacingWindow?.isVisible == true
        let showUnified = unifiedWindow?.isVisible == true
        mainWindow?.orderOut(nil); calibrationWindow?.orderOut(nil); spacingWindow?.orderOut(nil); unifiedWindow?.orderOut(nil); toolSettingsWindow?.orderOut(nil)
        pointPicker.begin(prompt: kind == .pen ? "点击目标画板的画笔按钮中心" : "点击目标画板的橡皮擦按钮中心") { [weak self] point in
            guard let self else { return }
            if let point {
                let hit = self.targetAt(CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1))
                if let pid = hit?.0 { _ = self.setToolButton(point, kind: kind, pid: pid) }
                else { self.error = "没有识别到按钮所在的软件，请重新定位。" }
            }
            if showMain { self.mainWindow?.orderFront(nil) }
            if showMovement { self.calibrationWindow?.orderFront(nil) }
            if showSpacing { self.spacingWindow?.orderFront(nil) }
            if showUnified { self.unifiedWindow?.orderFront(nil) }
            self.toolSettingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func validateCalibrationTools(area: CGRect, pid: pid_t, requireTools: Bool = false) -> Bool {
        let buttons: [CGPoint]
        if autoClearCalibration || requireTools {
            guard toolLocationsReady, let penButton, let eraserButton else {
                error = CalibrationAutomation.AutomationError.missingButtons.localizedDescription; return false
            }
            buttons = [penButton, eraserButton]
        } else {
            guard let penButton else { return true }
            buttons = [penButton]
        }
        guard targetIdentity(pid) == toolTargetIdentity else {
            error = "工具按钮属于另一软件，请重新指定当前画板的画笔和橡皮按钮。"; return false
        }
        for point in buttons {
            guard !area.contains(point),
                  CanvasMetrics.current(for: CGRect(x: point.x - 0.25, y: point.y - 0.25, width: 0.5, height: 0.5)) != nil,
                  targetAt(CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1))?.0 == pid else {
                error = "工具按钮的位置已不可用，或位于测试区内。请保持画板位置不变并重新定位。"; return false
            }
        }
        return true
    }
    private func prepareCalibrationOperation(paths: [[CGPoint]], area: CGRect, pid: pid_t, movement: Double) -> CalibrationOperation? {
        guard validateCalibrationTools(area: area, pid: pid) else { return nil }
        let actual = DrawingEngine.mapPaths(paths, to: area, brushWidth: brushWidth).map { path in
            path.map { CGPoint(x: ($0.x - area.minX) / area.width, y: ($0.y - area.minY) / area.height) }
        }
        let footprint = CalibrationFootprint(paths: actual, area: area, brushWidth: brushWidth, targetPID: pid)
        do {
            if autoClearCalibration { _ = try CalibrationCleanup.replay(footprint: footprint) }
            return try calibrationAutomation.prepare(newFootprint: footprint, area: area, targetPID: pid,
                penButton: penButton, eraserButton: eraserButton,
                autoClear: autoClearCalibration, minimumMovement: movement)
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func beginCalibrationOperation(_ operation: CalibrationOperation) {
        let erased = calibrationAutomation.records.filter { operation.erasedIDs.contains($0.id) }
        invalidateCalibrationFeedback(for: erased)
        calibrationAutomation.begin(operation)
    }
    private func invalidateCalibrationFeedback(for erased: [CalibrationInkRecord]) {
        // 共用测试区时，擦掉另一种校准的笔迹也必须撤回该轮的待反馈状态。
        // 已确认的历史上界保留；未确认的行选择不能用于已擦掉的测试线。
        if calibration.hasDrawn, !calibration.finished, let area = calibration.area,
           erased.contains(where: { $0.footprint.targetPID == calibrationPID && $0.footprint.area.intersects(area) }) {
            _ = calibration.repeatRound(); calibration.selectedRow = nil
        }
        if spacingCalibration.hasDrawn, !spacingCalibration.finished, let area = spacingCalibration.area,
           erased.contains(where: { $0.footprint.targetPID == spacingPID && $0.footprint.area.intersects(area) }) {
            _ = spacingCalibration.repeatRound()
        }
        if unifiedCalibration.hasDrawn, let area = unifiedCalibration.area,
           erased.contains(where: { $0.footprint.targetPID == unifiedPID && $0.footprint.area.intersects(area) }) {
            _ = unifiedCalibration.repeatRound()
        }
    }
    func hasCalibrationInk(spacing: Bool) -> Bool {
        guard let area = spacing ? spacingCalibration.area : calibration.area,
              let pid = spacing ? spacingPID : calibrationPID else { return false }
        return calibrationAutomation.hasInk(in: area, targetPID: pid)
    }
    func clearCalibrationInk(spacing: Bool) {
        guard !running, let area = spacing ? spacingCalibration.area : calibration.area,
              let pid = spacing ? spacingPID : calibrationPID else { return }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        // 显式清理也使用用户已指定的工具；不受自动开关影响。
        guard toolLocationsReady else { error = CalibrationAutomation.AutomationError.missingButtons.localizedDescription; return }
        guard validateCalibrationTools(area: area, pid: pid, requireTools: true) else { return }
        do {
            let operation = try calibrationAutomation.prepare(newFootprint: nil, area: area, targetPID: pid,
                penButton: penButton, eraserButton: eraserButton, autoClear: true)
            engine.speed = speed; cleanupOnly = true; cleanupShowsSpacing = spacing; cleanupShowsUnified = false
            if engine.start(actions: operation.actions, transport: .foreground, targetPID: pid) {
                beginCalibrationOperation(operation)
                running = true; paused = false; progress = 0; error = nil
                statusItem?.menu = makeStatusMenu()
                prepareWindowsForRun()
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            } else { cleanupOnly = false; error = "无法开始清理，请检查权限与测试区。" }
        } catch { self.error = error.localizedDescription }
    }
    private func showPausePanel() {
        guard engine.running, engine.paused else { return }
        if pausePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 186), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "绘制已暂停"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: PauseControlsView(model: self))
            pausePanel = panel
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame { pausePanel?.setFrameOrigin(NSPoint(x: frame.minX + 22, y: frame.minY + 22)) }
        pausePanel?.orderFrontRegardless()
        statusItem?.menu = makeStatusMenu()
    }

    func openCalibration() {
        guard !running else { return }
        hideOverlay()
        if calibrationWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "校准最小移动距离"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 760)
            window.contentView = NSHostingView(rootView: CalibrationHostView(model: self))
            window.center(); calibrationWindow = window
        }
        calibrationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func closeCalibration() { if calibrationRunning { engine.stop() }; calibrationWindow?.orderOut(nil) }
    func chooseCalibrationArea() {
        guard !running else { return }
        hideOverlay(); mainWindow?.orderOut(nil); calibrationWindow?.orderOut(nil)
        picker.begin(mode: .drag) { [weak self] rect in
            guard let self else { return }
            if let rect {
                _ = self.calibration.setArea(rect)
                let target = self.targetAt(rect)
                if let oldPID = self.calibrationPID, oldPID != target?.0, self.calibration.round > 1 {
                    self.calibration.retest(); self.calibrationBrush = nil; self.calibrationSpeed = nil
                }
                self.calibrationPID = target?.0; self.calibrationTargetName = target?.1 ?? "当前画板"
            }
            self.calibrationWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func drawCalibrationRound() {
        guard !running, let area = calibration.area else { return }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        guard let calibrationPID else { error = "未识别到测试区所在的目标程序，请重新框选实际画板的空白区。"; return }
        if calibration.round == 1, calibration.measuredMinimum == nil, !calibration.hasDrawn {
            calibrationBrush = brushWidth; calibrationSpeed = speed
        } else if calibrationBrush != brushWidth || calibrationSpeed != speed {
            error = "校准期间请保持同一笔宽与速度。请恢复原设置，或点击“重新测量”开始新的校准。"
            return
        }
        let paths = calibration.numberedPaths(brushWidth: brushWidth)
        guard !paths.isEmpty else { return }
        guard let operation = prepareCalibrationOperation(paths: paths, area: area, pid: calibrationPID,
                                                          movement: calibration.candidates.max() ?? 0) else { return }
        engine.speed = speed
        // 每条候选短线一次拖到终点，避免按 timer 拆成无效的小步；不会拉长候选。
        engine.minimumMovement = calibration.candidates.max() ?? 0
        calibrationRunning = true; wasProbe = false
        if engine.start(actions: operation.actions, transport: .foreground, targetPID: calibrationPID) {
            beginCalibrationOperation(operation)
            error = nil
            running = true; paused = false; progress = 0
            inputGuardNote = engine.hasImmediateInputGuard ? "" : "兼容监听：能响应暂停，但无法保证拦截触发暂停的第一下输入。"
            statusItem?.menu = makeStatusMenu()
            prepareWindowsForRun()
            NSRunningApplication(processIdentifier: calibrationPID)?.activate(options: [])
        } else {
            calibrationRunning = false; engine.minimumMovement = minimumMovement
            error = "校准无法开始，请检查权限、画板位置和测试区。"
        }
    }
    func applyCalibration(_ value: Double) {
        guard value.isFinite, value >= 0 else { error = "校准结果无效，请重新测量。"; return }
        if let calibrationBrush, let calibrationSpeed, calibrationBrush != brushWidth || calibrationSpeed != speed {
            error = "笔宽或速度已改变，请恢复测试设置或重新测量后采用。"; return
        }
        guard setMinimumMovement(value) else { error = "位移超出可用范围，请重新测量。"; return }
        let measured = calibration.measuredMinimum.map(MovementCalibration.format) ?? MovementCalibration.format(value)
        calibrationNote = "\(calibrationTargetName)：可见上界 \(measured) 点 · 黑笔 \(String(format: "%.1f", calibrationBrush ?? brushWidth)) 点 · \(Int(calibrationSpeed ?? speed)) 点/秒"
        preferences.set(calibrationNote, forKey: "calibrationNote")
        scheduleProcessing(); closeCalibration(); showMain()
    }
    @discardableResult
    func setMinimumMovement(_ value: Double) -> Bool {
        guard value.isFinite, value <= 10_000 else { return false }
        let validated = max(0, value)
        if minimumMovement != validated { minimumMovement = validated }
        engine.minimumMovement = validated
        preferences.set(validated, forKey: "minimumMovement")
        return true
    }
    @discardableResult
    func setBrushWidth(_ value: Double) -> Bool {
        guard value.isFinite, value > 0, value <= 10_000 else { return false }
        if brushWidth != value { brushWidth = value }
        preferences.set(value, forKey: "brushWidth")
        return true
    }
    @discardableResult
    func setMinimumSpacing(_ value: Double, axis: SpacingAxis) -> Bool {
        guard value.isFinite, value > 0, value <= 10_000 else { return false }
        switch axis {
        case .x:
            if minimumSpacingX != value { minimumSpacingX = value }
            preferences.set(value, forKey: "minimumSpacingX")
        case .y:
            if minimumSpacingY != value { minimumSpacingY = value }
            preferences.set(value, forKey: "minimumSpacingY")
        }
        let x = minimumSpacingX.map(MovementCalibration.format) ?? "未测"
        let y = minimumSpacingY.map(MovementCalibration.format) ?? "未测"
        spacingNote = "横 \(x) / 纵 \(y) 点 · 手动修正值"
        preferences.set(spacingNote, forKey: "spacingNote")
        return true
    }
    func openSpacingCalibration() {
        guard !running else { return }
        hideOverlay()
        if spacingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 830), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "校准最小笔画间距"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 800)
            window.contentView = NSHostingView(rootView: SpacingCalibrationHostView(model: self))
            window.center(); spacingWindow = window
        }
        spacingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func closeSpacingCalibration() { if spacingRunning { engine.stop() }; spacingWindow?.orderOut(nil) }
    func chooseSpacingArea() {
        guard !running else { return }
        hideOverlay(); mainWindow?.orderOut(nil); spacingWindow?.orderOut(nil)
        picker.begin(mode: .drag) { [weak self] rect in
            guard let self else { return }
            if let rect {
                _ = self.spacingCalibration.setArea(rect)
                let target = self.targetAt(rect)
                if let oldPID = self.spacingPID, oldPID != target?.0 {
                    self.spacingCalibration.retest(); self.spacingBrush = nil; self.spacingSpeed = nil
                }
                self.spacingPID = target?.0; self.spacingTargetName = target?.1 ?? "当前画板"
            }
            self.spacingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func drawSpacingRound() {
        guard !running, let area = spacingCalibration.area else { return }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        guard let spacingPID else { error = "请重新框选目标画板的一块空白测试区。"; return }
        if spacingCalibration.round == 1, spacingCalibration.measuredMinimum == nil, !spacingCalibration.hasDrawn {
            spacingBrush = brushWidth; spacingSpeed = speed; spacingMovement = minimumMovement
        } else if spacingBrush != brushWidth || spacingSpeed != speed || spacingMovement != minimumMovement {
            error = "校准期间请保持相同笔宽、速度与位移阈值；恢复设置或重新测量。"
            return
        }
        let paths = spacingCalibration.numberedPaths(brushWidth: brushWidth, minimumMovement: minimumMovement)
        guard !paths.isEmpty else { return }
        guard let operation = prepareCalibrationOperation(paths: paths, area: area, pid: spacingPID,
                                                          movement: minimumMovement) else { return }
        engine.speed = speed; engine.minimumMovement = minimumMovement
        spacingRunning = true; wasProbe = false
        if engine.start(actions: operation.actions, transport: .foreground, targetPID: spacingPID) {
            beginCalibrationOperation(operation)
            error = nil
            running = true; paused = false; progress = 0
            inputGuardNote = engine.hasImmediateInputGuard ? "" : "兼容监听：无法保证拦截触发暂停的第一下输入。"
            statusItem?.menu = makeStatusMenu()
            prepareWindowsForRun()
            NSRunningApplication(processIdentifier: spacingPID)?.activate(options: [])
        } else {
            spacingRunning = false; engine.minimumMovement = minimumMovement
            error = "间距测试无法开始，请检查权限、测试区与画板位置。"
        }
    }
    func applySpacingCalibration(_ value: Double) {
        if let spacingBrush, let spacingSpeed, let spacingMovement,
           spacingBrush != brushWidth || spacingSpeed != speed || spacingMovement != minimumMovement {
            error = "笔宽、速度或位移已改变，请恢复测试设置或重新测量后采用。"; return
        }
        guard setMinimumSpacing(value, axis: spacingCalibration.axis) else { error = "间距校准结果无效，请重新测量。"; return }
        let x = minimumSpacingX.map(MovementCalibration.format) ?? "未测"
        let y = minimumSpacingY.map(MovementCalibration.format) ?? "未测"
        spacingNote = "横 \(x) / 纵 \(y) 点（含余量）\n\(spacingTargetName) · 笔宽 \(MovementCalibration.format(spacingBrush ?? brushWidth)) 点 · \(Int(spacingSpeed ?? speed)) 点/秒"
        preferences.set(spacingNote, forKey: "spacingNote")
        scheduleProcessing(); closeSpacingCalibration(); showMain()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        status = "请在系统设置 → 隐私与安全性 → 辅助功能中允许“屏幕绘图器”"
    }
    func start(probe: Bool = false) {
        guard !running, let region, let plan = selectedPlan else { return }
        guard canvasMetrics != nil else { error = "画布显示器已改变，请重新框选。"; return }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        if transport == .background, targetPID == nil { error = "请先选择后台绘制的目标程序。"; return }
        if transport == .background, !probe, !backgroundConfirmed {
            error = "请先点击“试画一笔”，确认目标能收到笔画，再开始完整后台绘制。"; return
        }
        let drawingPaths = probe ? [[CGPoint(x: 0.04, y: 0.04), CGPoint(x: 0.13, y: 0.09), CGPoint(x: 0.22, y: 0.04)]] : paths(plan)
        guard !drawingPaths.isEmpty else { error = "当前模式没有可绘制的笔画，请检查校准参数或换一种模式。"; return }
        guard fullCompensationFits(drawingPaths, area: region, extension: endExtension) else {
            error = "画布边缘没有足够空间完成末端补偿，请减小补偿值或重新选定更大的画布。"
            return
        }
        var actions: [DrawingAction] = [.profiledStrokes(paths: drawingPaths, rect: region, brushWidth: brushWidth,
            minimumMovement: minimumMovement, speed: nil, pressDelay: nil, releaseDelay: nil,
            endExtension: endExtension)]
        if transport == .foreground, let pid = targetPID, targetIdentity(pid) == toolTargetIdentity, let penButton {
            guard !region.contains(penButton), targetAt(CGRect(x: penButton.x - 0.5, y: penButton.y - 0.5, width: 1, height: 1))?.0 == pid else {
                error = "画笔按钮位置已不可用，请重新定位后再绘制。"; return
            }
            actions.insert(.selectTool(penButton), at: 0)
        }
        hideOverlay(); engine.speed = speed; engine.minimumMovement = minimumMovement
        wasProbe = probe
        if engine.start(actions: actions, transport: transport, targetPID: targetPID) {
            if let pid = targetPID {
                invalidateCalibrationFeedback(for: calibrationAutomation.records.filter { $0.footprint.targetPID == pid && $0.footprint.area.intersects(region) })
                calibrationAutomation.forgetInk(overlapping: region, targetPID: pid)
            }
            running = true; paused = false; progress = 0
            inputGuardNote = transport == .foreground && !engine.hasImmediateInputGuard ? "兼容监听：能响应暂停，但无法保证拦截触发暂停的第一下输入。" : ""
            statusItem?.menu = makeStatusMenu()
            if transport == .foreground {
                prepareWindowsForRun()
                if let targetPID { NSRunningApplication(processIdentifier: targetPID)?.activate(options: []) }
            }
        } else { error = "无法开始，请检查辅助功能权限、画布尺寸和目标程序。" }
    }
    private func fullCompensationFits(_ paths: [[CGPoint]], area: CGRect, extension value: Double) -> Bool {
        guard value > 0 else { return true }
        let intended = DrawingEngine.mapPaths(paths, to: area, brushWidth: brushWidth)
        let actual = DrawingEngine.compensatedPaths(paths, to: area, brushWidth: brushWidth, endExtension: value)
        guard intended.count == actual.count else { return false }
        return zip(intended, actual).allSatisfy { path, extended in
            guard let end = path.last, let actualEnd = extended.last else { return false }
            if !zip(path, path.dropFirst()).contains(where: { $0 != $1 }) { return true }
            return abs(hypot(actualEnd.x - end.x, actualEnd.y - end.y) - value) <= max(0.000_001, value * 0.000_001)
        }
    }
    func exportPreview() {
        guard let plan = selectedPlan else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(selectedMode.title)-预览.png"
        if panel.runModal() == .OK, let url = panel.url {
            let bitmap = NSBitmapImageRep(cgImage: plan.preview)
            do { try bitmap.representation(using: .png, properties: [:])?.write(to: url) }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.48, green: 0.76, blue: 0.65) : Color(red: 0.20, green: 0.41, blue: 0.34) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 278)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("把照片，一笔一笔画出来").font(.system(size: 25, weight: .semibold))
                        Text("选定画布并校准画笔，预览自动匹配可绘制的精度。").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("\(model.plans.count + model.previewErrors.count) / \(DrawingMode.allCases.count) 种效果")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text("本机处理").font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(accent.opacity(0.08), in: Capsule())
                }
                HStack(spacing: 12) {
                    ForEach(DrawingMode.allCases) { mode in modeCard(mode) }
                }
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.white)
                        if let plan = model.selectedPlan {
                            Image(decorative: plan.preview, scale: 1).resizable().interpolation(.none).scaledToFit().padding(15)
                        } else if let message = model.previewErrors[model.selectedMode] {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                                Text("\(model.selectedMode.title)预览未完成").font(.system(size: 15, weight: .semibold))
                                Text(message).font(.system(size: 12)).multilineTextAlignment(.center)
                                Button("重新生成预览") { model.scheduleProcessing() }.disabled(model.running)
                            }.foregroundStyle(Color.black.opacity(0.65)).padding(30)
                        } else if model.pendingPreviewModes.contains(model.selectedMode) {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("正在生成\(model.selectedMode.title)…").font(.system(size: 14))
                                Text("已完成的效果会先显示").font(.system(size: 11))
                            }.foregroundStyle(Color.black.opacity(0.6))
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.selectedMode.title).font(.system(size: 18, weight: .semibold))
                        Text(model.selectedMode.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        stat("笔画数量", model.selectedPlan.map { "\($0.strokes.count) 笔" } ?? "—")
                        stat("预计耗时", model.estimate)
                        Text(model.precisionText).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let note = model.selectedPlan?.resolutionNote, !note.isEmpty {
                            Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("耗时是估算；目标画板的响应速度会影响结果。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { model.toggleOverlay() } label: { Label(model.overlayVisible ? "隐藏叠加预览" : "叠加到画布", systemImage: "square.on.square") }
                            .disabled(model.region == nil || model.selectedPlan == nil || model.running)
                        Button { model.exportPreview() } label: { Label("导出当前预览", systemImage: "square.and.arrow.up") }
                            .disabled(model.selectedPlan == nil || model.running)
                    }.frame(width: 160)
                }.frame(maxHeight: .infinity)
                bottomBar
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .frame(minWidth: 1000, minHeight: 740)
        .tint(accent)
        .onChange(of: model.brushWidth) { _, _ in model.scheduleProcessing() }
        .onChange(of: model.minimumMovement) { _, _ in model.scheduleProcessing() }
        .onChange(of: model.minimumSpacingX) { _, _ in model.scheduleProcessing() }
        .onChange(of: model.minimumSpacingY) { _, _ in model.scheduleProcessing() }
        .onChange(of: model.selectedMode) { _, _ in model.hideOverlay() }
        .onChange(of: model.transport) { _, _ in model.backgroundConfirmed = false }
        .alert("需要处理", isPresented: Binding(get: { model.error != nil && !model.unifiedVisible }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("目标画板收到测试笔画了吗？", isPresented: $model.showBackgroundCheck) {
            Button("收到了，启用后台绘制") { model.backgroundConfirmed = true; model.status = "后台试画已确认；请保持目标画布位置不变" }
            Button("没收到", role: .cancel) { model.backgroundConfirmed = false; model.status = "该目标暂不能后台绘制，可以切换前台鼠标" }
        } message: { Text("同时检查真实鼠标是否保持原位。确认后可完整发送笔画；后台兼容性取决于目标程序。") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !model.running, let first = providers.first else { return false }
            _ = first.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.load(url) } } }
            return true
        }
    }
    private var sidebar: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "pencil.tip.crop.circle.fill").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("屏幕绘图器").font(.system(size: 18, weight: .semibold))
                    Text("SCREEN SKETCH").font(.system(size: 9, weight: .medium)).tracking(1.4).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 4)
            sectionLabel("01", "导入图片")
            HStack {
                if let image = model.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: 42, height: 42).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                }
                Text(model.imageName).font(.system(size: 12)).lineLimit(2)
                Spacer()
            }
            Button("选择图片…") { model.chooseImage() }.frame(maxWidth: .infinity)
            Text("也可以把照片拖进窗口").font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("图片调整").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("重置") { model.resetImageAdjustments() }
                        .font(.system(size: 10)).disabled(model.imageAdjustmentsAreNeutral)
                }
                adjustmentSlider(.exposure)
                adjustmentSlider(.contrast)
                adjustmentSlider(.shadows)
                if model.selectedMode == .solid { adjustmentSlider(.fillThreshold) }
                Text(model.selectedMode == .solid
                     ? "松开拉杆更新预览。阈值向右保留更多浅灰细节，也可能增加背景笔迹。"
                     : "松开拉杆更新预览。调节同时应用到实际笔迹，保留纯白纸色和纯黑墨色。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 5)
            Divider()
            sectionLabel("02", "指定画布")
            HStack {
                Button("拖拽框选") { model.selectRegion(.drag) }
                Button("两点选区") { model.selectRegion(.twoPoints) }
            }
            Text(model.regionText).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("设置画笔 / 橡皮按钮…") { model.openToolSettings() }.frame(maxWidth: .infinity)
            Text(model.toolLocationsReady ? "\(model.toolTargetName) · 已定位两个工具按钮" : "定位两个按钮后，校准可自动擦除上一轮").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            sectionLabel("03", "画笔与精度校准")
            HStack {
                Text("实际黑笔宽度").font(.system(size: 11))
                Spacer()
                TextField("点", value: Binding(get: { model.brushWidth }, set: { _ = model.setBrushWidth($0) }), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 62)
                Text("点").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("填写屏幕上实际笔宽；目标软件标注的像素在缩放后可能不同。通用模式无法直接读取其他软件的笔刷。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 5) {
                HStack {
                    Text("最小有效位移").font(.system(size: 11))
                    Spacer()
                    TextField("点", value: minimumMovementBinding, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 62)
                    Text("点").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                spacingField("横向", axis: .x, value: model.minimumSpacingX)
                spacingField("纵向", axis: .y, value: model.minimumSpacingY)
            }
            Button("联合校准位移 / 间距 / 速度 / 收笔…") { model.openUnifiedCalibration() }.frame(maxWidth: .infinity)
            Text(model.unifiedNote).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("M、#、V、E 四区，每项三组；# 同时测 X/Y，E 区分终点等待和末端补偿。换画板、笔宽或缩放后重新校准。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            sectionLabel("04", "输入方式")
            Picker("输入方式", selection: $model.transport) {
                ForEach(DrawingTransport.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(maxWidth: .infinity)
            if model.transport == .background {
                Menu {
                    ForEach(model.applications, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "进程 \(app.processIdentifier)") { model.setTarget(app.processIdentifier) }
                    }
                } label: { Text("目标：\(model.targetName)").lineLimit(1) }
                Text(model.backgroundConfirmed ? "✓ 已确认收到测试笔画" : "先试画一笔；部分软件不接收后台输入。")
                    .font(.system(size: 11)).foregroundStyle(model.backgroundConfirmed ? accent : .secondary)
            } else {
                Text("绘制会占用鼠标。任意按键或手动鼠标操作暂停；点击“继续”恢复。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("运行时自动最小化窗口", isOn: $model.autoMinimizeOnRun).toggleStyle(.checkbox).font(.system(size: 11))
            Text("关闭后保留窗口显示；前台绘制仍需让画板保持焦点。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("辅助功能权限…") { model.requestAccessibility() }.font(.system(size: 11))
        }.padding(22).frame(maxWidth: .infinity, alignment: .top)
        }.scrollIndicators(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .disabled(model.running)
    }
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text("移动速度").font(.system(size: 12, weight: .medium)); Spacer(); Text("\(model.speedText) 点/秒").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $model.speed, in: min(60, model.speed)...max(8000, model.speed))
                        .disabled(model.isCalibrating)
                    Text("落笔 \(Int(model.pressDelay * 1000)) ms · 收笔 \(Int(model.releaseDelay * 1000)) ms / \(UnifiedCalibration.format(model.endExtension)) 点").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: 260)
                Spacer()
                if model.running {
                    Button(model.paused ? "继续" : "暂停") { model.pauseDrawing() }.buttonStyle(.bordered)
                    Button("停止") { model.stopDrawing() }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("试画一笔") { model.start(probe: true) }.buttonStyle(.bordered).disabled(model.region == nil || model.selectedPlan == nil)
                    Button { model.start() } label: { Label("开始绘制", systemImage: "play.fill").padding(.horizontal, 10) }
                        .buttonStyle(.borderedProminent).disabled(model.region == nil || model.selectedPlan == nil)
                }
            }
            if model.running { ProgressView(value: model.progress).tint(accent) }
            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            if !model.inputGuardNote.isEmpty { Text(model.inputGuardNote).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(15).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private var minimumMovementBinding: Binding<Double> {
        Binding(get: { model.minimumMovement }, set: { _ = model.setMinimumMovement($0) })
    }
    private func adjustmentSlider(_ adjustment: ImageAdjustment) -> some View {
        let value = model.imageAdjustmentValue(adjustment)
        let text: String
        switch adjustment {
        case .exposure: text = String(format: "%+.2f", value)
        case .contrast: text = String(format: "%.2f×", value)
        case .shadows: text = "\(Int((value * 100).rounded()))%"
        case .fillThreshold: text = String(format: "%+.0f", value)
        }
        return VStack(spacing: 4) {
            HStack {
                Text(adjustment.title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Slider(value: Binding(get: { model.imageAdjustmentValue(adjustment) },
                                  set: { _ = model.setImageAdjustment($0, adjustment: adjustment) }),
                   in: adjustment.range, onEditingChanged: model.editImageAdjustments)
        }
    }
    private func spacingField(_ title: String, axis: SpacingAxis, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)间距 / 点").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("未校准", value: Binding<Double?>(get: { value }, set: { if let value = $0 { _ = model.setMinimumSpacing(value, axis: axis) } }), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
        }
    }
    private func modeCard(_ mode: DrawingMode) -> some View {
        Button { model.selectedMode = mode } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.white)
                    if let plan = model.plans[mode] { Image(decorative: plan.preview, scale: 1).resizable().interpolation(.none).scaledToFit().padding(5) }
                    else if model.previewErrors[mode] != nil {
                        Label("未完成", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Color.black.opacity(0.6))
                    } else if model.pendingPreviewModes.contains(mode) {
                        VStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("生成中…").font(.system(size: 10)).foregroundStyle(Color.black.opacity(0.6))
                        }
                    }
                }.frame(height: 105)
                HStack { Text(mode.title).font(.system(size: 12, weight: .semibold)); Spacer(); if mode == model.selectedMode { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) } }
            }.padding(10).background(mode == model.selectedMode ? accent.opacity(0.06) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(mode == model.selectedMode ? accent.opacity(0.65) : .black.opacity(0.07), lineWidth: mode == model.selectedMode ? 1.5 : 1))
        }.buttonStyle(.plain).disabled(model.running).frame(maxWidth: .infinity)
    }
    private func sectionLabel(_ n: String, _ title: String) -> some View {
        HStack(spacing: 8) { Text(n).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent); Text(title).font(.system(size: 12, weight: .semibold)) }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.system(size: 11)).foregroundStyle(.secondary); Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit() }
    }
}

struct PauseControlsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已松开画笔，进度已保留").font(.system(size: 13, weight: .medium))
            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text("点击继续后保持鼠标不动，1 秒后接着绘制。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("继续绘制") { model.pauseDrawing() }.buttonStyle(.borderedProminent)
                Button("停止任务") { model.stopDrawing() }
                Spacer()
                Button("打开设置") { model.showMain() }
            }
        }.padding(15)
    }
}

struct CalibrationHostView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            CalibrationAutomationControls(model: model, spacing: false)
            MovementCalibrationView(calibration: model.calibration, onSelectArea: model.chooseCalibrationArea,
                onDraw: model.drawCalibrationRound, onApply: model.applyCalibration, onClose: model.closeCalibration,
                isRunning: model.running, isPaused: model.paused, onPauseResume: model.pauseDrawing, onStop: model.stopDrawing)
            Text("本轮使用黑笔 \(String(format: "%.1f", model.brushWidth)) 点、\(Int(model.speed)) 点/秒；请先在主窗口设好。").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
    }
}

struct SpacingCalibrationHostView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            CalibrationAutomationControls(model: model, spacing: true)
            SpacingCalibrationView(calibration: model.spacingCalibration, onSelectArea: model.chooseSpacingArea,
                onDraw: model.drawSpacingRound, onApply: { _, value in model.applySpacingCalibration(value) }, onClose: model.closeSpacingCalibration,
                isRunning: model.running, isPaused: model.paused, onPauseResume: model.pauseDrawing, onStop: model.stopDrawing)
            Text("当前黑笔 \(MovementCalibration.format(model.brushWidth)) 点 · \(Int(model.speed)) 点/秒；测试线会长于最小有效位移。")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
    }
}

struct CalibrationAutomationControls: View {
    @ObservedObject var model: AppModel
    let spacing: Bool
    private var hasInk: Bool {
        model.hasCalibrationInk(spacing: spacing)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("自动清理上一轮", isOn: $model.autoClearCalibration).toggleStyle(.checkbox)
                Spacer()
                Button("设置工具按钮…") { model.openToolSettings() }
                Button("清理上轮") { model.clearCalibrationInk(spacing: spacing) }.disabled(!hasInk)
            }.disabled(model.running)
            Text(model.automaticCleanupText).font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.padding(.horizontal, 24).padding(.top, 16)
    }
}

struct UnifiedCalibrationHostView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("自动清理上一轮", isOn: $model.autoClearCalibration).toggleStyle(.checkbox)
                    Spacer()
                    Button("设置工具 / 等待时间…") { model.openToolSettings() }
                    Button("清理测试笔迹") { model.clearUnifiedInk() }.disabled(!model.hasUnifiedInk)
                }.disabled(model.running)
                Toggle("运行时自动最小化窗口", isOn: $model.autoMinimizeOnRun).toggleStyle(.checkbox).font(.system(size: 11)).disabled(model.running)
                Text("\(model.unifiedCleanupText) · 落笔 \(Int(model.pressDelay * 1000)) ms / 收笔 \(Int(model.releaseDelay * 1000)) ms / \(UnifiedCalibration.format(model.endExtension)) 点")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("主画布：\(model.targetName) · 画笔 \(model.toolPointText(model.penButton)) · 橡皮 \(model.toolPointText(model.eraserButton))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(.horizontal, 24).padding(.top, 16)
            UnifiedCalibrationView(calibration: model.unifiedCalibration, onSelectArea: model.chooseUnifiedArea,
                onDraw: model.drawUnifiedRound, onConfirm: model.confirmAndApplyUnifiedCalibration, onClose: model.closeUnifiedCalibration,
                isRunning: model.running, isPaused: model.paused, onPauseResume: model.pauseDrawing, onStop: model.stopDrawing)
            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 24).padding(.bottom, 12)
        }.background(Color(nsColor: .windowBackgroundColor)).buttonStyle(.bordered)
    }
}

struct ToolSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("画笔与橡皮按钮").font(.system(size: 22, weight: .semibold)); Spacer(); Button("完成") { model.closeToolSettings() } }
            Text("定位时单击按钮中心，只记录屏幕点，不会点击到目标软件。橡皮大小直接使用目标画板的当前设置。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("指定画笔按钮") { model.chooseToolButton(.pen) }; Spacer(); Text(model.toolPointText(model.penButton)).font(.system(size: 12)).monospacedDigit() }
            HStack { Button("指定橡皮按钮") { model.chooseToolButton(.eraser) }; Spacer(); Text(model.toolPointText(model.eraserButton)).font(.system(size: 12)).monospacedDigit() }
            HStack {
                Button("试切换画笔") { model.testToolButton(.pen) }.disabled(model.penButton == nil)
                Button("试切换橡皮") { model.testToolButton(.eraser) }.disabled(model.eraserButton == nil)
            }
            Text("切换工具会连续点击 3 次，让首次激活窗口后仍能选中工具。每次点击都有独立停留时间，不随绘制速度缩短。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("末端补偿")
                Spacer()
                TextField("0", value: Binding(get: { model.endExtension }, set: { _ = model.setEndExtension($0) }), format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Text("屏幕点").foregroundStyle(.secondary)
            }.font(.system(size: 12))
            Text("补偿是收笔前沿最后方向多走的距离。默认 0；用 E 测试选择刚好齐线的值，避免画过头。预览显示目标笔迹，额外鼠标行程另留边距。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("落笔停留 / 毫秒").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("120", value: Binding(get: { model.pressDelay * 1000 }, set: { _ = model.setStrokeDelay($0 / 1000, press: true) }), format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("终点停留 / 毫秒").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("120", value: Binding(get: { model.releaseDelay * 1000 }, set: { _ = model.setStrokeDelay($0 / 1000, press: false) }), format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder)
                }
            }
            Text("每笔先按下并停留，再移动；到终点停留后松开。速度提高不会缩短这两段等待；更改后请重新测速。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("校准下一轮前自动擦除记录的笔迹", isOn: $model.autoClearCalibration).toggleStyle(.checkbox).font(.system(size: 12))
            Toggle("运行时自动最小化窗口", isOn: $model.autoMinimizeOnRun).toggleStyle(.checkbox).font(.system(size: 12))
            Text("目标：\(model.toolTargetName) · 沿记录的测试线擦除，不主动擦标题。实际擦除范围由目标画板的橡皮设置决定；移动窗口、工具栏或缩放后请重新定位。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(24).frame(minWidth: 510, minHeight: 700)
            .background(Color(nsColor: .windowBackgroundColor)).buttonStyle(.bordered).disabled(model.running)
    }
}

enum DemoImage {
    static func make() -> CGImage {
        let width = 480, height = 360
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) / Double(width), py = Double(y) / Double(height)
                var r = 0.82 - py * 0.18, g = 0.89 - py * 0.12, b = 0.92 - py * 0.08
                let mountain = 0.53 + 0.12 * sin(px * 9) + 0.06 * cos(px * 18)
                if py > mountain { r = 0.31 + py * 0.17; g = 0.43 + py * 0.13; b = 0.40 + py * 0.15 }
                let mountain2 = 0.77 + 0.035 * sin(px * 22)
                if py > mountain2 { r = 0.18 + px * 0.09; g = 0.27 + px * 0.09; b = 0.23 + px * 0.08 }
                let dx = (px - 0.63) / 0.155, dy = (py - 0.32) / 0.20
                let sphere = dx * dx + dy * dy
                if sphere < 1 {
                    let shade = 0.2 + 0.65 * max(0, -dx * 0.38 - dy * 0.5 + sqrt(1 - sphere) * 0.65)
                    r = shade; g = shade * 0.79; b = shade * 0.59
                }
                if py > 0.43, py < 0.60, abs(px - 0.63) < 0.0018 { r = 0.13; g = 0.14; b = 0.11 }
                if py > 0.59, py < 0.645, abs(px - 0.63) < 0.043 { r = 0.26; g = 0.18; b = 0.11 }
                let i = (y * width + x) * 4
                rgba[i] = UInt8(max(0, min(255, r * 255))); rgba[i + 1] = UInt8(max(0, min(255, g * 255))); rgba[i + 2] = UInt8(max(0, min(255, b * 255)))
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        if let i = CommandLine.arguments.firstIndex(of: "--image"), CommandLine.arguments.count > i + 1 {
            model.load(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        let root = ContentView(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "屏幕绘图器"
        window.contentView = NSHostingView(rootView: root)
        window.minSize = NSSize(width: 1000, height: 760)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center(); model.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.engine.stop(); model.hideOverlay(); sender.orderOut(nil); return false
    }
    func applicationWillTerminate(_ notification: Notification) { model.engine.stop(); model.hideOverlay() }
}

#if !VIEW_RENDERER
@main struct Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
