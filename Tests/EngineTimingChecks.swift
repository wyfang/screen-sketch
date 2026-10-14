import AppKit
import ApplicationServices

@main struct EngineTimingChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    static let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

    final class Harness {
        let engine = DrawingEngine()
        var events: [Event] = []
        var time = 0.0
        var afterEvent: ((Event) -> Void)?
        init() {
            engine.testClock = 0
            engine.testSink = { [weak self] type, point in
                guard let self else { return }
                let event = Event(type: type, point: point, time: self.time)
                self.events.append(event)
                require(!self.engine.testInput(type, marked: true), "自身事件不能暂停绘制")
                self.afterEvent?(event)
            }
        }
        func start(_ actions: [DrawingAction]) {
            require(engine.start(actions: actions, transport: .foreground, targetPID: nil, countdown: 0), "测试动作应启动")
        }
        func tick() { time += 0.004; engine.testTick(at: time) }
        func advance(until condition: () -> Bool) {
            for _ in 0..<25000 { if condition() { return }; tick() }
            fatalError("测试虚拟时钟不应停滞")
        }
        func finish() { advance { !engine.running } }
    }

    static func line(y: Double = 0.2) -> [CGPoint] {
        [CGPoint(x: 0.2, y: y), CGPoint(x: 0.35, y: y)]
    }
    static func action(y: Double = 0.2) -> DrawingAction {
        .strokes(paths: [line(y: y)], rect: rect, brushWidth: 2, minimumMovement: 0)
    }
    static func strokeEvents(_ h: Harness, y: Double) -> [Event] {
        h.events.filter { abs($0.point.y - rect.height * y) < 0.000001 && $0.type != .mouseMoved }
    }
    static func checkHolds(_ events: [Event], press: Double, release: Double) {
        let down = events.first { $0.type == .leftMouseDown }!
        let firstDrag = events.first { $0.type == .leftMouseDragged }!
        let lastDrag = events.last { $0.type == .leftMouseDragged }!
        let up = events.first { $0.type == .leftMouseUp }!
        require(firstDrag.time - down.time >= press - 0.000001, "首个拖动前必须完整等待按下延迟")
        require(up.time - lastDrag.time >= release - 0.000001, "终点拖动后必须完整等待释放延迟")
        require(up.point == lastDrag.point, "结束停留不能移动已画好的终点")
    }

    static func main() {
        for speed in [60.0, 300, 8000] {
            let h = Harness(); h.engine.speed = speed
            h.start([action()]); h.finish()
            checkHolds(h.events, press: 0.12, release: 0.12)
            let configured = Harness(); configured.engine.speed = speed
            configured.engine.pressDelay = 0.24; configured.engine.releaseDelay = 0.18
            configured.start([action()]); configured.finish()
            checkHolds(configured.events, press: 0.24, release: 0.18)
        }

        // Interrupting either hold releases immediately. Resume performs a fresh
        // reposition/down sequence and starts a full new press hold.
        let resumed = Harness(); resumed.engine.speed = 8000
        resumed.start([action()])
        resumed.advance { resumed.events.last?.type == .leftMouseDown }
        let firstDownTime = resumed.time
        for _ in 0..<8 { resumed.tick() }
        require(resumed.events.last?.type == .leftMouseDown, "测试应仍处于按下停留阶段")
        require(resumed.engine.testInput(.keyDown) && resumed.engine.paused, "按下停留时键盘输入应暂停")
        require(resumed.events.last?.type == .leftMouseUp && resumed.events.last!.time < firstDownTime + 0.12, "暂停不能等到停留结束再释放")
        let pausedCount = resumed.events.count
        for _ in 0..<50 { resumed.tick() }
        require(resumed.events.count == pausedCount, "暂停时不应有任何未来输入")
        resumed.engine.resume(countdown: 0); resumed.finish()
        let remainder = Array(resumed.events.dropFirst(pausedCount))
        require(remainder.first?.type == .mouseMoved, "恢复应先重新定位")
        checkHolds(remainder, press: 0.12, release: 0.12)

        for edge in [CGEventType.leftMouseDown, .leftMouseDragged] {
            let stopped = Harness(); stopped.engine.speed = 8000
            stopped.start([action()])
            stopped.advance {
                stopped.events.last?.type == edge
                    && (edge == .leftMouseDown || abs(stopped.events.last!.point.x - 210) < 0.000001)
            }
            let stopTime = stopped.time
            stopped.engine.stop()
            require(stopped.events.last?.type == .leftMouseUp && stopped.events.last!.time == stopTime, "停止必须立即释放，不能继续等待按下或释放停留")
            let count = stopped.events.count
            for _ in 0..<200 { stopped.tick() }
            require(stopped.events.count == count && !stopped.engine.running, "停止后不应继续绘制")
        }

        // Tool clicks retain their own move/hold/settle timings at every speed,
        // independently of both zero and much longer drawing holds.
        for speed in [60.0, 300, 8000] {
            for hold in [0.0, 2] {
                let button = Harness(); button.engine.speed = speed
                button.engine.pressDelay = hold; button.engine.releaseDelay = hold
                button.start([.click(CGPoint(x: -100, y: -100))]); button.finish()
                require(button.events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp], "按钮点击不能插入绘制拖动")
                let buttonMove = button.events[0]; let buttonDown = button.events[1]; let buttonUp = button.events[2]
                let moveDelay = buttonDown.time - buttonMove.time
                let pressDelay = buttonUp.time - buttonDown.time
                require(moveDelay >= 0.10 - 0.000001 && moveDelay <= 0.104 + 0.000001,
                        "按钮移动后必须固定等待100毫秒，与绘制速度及停留无关")
                require(pressDelay >= 0.10 - 0.000001 && pressDelay <= 0.104 + 0.000001,
                        "按钮必须固定按住100毫秒，与绘制速度及停留无关")
                require(button.time - buttonUp.time >= 0.30 - 0.000001, "按钮释放后应等待至少300毫秒")
                require(button.time < 0.52, "绘制停留设置不能拖长工具按钮自己的固定等待")
            }
        }

        // Candidate speeds remain fixed even when the global drawing speed changes.
        // The following ordinary stroke reads the new global speed instead of
        // inheriting the previous candidate's fixed speed.
        let fixed = Harness(); fixed.engine.speed = 450
        fixed.afterEvent = { [weak fixed] event in
            guard event.type == .leftMouseDown else { return }
            if abs(event.point.y - 80) < 0.000001 { fixed?.engine.speed = 8000 }
            if abs(event.point.y - 160) < 0.000001 { fixed?.engine.speed = 600 }
        }
        fixed.start([
            .timedStrokes(paths: [line(y: 0.2)], rect: rect, brushWidth: 2, minimumMovement: 0, speed: 60),
            .timedStrokes(paths: [line(y: 0.4)], rect: rect, brushWidth: 2, minimumMovement: 0, speed: 8000),
            action(y: 0.6)
        ])
        fixed.finish()
        func travelTime(y: Double) -> Double {
            let drags = strokeEvents(fixed, y: y).filter { $0.type == .leftMouseDragged }
            return drags.last!.time - drags.first!.time
        }
        require(travelTime(y: 0.2) > 1.4, "低速候选不能被新的全局8000速度覆盖")
        require(travelTime(y: 0.4) < 0.025, "高速候选不能被新的全局600速度覆盖")
        require(travelTime(y: 0.6) > 0.12 && travelTime(y: 0.6) < 0.18, "下一普通笔画应使用全局600速度，不能泄漏候选8000速度")
        for y in [0.2, 0.4, 0.6] { checkHolds(strokeEvents(fixed, y: y), press: 0.12, release: 0.12) }

        // Continued refinement can produce speeds below the normal speed control
        // range. The candidate and its duration estimate must retain that value.
        let belowRange = Harness(); belowRange.engine.speed = 8000
        belowRange.start([.timedStrokes(paths: [line()], rect: rect, brushWidth: 2, minimumMovement: 0, speed: 10)])
        belowRange.finish()
        let slowDrags = belowRange.events.filter { $0.type == .leftMouseDragged }
        require(slowDrags.last!.time - slowDrags.first!.time > 8.9, "10点每秒候选不可被悄悄提升到20点每秒")
        let slowEstimate = DrawingEngine.estimateSeconds(paths: [line()], rect: rect, brushWidth: 2, speed: 10)
        require(slowEstimate > 12, "低于控制范围的候选预计耗时也应使用真实10点每秒")
        checkHolds(belowRange.events, press: 0.12, release: 0.12)

        // A real displacement remains real at every representable refinement,
        // including distances smaller than the previous geometric tolerance.
        let tinyPath = [CGPoint(x: 0.2, y: 0.2),
                        CGPoint(x: 0.2 + 0.0002 / rect.width, y: 0.2),
                        CGPoint(x: 0.2 + 0.0004 / rect.width, y: 0.2)]
        let exactTiny = DrawingEngine.mapPaths([tinyPath], to: rect, brushWidth: 2)[0]
        let tinyAction = DrawingAction.timedStrokes(paths: [tinyPath], rect: rect, brushWidth: 2,
                                                  minimumMovement: 0.0004, speed: 8000)
        let tiny = Harness(); tiny.start([tinyAction]); tiny.finish()
        let tinyDrags = tiny.events.filter { $0.type == .leftMouseDragged }
        require(tinyDrags.map(\.point) == Array(exactTiny.dropFirst()), "小于0.001点的候选与转折必须逐点精确绘制")
        require(tinyDrags.allSatisfy { $0.point != exactTiny[0] }, "真实微小位移不能被处理成零长度拖动")
        checkHolds(tiny.events, press: 0.12, release: 0.12)

        let tinyResume = Harness(); tinyResume.start([tinyAction])
        tinyResume.advance { tinyResume.events.last?.type == .leftMouseDown }
        tinyResume.engine.pause(); tinyResume.engine.resume(countdown: 0); tinyResume.finish()
        require(tinyResume.events.filter { $0.type == .leftMouseDragged }.map(\.point) == Array(exactTiny.dropFirst()), "微小候选在按下暂停后恢复也必须保留精确位移")
        let tinyEndpoint = Harness(); tinyEndpoint.start([tinyAction])
        tinyEndpoint.advance { tinyEndpoint.events.last?.type == .leftMouseDragged && tinyEndpoint.events.last!.point == exactTiny.last! }
        let endpointDragCount = tinyEndpoint.events.filter { $0.type == .leftMouseDragged }.count
        tinyEndpoint.engine.pause(); tinyEndpoint.engine.resume(countdown: 0); tinyEndpoint.finish()
        require(tinyEndpoint.events.filter { $0.type == .leftMouseDragged }.count == endpointDragCount,
                "微小候选到终点后的暂停恢复不可添加新的点")
        require(tinyEndpoint.events.filter { $0.type == .leftMouseDown }.count == 1 && tinyEndpoint.events.last?.type == .leftMouseUp,
                "终点暂停应立即释放且不重复按下")

        let paths = [line(), line(y: 0.4), line(y: 0.6)]
        let noHolds = DrawingEngine.estimateSeconds(paths: paths, rect: rect, brushWidth: 2, speed: 8000,
                                                   pressDelay: 0, releaseDelay: 0)
        let defaultHolds = DrawingEngine.estimateSeconds(paths: paths, rect: rect, brushWidth: 2, speed: 8000)
        require(abs(defaultHolds - noHolds - Double(paths.count) * (0.24 - 0.008)) < 0.000001, "预计耗时应计入每笔按下和松开停留")
        let invalidHolds = Harness(); invalidHolds.engine.pressDelay = .nan; invalidHolds.engine.releaseDelay = .infinity
        invalidHolds.start([action()]); invalidHolds.finish()
        checkHolds(invalidHolds.events, press: 0.12, release: 0.12)
        print("PASS speed-independent press/release holds / custom holds / fresh hold after resume / immediate stop during either hold / fixed 100ms move and hold + 300ms settle clicks independent of speed and stroke holds / fixed per-action speeds without leakage / exact 10-point speed / sub-0.001-point candidates and resume / no repeat at tiny endpoint / estimates include holds / invalid delay fallback")
    }
}
