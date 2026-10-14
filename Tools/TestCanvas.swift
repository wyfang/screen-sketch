import AppKit
import ApplicationServices
import Darwin
import UniformTypeIdentifiers

// 独立诊断程序。只将鼠标事件投递到运行相同可执行文件的另一个测试画板进程。
private func processExecutable(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func quartzMouseLocation() -> [String: Double] {
    let point = CGEvent(source: nil)?.location ?? .zero
    return ["x": Double(point.x), "y": Double(point.y)]
}

private func printJSON(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

private func sendBackgroundProbe(arguments: [String]) -> Int32 {
    guard arguments.count == 5,
          let target = Int32(arguments[2]), target > 0,
          let x = Double(arguments[3]), x.isFinite,
          let y = Double(arguments[4]), y.isFinite else {
        printJSON(["error": "用法：TestCanvas --send-background-probe PID X Y"])
        return 64
    }
    let trusted = AXIsProcessTrusted()
    var report: [String: Any] = [
        "mode": "background-probe",
        "accessibilityTrusted": trusted,
        "targetPID": target,
        "requestedQuartzPoint": ["x": x, "y": y],
        "mouseLocationBeforeQuartz": quartzMouseLocation(),
        "postedEvents": 0,
        "deliveryVerified": false,
        "permissionPrompted": false
    ]
    guard trusted else {
        report["error"] = "辅助功能权限未授予；未弹出授权窗口，也未注入任何事件。"
        printJSON(report)
        return 77
    }
    guard target != getpid(),
          let ownExecutable = processExecutable(getpid()),
          let targetExecutable = processExecutable(target),
          ownExecutable == targetExecutable else {
        report["error"] = "目标必须是运行同一可执行文件的另一个 TestCanvas 进程；未注入事件。"
        printJSON(report)
        return 65
    }
    report["targetExecutable"] = targetExecutable
    guard let source = CGEventSource(stateID: .privateState) else {
        report["error"] = "无法创建私有鼠标事件源。"
        printJSON(report)
        return 70
    }
    let start = CGPoint(x: x, y: y)
    let end = CGPoint(x: x + 44, y: y + 24)
    let specifications: [(CGEventType, CGPoint)] = [
        (.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)
    ]
    let events = specifications.compactMap { type, point in
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    }
    guard events.count == specifications.count else {
        report["error"] = "无法创建完整短笔画；未注入事件。"
        printJSON(report)
        return 70
    }
    for event in events {
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: 0x53534B)
        event.postToPid(target)
        Thread.sleep(forTimeInterval: 0.05)
    }
    report["postedEvents"] = events.count
    report["mouseLocationAfterQuartz"] = quartzMouseLocation()
    report["note"] = "事件已投递；是否送达请以目标画板 probe-log 的计数为准。"
    printJSON(report)
    return 0
}

@MainActor
private final class TestCanvasView: NSView {
    private var strokes: [[CGPoint]] = []
    private var currentStroke: [CGPoint] = []
    private(set) var downCount = 0
    private(set) var dragCount = 0
    private(set) var upCount = 0
    private(set) var lastEventQuartz: CGPoint?
    var onChange: (() -> Void)?

    var eventCount: Int { downCount + dragCount + upCount }
    var strokeCount: Int { strokes.count }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downCount += 1
        currentStroke = [convert(event.locationInWindow, from: nil)]
        lastEventQuartz = event.cgEvent?.location
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        dragCount += 1
        if !currentStroke.isEmpty { currentStroke.append(convert(event.locationInWindow, from: nil)) }
        lastEventQuartz = event.cgEvent?.location
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        upCount += 1
        if !currentStroke.isEmpty {
            currentStroke.append(convert(event.locationInWindow, from: nil))
            strokes.append(currentStroke)
            currentStroke.removeAll()
        }
        lastEventQuartz = event.cgEvent?.location
        changed()
    }

    func clear() {
        strokes.removeAll()
        currentStroke.removeAll()
        downCount = 0
        dragCount = 0
        upCount = 0
        lastEventQuartz = nil
        changed()
    }

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.black.setStroke()
        for stroke in strokes + (currentStroke.isEmpty ? [] : [currentStroke]) {
            guard let first = stroke.first else { continue }
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            for point in stroke.dropFirst() { path.line(to: point) }
            path.stroke()
        }
    }

    func snapshotPNG() -> Data? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
private final class TestCanvasDelegate: NSObject, NSApplicationDelegate {
    private let canvas = TestCanvasView(frame: .zero)
    private let status = NSTextField(labelWithString: "")
    private var window: NSWindow?
    private var logTimer: Timer?
    private var quitTimer: Timer?
    private let logURL: URL?
    private let quitAfter: Double?
    private var logErrorReported = false

