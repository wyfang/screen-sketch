import AppKit

/// 记录目标软件工具按钮的 Quartz 全局屏幕点，不读取屏幕图像。
@MainActor
final class ScreenPointPicker {
    private var windows: [PointSelectionWindow] = []
    private var views: [PointSelectionView] = []
    private var completion: ((CGPoint?) -> Void)?
    private var primaryTop: CGFloat = 0
    private weak var pressedView: PointSelectionView?
    private var cancellationRequested = false

    func begin(prompt: String, completion: @escaping (CGPoint?) -> Void) {
        // 上一次按下尚未松开时保留覆盖层，避免鼠标释放落到目标画布。
        if pressedView != nil {
            cancel()
            completion(nil)
            return
        }
        cancel()
        guard let primaryScreen = NSScreen.screens.first else {
            completion(nil)
            return
        }

        primaryTop = primaryScreen.frame.maxY
        self.completion = completion
        for screen in NSScreen.screens {
            let window = PointSelectionWindow(contentRect: screen.frame,
                                              styleMask: .borderless, backing: .buffered,
                                              defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.acceptsMouseMovedEvents = true
            window.cancelAction = { [weak self] in self?.cancel() }

            let view = PointSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.prompt = prompt
            view.onMouseDown = { [weak self, weak view] in
                guard let self, let view else { return }
                self.pressedView = view
                view.window?.makeKey()
                view.window?.makeFirstResponder(view)
            }
            view.onMouseUp = { [weak self, weak view] point in
                guard let self, let view, self.pressedView === view,
                      let window = view.window else { return }
                if self.cancellationRequested {
                    self.finish(nil)
                    return
                }
                let local = view.convert(point, to: nil)
                let screenPoint = window.convertToScreen(CGRect(origin: local, size: .zero)).origin
                // 同一次点击的 mouseUp 已由覆盖层接收，才移除窗口；目标软件不会收到该点击。
                self.finish(Self.quartzPoint(fromAppKit: screenPoint, primaryTop: self.primaryTop))
            }
            view.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWindow?.makeKey()
        if let view = keyWindow?.contentView { keyWindow?.makeFirstResponder(view) }
    }

    func cancel() {
        if pressedView != nil {
            cancellationRequested = true
            views.forEach { $0.prompt = "已取消选点，松开鼠标后退出" }
            return
        }
        finish(nil)
    }

    /// AppKit 的全局坐标向上为正；Quartz 向下为正。坐标单位始终是屏幕点。
    nonisolated static func quartzPoint(fromAppKit point: CGPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    private func finish(_ point: CGPoint?) {
        let callback = completion
        completion = nil
        pressedView = nil
        cancellationRequested = false
        let oldWindows = windows
        windows.removeAll()
        views.removeAll()
        oldWindows.forEach { window in
            window.cancelAction = nil
            if let view = window.contentView as? PointSelectionView {
                view.onMouseDown = nil
                view.onMouseUp = nil
                view.onCancel = nil
            }
            window.orderOut(nil)
            window.close()
        }
        callback?(point)
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
private final class PointSelectionWindow: NSWindow {
    var cancelAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelAction?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class PointSelectionView: NSView {
    var prompt = "点选工具按钮" { didSet { needsDisplay = true } }
    var onMouseDown: (() -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var hoverPoint: CGPoint? { didSet { needsDisplay = true } }
    private var movementTracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        onMouseDown?()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 拖出当前屏幕也只记录同一覆盖层的边界，不把事件传给下层画布。
        onMouseUp?(CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                           y: min(max(point.y, bounds.minY), bounds.maxY)))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
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
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: bounds).fill()

        if let hoverPoint {
            let mark = NSBezierPath()
            mark.move(to: CGPoint(x: hoverPoint.x - 9, y: hoverPoint.y))
            mark.line(to: CGPoint(x: hoverPoint.x + 9, y: hoverPoint.y))
            mark.move(to: CGPoint(x: hoverPoint.x, y: hoverPoint.y - 9))
            mark.line(to: CGPoint(x: hoverPoint.x, y: hoverPoint.y + 9))
            mark.lineWidth = 1.5
            NSColor.systemGreen.setStroke()
            mark.stroke()
        }

        let width = min(620, max(220, bounds.width - 32))
        let panel = CGRect(x: (bounds.width - width) / 2, y: 24, width: width, height: 96)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (prompt as NSString).draw(in: CGRect(x: panel.minX + 12, y: panel.minY + 12,
                                            width: panel.width - 24, height: 32), withAttributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        ("在目标按钮中心点击并松开鼠标。此点击只记录位置。" as NSString).draw(
            in: CGRect(x: panel.minX + 12, y: panel.minY + 46, width: panel.width - 24, height: 22),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                             .paragraphStyle: paragraph])
        ("Esc 取消 · 移动窗口或工具栏后请重新指定" as NSString).draw(
            in: CGRect(x: panel.minX + 12, y: panel.minY + 71, width: panel.width - 24, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.65),
                             .paragraphStyle: paragraph])
    }
}
