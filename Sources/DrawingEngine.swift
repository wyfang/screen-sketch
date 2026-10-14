import AppKit
import ApplicationServices
import Darwin
import OSLog

enum DrawingTargetAvailability: Equatable {
    case alive, missing, changed
    case unconfirmed(Int32)
}

enum DrawingTransport: String, CaseIterable, Identifiable {
    case foreground = "前台鼠标"
    case background = "后台绘制（试验）"
    var id: String { rawValue }
}

// Button coordinates are absolute Quartz screen points. Stroke coordinates are
// normalized within their own rectangle, just like the original drawing API.
enum DrawingAction {
    case click(CGPoint)
    // A target window may consume its first click to activate. These are three
    // ordinary, separately settled clicks, never a double/triple-click event.
    case selectTool(CGPoint)
    case strokes(paths: [[CGPoint]], rect: CGRect, brushWidth: Double, minimumMovement: Double)
    case timedStrokes(paths: [[CGPoint]], rect: CGRect, brushWidth: Double, minimumMovement: Double, speed: Double)
    case profiledStrokes(paths: [[CGPoint]], rect: CGRect, brushWidth: Double, minimumMovement: Double,
                         speed: Double?, pressDelay: Double?, releaseDelay: Double?, endExtension: Double)
}

// Coordinates remain in Quartz global screen points, including negative origins.
final class DrawingEngine {
    var onUpdate: ((Double, String) -> Void)?
    var onFinish: ((Bool) -> Void)?
    var onPause: ((String) -> Void)?
    var speed: Double = 450
    var pressDelay: Double = 0.12
    var releaseDelay: Double = 0.12
    var minimumMovement: Double = 0
    private(set) var running = false
    private(set) var paused = false
    private(set) var hasImmediateInputGuard = false
    private var timer: Timer?
    private enum Operation {
        case click(CGPoint)
        case stroke([CGPoint], minimumMovement: Double, speed: Double?, pressDelay: Double?, releaseDelay: Double?)
    }
    private var operations: [Operation] = []
    private var transport: DrawingTransport = .foreground
    private var targetPID: pid_t?
    private var targetApplication: NSRunningApplication?
    private var source: CGEventSource?
    private var activity: NSObjectProtocol?
    private var stroke = 0
    private var vertex = 0
    private var position = CGPoint.zero
    private var pressed = false
    private enum Phase { case position, press, drawing, release, gap }
    private var phase: Phase = .position
    private var nextTime = 0.0
    private var lastTime = 0.0
    private var countdownEnd = 0.0
    private var monitorDuringCountdown = false
    private var movementBudget = 0.0
    private var movementBudgetSpeed = 0.0
    private var travelled = 0.0
    private var totalDistance = 0.0
    private var lastUIUpdate = -Double.infinity
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private static let eventMarker: Int64 = 0x53534B45544348
    private static let timerInterval = 1.0 / 250
    private static let targetLogger = Logger(subsystem: "com.wangyifang.screensketch", category: "DrawingTarget")
    // Tool UI events need human-length timing independently of drawing speed.
    private static let clickPositionDelay = 0.10
    private static let clickPressDelay = 0.10
    private static let clickSettleTime = 0.30
    private static let inputTypes: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved,
        .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
        .otherMouseDown, .otherMouseDragged, .scrollWheel]

    #if ENGINE_TESTS
    // The sink is the only production-input bypass; tests never install taps or post events.
    var testClock: Double?
    var testSink: ((CGEventType, CGPoint) -> Void)?
    var testTargetProbe: ((pid_t) -> DrawingTargetAvailability)?
    func testTick(at time: Double) { testClock = time; tick() }
    @discardableResult func testInput(_ type: CGEventType, keyCode: CGKeyCode = 0, marked: Bool = false) -> Bool {
        handleInput(type: type, keyCode: keyCode, marked: marked)
    }
    #endif
    private var clock: Double {
        #if ENGINE_TESTS
        if let testClock { return testClock }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    private var trusted: Bool {
        #if ENGINE_TESTS
        if testSink != nil { return true }
        #endif
        return AXIsProcessTrusted()
    }
    private var effectiveSpeed: Double {
        if operations.indices.contains(stroke), case .stroke(_, _, let fixedSpeed, _, _) = operations[stroke],
           let fixedSpeed { return fixedSpeed }
        return Self.validSpeed(speed)
    }
    private var effectivePressDelay: Double {
        if operations.indices.contains(stroke), case .stroke(_, _, _, let fixedDelay, _) = operations[stroke],
           let fixedDelay { return fixedDelay }
        return Self.holdDelay(pressDelay)
    }
    private var effectiveReleaseDelay: Double {
        if operations.indices.contains(stroke), case .stroke(_, _, _, _, let fixedDelay) = operations[stroke],
           let fixedDelay { return fixedDelay }
        return Self.holdDelay(releaseDelay)
    }
    // Calibration can refine below the normal UI range. Preserve every positive
    // finite candidate instead of silently drawing it at a faster speed.
    private static func validSpeed(_ speed: Double) -> Double { speed.isFinite && speed > 0 ? speed : 450 }
    private static func holdDelay(_ value: Double) -> Double {
        max(timerInterval, value.isFinite ? max(0, value) : 0.12)
    }
    private static func transitionDelay(_ speed: Double) -> Double {
        // A maximum of one injected event per timer tick, with slower tools allowed to settle.
        max(timerInterval, min(0.045, 6 / validSpeed(speed)))
    }

    deinit {
        release()
        removeInputGuard()
        timer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func installInputGuard() {
        #if ENGINE_TESTS
        if testSink != nil { return }
        #endif
        let mask = Self.inputTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<DrawingEngine>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = engine.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                if engine.running, !engine.paused, engine.transport == .foreground {
                    engine.pause(reason: "输入防护暂时中断，已暂停")
                }
                return Unmanaged.passUnretained(event)
            }
            return engine.handleEvent(event) ? nil : Unmanaged.passUnretained(event)
        }
        // Try the existing Accessibility authorization. Never request additional privacy access.
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                      userInfo: Unmanaged.passUnretained(self).toOpaque()),
           let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            eventTap = tap
            tapRunLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            hasImmediateInputGuard = true
            return
        }
        // A compatibility fallback can observe global events only after delivery; it still releases
        // immediately when observed. Local monitoring covers this tool's own control window.
        let eventMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
            .otherMouseDown, .otherMouseDragged, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            if let cgEvent = event.cgEvent { _ = self?.handleEvent(cgEvent) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let cgEvent = event.cgEvent else { return event }
            return self?.handleEvent(cgEvent) == true ? nil : event
        }
    }

    private func removeInputGuard() {
        if let tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
            self.tapRunLoopSource = nil
        }
        if let eventTap { CFMachPortInvalidate(eventTap); self.eventTap = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        hasImmediateInputGuard = false
    }

    private func handleEvent(_ event: CGEvent) -> Bool {
        handleInput(type: event.type,
                    keyCode: CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                    marked: event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker)
    }

    @discardableResult private func handleInput(type: CGEventType, keyCode: CGKeyCode, marked: Bool) -> Bool {
        guard running, !marked else { return false }
        if transport == .background {
            if type == .keyDown, keyCode == 53 { stop(); return true }
            return false
        }
        // Paused input always passes through. Only the Continue control can resume drawing.
        guard !paused, monitorDuringCountdown || clock >= countdownEnd,
              Self.inputTypes.contains(type) else { return false }
        let keyboard = type == .keyDown || type == .flagsChanged
        pause(reason: keyboard ? "检测到键盘操作，已暂停" : "检测到手动鼠标操作，已暂停")
        return true
    }

    static func mapPaths(_ strokes: [[CGPoint]], to rect: CGRect, brushWidth: Double) -> [[CGPoint]] {
        let margin = max(1, brushWidth / 2 + 1)
        guard rect.width > margin * 2, rect.height > margin * 2 else { return [] }
        let safe = rect.insetBy(dx: margin, dy: margin)
        return strokes.compactMap { path in
            guard !path.isEmpty, path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            return path.map { CGPoint(x: min(safe.maxX, max(safe.minX, rect.minX + $0.x * rect.width)),
                                      y: min(safe.maxY, max(safe.minY, rect.minY + $0.y * rect.height))) }
        }
    }

    /// Absolute screen-point paths, with an optional extra terminal vertex.
    /// The original endpoint remains a vertex so it is always delivered before
    /// compensation. Bound the extension along its vector instead of clamping
    /// x/y independently, which would change the final segment's direction.
    static func compensatedPaths(_ paths: [[CGPoint]], to rect: CGRect, brushWidth: Double,
                                 endExtension: Double) -> [[CGPoint]] {
        let mapped = mapPaths(paths, to: rect, brushWidth: brushWidth)
        guard endExtension.isFinite, endExtension > 0 else { return mapped }
        let margin = max(1, brushWidth / 2 + 1)
        let safe = rect.insetBy(dx: margin, dy: margin)
        return mapped.map { path in
            guard let end = path.last,
                  let segment = zip(path, path.dropFirst()).reversed().first(where: { $0.0 != $0.1 }) else {
                return path
            }
            let distance = hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
            guard distance.isFinite, distance > 0 else { return path }
            let dx = (segment.1.x - segment.0.x) / distance
            let dy = (segment.1.y - segment.0.y) / distance
            var length = endExtension
            if dx > 0 { length = min(length, (safe.maxX - end.x) / dx) }
            else if dx < 0 { length = min(length, (safe.minX - end.x) / dx) }
            if dy > 0 { length = min(length, (safe.maxY - end.y) / dy) }
            else if dy < 0 { length = min(length, (safe.minY - end.y) / dy) }
            guard length.isFinite, length > 0 else { return path }
            // A rounded boundary calculation may land one ULP outside. Reduce
            // the same scalar, keeping the vector and safe boundary intact.
            for _ in 0..<4 {
                let extended = CGPoint(x: end.x + dx * length, y: end.y + dy * length)
                if extended.x >= safe.minX, extended.x <= safe.maxX,
                   extended.y >= safe.minY, extended.y <= safe.maxY {
                    return extended == end ? path : path + [extended]
                }
                length = length.nextDown
                if length <= 0 { break }
            }
            return path
        }
    }

    static func estimateSeconds(paths: [[CGPoint]], rect: CGRect, brushWidth: Double,
                                speed: Double, minimumMovement: Double = 0,
                                pressDelay: Double = 0.12, releaseDelay: Double = 0.12,
                                endExtension: Double = 0) -> Double {
        let mapped = compensatedPaths(paths, to: rect, brushWidth: brushWidth, endExtension: endExtension)
        let speed = validSpeed(speed)
        let minimum = minimumMovement.isFinite ? max(0, minimumMovement) : 0
        let travelPerTick = speed * timerInterval
        guard travelPerTick.isFinite, travelPerTick > 0 else { return .infinity }
        let packetTicks = max(1, ceil(minimum / travelPerTick))
        guard packetTicks.isFinite else { return .infinity }
        let packetDistance = min(packetTicks * travelPerTick, max(minimum, speed * 0.05))
        let delay = ceil(transitionDelay(speed) / timerInterval) * timerInterval
        let holds = ceil(holdDelay(pressDelay) / timerInterval) * timerInterval
            + ceil(holdDelay(releaseDelay) / timerInterval) * timerInterval
        return mapped.reduce(3.0) { total, path in
            let distances = zip(path, path.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            // Each real vertex ends a packet and discards unused travel. Sum
            // timer-quantized waits per segment instead of banking short-segment
            // time against a longer segment in the duration estimate.
            let ticks = distances.reduce(0.0) { ticks, distance in
                guard distance > 0 else { return ticks }
                let full = floor(distance / packetDistance)
                guard full.isFinite else { return .infinity }
                let remainder = max(0, distance - full * packetDistance)
                return ticks + full * packetTicks + ceil(remainder / travelPerTick)
            }
            return total + max(1, ticks) * timerInterval + delay * 2 + holds
        }
    }

    func start(paths strokes: [[CGPoint]], rect: CGRect, brushWidth: Double,
               transport: DrawingTransport, targetPID: pid_t?, countdown: Double = 3,
               endExtension: Double = 0) -> Bool {
        start(actions: [.profiledStrokes(paths: strokes, rect: rect, brushWidth: brushWidth,
                                        minimumMovement: minimumMovement, speed: nil,
                                        pressDelay: nil, releaseDelay: nil, endExtension: endExtension)],
              transport: transport, targetPID: targetPID, countdown: countdown)
    }

    func start(actions: [DrawingAction], transport: DrawingTransport,
               targetPID: pid_t?, countdown: Double = 3) -> Bool {
        guard !running, trusted,
              transport == .foreground || targetPID.map({ $0 > 0 }) == true else { return false }
        var prepared: [Operation] = []
        for action in actions {
            switch action {
            case .click(let point), .selectTool(let point):
                guard point.x.isFinite, point.y.isFinite else { return false }
                let clickCount: Int
                if case .selectTool = action { clickCount = 3 } else { clickCount = 1 }
                prepared += Array(repeating: .click(point), count: clickCount)
            case .strokes(let strokes, let rect, let brushWidth, let minimum):
                let movement = minimum.isFinite ? max(0, minimum) : 0
                prepared += Self.mapPaths(strokes, to: rect, brushWidth: brushWidth).map {
                    .stroke($0, minimumMovement: movement, speed: nil, pressDelay: nil, releaseDelay: nil)
                }
            case .timedStrokes(let strokes, let rect, let brushWidth, let minimum, let speed):
                let movement = minimum.isFinite ? max(0, minimum) : 0
                let fixedSpeed = Self.validSpeed(speed)
                prepared += Self.mapPaths(strokes, to: rect, brushWidth: brushWidth).map {
                    .stroke($0, minimumMovement: movement, speed: fixedSpeed, pressDelay: nil, releaseDelay: nil)
                }
            case .profiledStrokes(let strokes, let rect, let brushWidth, let minimum,
                                  let speed, let pressDelay, let releaseDelay, let extensionLength):
                let movement = minimum.isFinite ? max(0, minimum) : 0
                let fixedSpeed = speed.map(Self.validSpeed)
                let fixedPressDelay = pressDelay.map(Self.holdDelay)
                let fixedReleaseDelay = releaseDelay.map(Self.holdDelay)
                prepared += Self.compensatedPaths(strokes, to: rect, brushWidth: brushWidth,
                                                  endExtension: extensionLength).map {
                    .stroke($0, minimumMovement: movement, speed: fixedSpeed,
                            pressDelay: fixedPressDelay, releaseDelay: fixedReleaseDelay)
                }
            }
        }
        guard !prepared.isEmpty else { return false }
        operations = prepared
        self.transport = transport
        // Foreground input addresses screen coordinates, not a process. It must
        // not depend on LaunchServices, PID lifetime, or frontmost-app identity.
        self.targetPID = transport == .background ? targetPID : nil
        // Keep the original application instance when available. A fresh
        // LaunchServices lookup can be nil while the OS process is still alive.
        targetApplication = self.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        source = CGEventSource(stateID: .privateState)
        guard source != nil else { return false }
        // Let genuine hardware input reach the guard instead of suppressing it during our drag.
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents], state: .eventSuppressionStateRemoteMouseDrag)
        stroke = 0; vertex = 0; travelled = 0; pressed = false; phase = .position; paused = false
        movementBudget = 0; monitorDuringCountdown = false; lastUIUpdate = -Double.infinity
        pendingClickSettleUntil = 0
        totalDistance = operations.reduce(0) { total, operation in
            guard case .stroke(let path, _, _, _, _) = operation else { return total }
            return total + zip(path, path.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        running = true
        countdownEnd = clock + max(0, countdown)
        lastTime = countdownEnd
        nextTime = countdownEnd
        installInputGuard()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "按笔画绘图")
        #if ENGINE_TESTS
        if testSink == nil { installTimer() }
        #else
        installTimer()
        #endif
        let guardNote = transport == .foreground && !hasImmediateInputGuard ? "（兼容监听无法预先拦截其他程序收到的输入）" : ""
        onUpdate?(0, "准备绘制，前台开始后任意键或鼠标操作会暂停" + guardNote)
        return true
    }

    private func installTimer() {
        timer = Timer(timeInterval: Self.timerInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func pause(reason: String = "已暂停") {
        guard running, !paused else { return }
        paused = true
        release()
        movementBudget = 0
        switch phase {
        case .press, .drawing: phase = .position // Keep position and vertex; reposition before a fresh down.
        case .release:
            // Both a completed stroke and a button down have already been delivered.
            // release() above completes the click; resuming must never click a toggle twice.
            phase = .gap
            if currentIsClick {
                pendingClickSettleUntil = clock + Self.clickSettleTime
                nextTime = pendingClickSettleUntil
            }
        default: break
        }
        let message = reason + " · 请点击工具中的“继续”"
        onUpdate?(progress, message)
        onPause?(message)
    }

    func resume(countdown: Double = 1) {
        guard running, paused else { return }
        paused = false
        monitorDuringCountdown = true
        movementBudget = 0
        countdownEnd = clock + max(0, countdown)
        lastTime = countdownEnd
        nextTime = countdownEnd
        onUpdate?(progress, "准备继续，请保持画板位置不变")
    }

    func togglePause() { paused ? resume() : pause() }
    func stop() { finish(completed: false) }

    private var progress: Double {
        guard !operations.isEmpty else { return 0 }
        let byStrokes = Double(stroke) / Double(operations.count)
        return min(1, totalDistance > 0 ? (travelled / totalDistance * 0.6 + byStrokes * 0.4) : byStrokes)
    }

    private var currentIsClick: Bool {
        guard operations.indices.contains(stroke) else { return false }
        if case .click = operations[stroke] { return true }
        return false
    }

    // A resume countdown may be zero. Preserve the remainder of a button's
    // settling interval even in that case, including when pause sent its mouse-up.
    private var pendingClickSettleUntil = 0.0

    @discardableResult private func post(_ type: CGEventType, at point: CGPoint) -> Bool {
        #if ENGINE_TESTS
        if let testSink { testSink(type, point); return true }
        #endif
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return false }
        event.setIntegerValueField(.mouseEventClickState, value: type == .leftMouseDown || type == .leftMouseUp ? 1 : 0)
        event.setIntegerValueField(.mouseEventNumber, value: Int64(stroke + 1))
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        if type == .mouseMoved || type == .leftMouseDragged {
            event.flags.insert(.maskNonCoalesced)
        }
        event.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
        if transport == .background, let targetPID {
            // Process-directed delivery is best effort. It does not create a second system pointer.
            event.postToPid(targetPID)
        } else { event.post(tap: .cghidEventTap) }
        return true
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        if !post(.leftMouseUp, at: position) { pressed = true }
    }

    static func targetAvailability(signalResult: Int32, signalError: Int32) -> DrawingTargetAvailability {
        if signalResult == 0 || signalError == EPERM { return .alive }
        if signalError == ESRCH { return .missing }
        return .unconfirmed(signalError)
    }
    private func probeTarget(_ pid: pid_t) -> DrawingTargetAvailability {
        #if ENGINE_TESTS
        if let testTargetProbe { return testTargetProbe(pid) }
        #endif
        guard pid > 0 else { return .missing }
        errno = 0
        let result = Darwin.kill(pid, 0)
        let state = Self.targetAvailability(signalResult: result, signalError: errno)
        // A terminated original instance with a now-live PID can indicate PID
        // reuse. It is not authorization to draw into that replacement process.
        if state == .alive, targetApplication?.isTerminated == true { return .changed }
        return state
    }

    private func tick() {
        guard running, !paused else { return }
        let now = clock
        #if ENGINE_TESTS
        let checkingRealTarget = testSink == nil || testTargetProbe != nil
        #else
        let checkingRealTarget = true
        #endif
        if checkingRealTarget, transport == .background, let targetPID {
            let state = probeTarget(targetPID)
            switch state {
            case .alive: break
            case .missing:
                Self.targetLogger.warning("Target PID unavailable pid=\(targetPID, privacy: .public)")
                pause(reason: "暂时找不到目标进程，已暂停并保留进度"); return
            case .changed:
                Self.targetLogger.warning("Original target instance ended but PID is live pid=\(targetPID, privacy: .public)")
                pause(reason: "目标进程已改变，已暂停并保留进度；请核对原画布"); return
            case .unconfirmed(let error):
                Self.targetLogger.warning("Target PID check uncertain pid=\(targetPID, privacy: .public) errno=\(error, privacy: .public)")
                pause(reason: "暂时无法确认目标进程，已暂停并保留进度"); return
            }
        }
        guard now >= countdownEnd else {
            lastTime = now
            report("\(Int(ceil(countdownEnd - now))) 秒后\(monitorDuringCountdown ? "继续" : "开始")")
            return
        }
        let elapsed = min(0.05, max(0, now - lastTime))
        lastTime = now
        guard now >= nextTime, now >= pendingClickSettleUntil else { return }
        guard stroke < operations.count else { finish(completed: true); return }
        let path: [CGPoint]
        let movementMinimum: Double
        let clicking: Bool
        switch operations[stroke] {
        case .click(let point): path = [point]; movementMinimum = 0; clicking = true
        case .stroke(let points, let minimum, _, _, _): path = points; movementMinimum = minimum; clicking = false
        }
        let delay = Self.transitionDelay(effectiveSpeed)
        switch phase {
        case .position:
            if vertex == 0 { position = path[0]; vertex = 1 }
            // Also executed on resume: never draw a connection from the user's relocated cursor.
            phase = .press
            if transport == .foreground || clicking {
                guard post(.mouseMoved, at: position) else { finish(completed: false); return }
            }
            guard running, !paused else { return }
            nextTime = now + (clicking ? Self.clickPositionDelay : delay)
        case .press:
            pressed = true
            movementBudget = 0
            phase = clicking ? .release : .drawing
            guard post(.leftMouseDown, at: position) else { pressed = false; finish(completed: false); return }
            // A test sink or a reentrant event callback may pause/stop as the down is delivered.
            guard running, !paused else { return }
            nextTime = now + (clicking ? Self.clickPressDelay : effectivePressDelay)
        case .drawing:
            let minimum = movementMinimum
            let speed = effectiveSpeed
            // A live speed change cannot spend travel accumulated at the old rate.
            // Fixed-speed calibration actions still use their own unchanged rate.
            if movementBudgetSpeed != speed {
                movementBudget = 0
                movementBudgetSpeed = speed
            }
            movementBudget = min(max(minimum, speed * 0.05), movementBudget + speed * elapsed)
            // Skip coincident vertices, but never skip genuine corners or combine separate strokes.
            while vertex < path.count, path[vertex] == position {
                vertex += 1
            }
            if vertex >= path.count {
                // A single point or a path made only of repeated points still needs one drag
                // for canvases that paint exclusively on mouseDragged.
                phase = .release
                guard post(.leftMouseDragged, at: position) else { finish(completed: false); return }
                guard running, !paused else { return }
                nextTime = now + effectiveReleaseDelay
                break
            }
            let end = path[vertex]
            let distance = hypot(end.x - position.x, end.y - position.y)
            // Wait for enough travel to avoid tiny per-tick steps. A shorter corner or final tail
            // is sent exactly to its existing endpoint, keeping the original path and white gaps.
            let required = min(distance, minimum)
            guard movementBudget >= required, movementBudget > 0 else { break }
            let step = min(movementBudget, distance)
            let fraction = step / distance
            position = step >= distance ? end : CGPoint(x: position.x + (end.x - position.x) * fraction,
                                                        y: position.y + (end.y - position.y) * fraction)
            travelled += step
            // Credit is only for waiting to reach the next minimum movement.
            // Never carry unused credit past a delivered corner: many short fill
            // vertices would bank it and turn the next long segment into a burst.
            movementBudget = 0
            if step >= distance { vertex += 1 }
            if vertex >= path.count { phase = .release; nextTime = now + effectiveReleaseDelay }
            guard post(.leftMouseDragged, at: position) else { finish(completed: false); return }
            guard running, !paused else { return }
        case .release:
            release()
            guard !pressed else { finish(completed: false); return }
            if clicking {
                pendingClickSettleUntil = now + Self.clickSettleTime
                phase = .gap; nextTime = pendingClickSettleUntil
            } else {
                if stroke == operations.count - 1 { finish(completed: true); return }
                phase = .gap; nextTime = now + delay
            }
        case .gap:
            stroke += 1; vertex = 0; phase = .position; movementBudget = 0
            if stroke >= operations.count { finish(completed: true); return }
            switch operations[stroke] {
            case .click(let point): position = point
            case .stroke(let path, _, _, _, _): position = path[0]
            }
            vertex = 1
            phase = .press
            if transport == .foreground || currentIsClick {
                guard post(.mouseMoved, at: position) else { finish(completed: false); return }
            }
            guard running, !paused else { return }
            nextTime = now + (currentIsClick ? Self.clickPositionDelay : Self.transitionDelay(effectiveSpeed))
        }
        report("执行 \(min(stroke + 1, operations.count)) / \(operations.count) 步 · \(transport == .foreground ? "任意键或鼠标操作暂停" : "Esc 停止")")
    }

    private func report(_ status: String) {
        guard clock - lastUIUpdate >= 0.1 else { return }
        lastUIUpdate = clock
        onUpdate?(progress, status)
    }

    private func finish(completed: Bool) {
        guard running else { return }
        release()
        timer?.invalidate(); timer = nil
        running = false; paused = false
        targetApplication = nil
        removeInputGuard()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        onUpdate?(completed ? 1 : progress, completed ? (transport == .background ? "笔画发送完成，请检查目标画板" : "绘制完成") : "绘制已停止")
        onFinish?(completed)
    }
}