    init(logURL: URL?, quitAfter: Double?) {
        self.logURL = logURL
        self.quitAfter = quitAfter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ScreenSketch 独立测试画板 · PID \(getpid())"
        window.minSize = CGSize(width: 440, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        let content = NSView(frame: CGRect(x: 0, y: 0, width: 760, height: 580))
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let clear = NSButton(title: "清空", target: self, action: #selector(clearCanvas))
        let export = NSButton(title: "导出 PNG", target: self, action: #selector(exportCanvas))
        toolbar.addArrangedSubview(clear)
        toolbar.addArrangedSubview(export)
        toolbar.addArrangedSubview(status)
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        canvas.onChange = { [weak self] in self?.updateStatus(); self?.writeProbeLog() }
        updateStatus()

        let menu = NSMenu()
        let rootItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出测试画板", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        rootItem.submenu = appMenu
        menu.addItem(rootItem)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if logURL != nil {
            logTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeProbeLog() }
            }
        }
        if let quitAfter {
            quitTimer = Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.writeProbeLog()
                    NSApp.terminate(nil)
                }
            }
        }
        content.layoutSubtreeIfNeeded()
        writeProbeLog()
        printJSON(["mode": "test-canvas", "pid": getpid(), "probeLog": logURL?.path ?? "",
                   "accessibilityTrusted": AXIsProcessTrusted()])
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        writeProbeLog()
        logTimer?.invalidate()
        quitTimer?.invalidate()
    }

    @objc private func clearCanvas() { canvas.clear() }

    @objc private func exportCanvas() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "TestCanvas.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = self?.canvas.snapshotPNG() else { return }
            do { try data.write(to: url, options: .atomic) }
            catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func updateStatus() {
        status.stringValue = "笔画 \(canvas.strokeCount) · 事件 \(canvas.eventCount)（↓\(canvas.downCount) ↝\(canvas.dragCount) ↑\(canvas.upCount)）"
    }

    private func writeProbeLog() {
        guard let logURL else { return }
        var snapshot: [String: Any] = [
            "pid": getpid(),
            "timestamp": Date().timeIntervalSince1970,
            "eventCount": canvas.eventCount,
            "strokeCount": canvas.strokeCount,
            "mouseDownCount": canvas.downCount,
            "mouseDraggedCount": canvas.dragCount,
            "mouseUpCount": canvas.upCount,
            "mouseLocationQuartz": quartzMouseLocation(),
            "appActive": NSApp.isActive,
            "windowKey": window?.isKeyWindow ?? false,
            "accessibilityTrusted": AXIsProcessTrusted()
        ]
        if let window, let primary = NSScreen.screens.first {
            let rect = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
            snapshot["windowNumber"] = window.windowNumber
            snapshot["windowFrameAppKit"] = ["x": Double(window.frame.minX), "y": Double(window.frame.minY),
                                             "width": Double(window.frame.width), "height": Double(window.frame.height)]
            snapshot["primaryTop"] = Double(primary.frame.maxY)
            snapshot["canvasRectQuartz"] = ["x": Double(rect.minX), "y": Double(primary.frame.maxY - rect.maxY),
                                             "width": Double(rect.width), "height": Double(rect.height)]
        }
        if let last = canvas.lastEventQuartz {
            snapshot["lastEventQuartz"] = ["x": Double(last.x), "y": Double(last.y)]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: logURL, options: .atomic)
        } catch {
            if !logErrorReported {
                printJSON(["probeLogError": error.localizedDescription, "path": logURL.path])
                logErrorReported = true
            }
        }
    }
}

@main @MainActor
private struct TestCanvasProgram {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--send-background-probe") {
            exit(sendBackgroundProbe(arguments: arguments))
        } else {
            var logURL: URL?
            var quitAfter: Double?
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--probe-log":
                    guard index + 1 < arguments.count else {
                        printJSON(["error": "--probe-log 需要文件路径"])
                        exit(64)
                    }
                    logURL = URL(fileURLWithPath: arguments[index + 1])
                    index += 2
                case "--quit-after":
                    guard index + 1 < arguments.count,
                          let seconds = Double(arguments[index + 1]), seconds.isFinite, seconds > 0 else {
                        printJSON(["error": "--quit-after 需要正数秒数"])
                        exit(64)
                    }
                    quitAfter = seconds
                    index += 2
                default:
                    printJSON(["error": "未知参数：\(arguments[index])"])
                    exit(64)
                }
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = TestCanvasDelegate(logURL: logURL, quitAfter: quitAfter)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
