import AppKit

/// 选区和绘图引擎都使用 Quartz 全局坐标：主屏左上角为 (0, 0)，单位为点。
@MainActor
final class ScreenRegionPicker {
    enum SelectionMode {
        case drag
        case twoPoints
    }

    private var windows: [RegionSelectionWindow] = []
    private var views: [RegionSelectionView] = []
    private var completion: ((CGRect?) -> Void)?
    private var mode: SelectionMode = .drag
    private var primaryTop: CGFloat = 0
    private weak var activeView: RegionSelectionView?
    private var firstPoint: CGPoint?
    private var pendingRegion: CGRect?

    func begin(mode: SelectionMode = .drag, completion: @escaping (CGRect?) -> Void) {
        cancel()
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            completion(nil)
            return
        }

        self.mode = mode
        self.completion = completion
        primaryTop = primaryScreen.frame.maxY

        for screen in screens {
            let window = RegionSelectionWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.acceptsMouseMovedEvents = true
            window.cancelAction = { [weak self] in self?.cancel() }

            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.mode = mode
            view.onMouseDown = { [weak self, weak view] point in
                guard let view else { return }
                self?.mouseDown(in: view, point: point)
            }
            view.onMouseMoved = { [weak self, weak view] point in
                guard let view else { return }
                self?.mouseMoved(in: view, point: point)
            }
            view.onMouseUp = { [weak self, weak view] point in
                guard let view else { return }
                self?.mouseUp(in: view, point: point)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        // 让光标所在屏幕接收 Escape，其他屏幕的选区窗口仍正常拦截鼠标。
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()
        if let view = keyWindow?.contentView { keyWindow?.makeFirstResponder(view) }
    }

    func cancel() {
        finish(nil)
    }

    private func mouseDown(in view: RegionSelectionView, point: CGPoint) {
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
        let point = view.clamped(point)
        pendingRegion = nil

        switch mode {
        case .drag:
            activeView = view
            firstPoint = point
            views.forEach {
                $0.selection = nil
                $0.message = nil
                $0.anchor = nil
            }
            view.anchor = point
            view.selection = rectangle(from: point, to: point)
        case .twoPoints:
            guard let firstPoint, let activeView else {
                activeView = view
                self.firstPoint = point
                view.anchor = point
                view.selection = rectangle(from: point, to: point)
                views.forEach { $0.message = "已记录第一个点，请在同一显示器点另一个对角。" }
                return
            }
            guard activeView === view else {
                views.forEach { $0.message = "两个点必须在同一显示器；请回到第一个点所在的屏幕。" }
                return
            }
            let region = rectangle(from: firstPoint, to: point)
            view.selection = region
            pendingRegion = region
        }
    }

    private func mouseMoved(in view: RegionSelectionView, point: CGPoint) {
        guard activeView === view, let firstPoint else { return }
        if mode == .drag && !view.isDragging { return }
        if pendingRegion != nil { return }
        view.selection = rectangle(from: firstPoint, to: view.clamped(point))
    }

    private func mouseUp(in view: RegionSelectionView, point: CGPoint) {
        guard activeView === view, let firstPoint else { return }
        let region: CGRect
        switch mode {
        case .drag:
            region = rectangle(from: firstPoint, to: view.clamped(point))
        case .twoPoints:
            guard let pendingRegion else { return }
            region = pendingRegion
        }
        pendingRegion = nil
        view.selection = region
        guard region.width >= 12, region.height >= 12 else {
            view.message = "选区太小，请选择宽高至少 12 点的矩形。按 Esc 可取消。"
            if mode == .drag {
                self.firstPoint = nil
                activeView = nil
                view.anchor = nil
            }
            return
        }
        guard let window = view.window else { return }
        let windowRect = view.convert(region, to: nil)
        let appKitRect = window.convertToScreen(windowRect)
        let quartzRect = CGRect(
            x: appKitRect.minX,
            y: primaryTop - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
        // 完整接收第二次点击 / 拖拽的 mouseUp 后才移除覆盖层。
        finish(quartzRect)
    }

    private func rectangle(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
               width: abs(first.x - second.x), height: abs(first.y - second.y))
    }

    private func finish(_ region: CGRect?) {
        let callback = completion
        completion = nil
        firstPoint = nil
        pendingRegion = nil
        activeView = nil
        let oldWindows = windows
        windows.removeAll()
        views.removeAll()
        oldWindows.forEach {
            $0.cancelAction = nil
            if let view = $0.contentView as? RegionSelectionView {
                view.onMouseDown = nil
                view.onMouseMoved = nil
                view.onMouseUp = nil
                view.onCancel = nil
            }
            $0.orderOut(nil)
            $0.close()
        }
        callback?(region)
    }

    deinit {
        let remainingWindows = windows
        DispatchQueue.main.async {
            remainingWindows.forEach {
                $0.orderOut(nil)
                $0.close()
            }
        }
    }
}

@MainActor
private final class RegionSelectionWindow: NSWindow {
    var cancelAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelAction?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class RegionSelectionView: NSView {
    var mode: ScreenRegionPicker.SelectionMode = .drag
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isDragging = false
    var selection: CGRect? { didSet { needsDisplay = true } }
    var anchor: CGPoint? { didSet { needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }
    private var movementTracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onMouseDown?(point(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseMoved?(point(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(point(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        onMouseUp?(point(for: event))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let movementTracking { removeTrackingArea(movementTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        movementTracking = area
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        NSColor.black.withAlphaComponent(0.48).setFill()
        if let selection, selection.width > 0, selection.height > 0 {
            let outside = [
                CGRect(x: 0, y: 0, width: bounds.width, height: selection.minY),
                CGRect(x: 0, y: selection.maxY, width: bounds.width, height: bounds.height - selection.maxY),
                CGRect(x: 0, y: selection.minY, width: selection.minX, height: selection.height),
                CGRect(x: selection.maxX, y: selection.minY, width: bounds.width - selection.maxX, height: selection.height)
            ]
            outside.forEach { NSBezierPath(rect: $0).fill() }
            NSColor.white.withAlphaComponent(0.02).setFill()
            NSBezierPath(rect: selection).fill()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            NSColor.systemGreen.setStroke()
            border.stroke()
            drawSize(selection)
        } else {
            NSBezierPath(rect: bounds).fill()
        }

        if let anchor {
            let mark = NSBezierPath()
            mark.move(to: CGPoint(x: anchor.x - 8, y: anchor.y))
            mark.line(to: CGPoint(x: anchor.x + 8, y: anchor.y))
            mark.move(to: CGPoint(x: anchor.x, y: anchor.y - 8))
            mark.line(to: CGPoint(x: anchor.x, y: anchor.y + 8))
            mark.lineWidth = 1.5
            NSColor.systemGreen.setStroke()
            mark.stroke()
        }
        drawInstructions()
    }

    private func drawInstructions() {
        let width = min(620, max(220, bounds.width - 32))
        let panel = CGRect(x: (bounds.width - width) / 2, y: 24, width: width, height: 108)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
        let title = mode == .drag ? "拖拽框选绘图区域" : "点选画布的两个对角"
        let detail = message ?? (mode == .drag
            ? "在同一显示器内拖出矩形，松开鼠标确认。"
            : "先点左上角，再点右下角；也可选择其他两个对角。")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (title as NSString).draw(in: panel.insetBy(dx: 12, dy: 14), withAttributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        (detail as NSString).draw(in: CGRect(x: panel.minX + 12, y: panel.minY + 48,
                                           width: panel.width - 24, height: 27), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: paragraph
        ])
        ("Esc 取消 · 坐标和尺寸以屏幕点为单位" as NSString).draw(
            in: CGRect(x: panel.minX + 12, y: panel.minY + 77, width: panel.width - 24, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.65),
                             .paragraphStyle: paragraph]
        )
    }

    private func drawSize(_ selection: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded())) 点"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let boxWidth = size.width + 20
        let x = min(max(8, selection.minX), max(8, bounds.width - boxWidth - 8))
        var y = selection.maxY + 8
        if y + 28 > bounds.maxY { y = max(8, selection.minY - 36) }
        let box = CGRect(x: x, y: y, width: boxWidth, height: 28)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: x + 10, y: y + 5), withAttributes: attributes)
    }
}

/// 只显示本机转换图，不读取屏幕；覆盖层不会接收鼠标，也不会抢夺目标窗口焦点。
@MainActor
final class CanvasPreviewOverlay {
    private var window: NSPanel?

    func show(image: CGImage, region: CGRect, opacity: Double = 0.4) {
        hide()
        guard let primaryScreen = NSScreen.screens.first,
              region.origin.x.isFinite, region.origin.y.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0 else { return }
        let appKitRect = CGRect(x: region.minX, y: primaryScreen.frame.maxY - region.maxY,
                               width: region.width, height: region.height)
        let panel = NSPanel(contentRect: appKitRect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.setFrame(appKitRect, display: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = opacity.isFinite ? min(1, max(0, opacity)) : 0.4
        let view = CanvasPreviewView(frame: CGRect(origin: .zero, size: region.size), image: image)
        panel.contentView = view
        window = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    deinit {
        let remainingWindow = window
        DispatchQueue.main.async {
            remainingWindow?.orderOut(nil)
            remainingWindow?.close()
        }
    }
}

@MainActor
private final class CanvasPreviewView: NSView {
    private let image: NSImage
    override var isFlipped: Bool { true }

    init(frame: CGRect, image: CGImage) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(rect: bounds).fill()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}
