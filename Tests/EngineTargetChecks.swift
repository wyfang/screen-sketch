import AppKit
import ApplicationServices
import Darwin

@main struct EngineTargetChecks {
    struct Event { let type: CGEventType; let point: CGPoint }
    final class Harness {
        let engine = DrawingEngine()
        var events: [Event] = []
        var finishes: [Bool] = []
        var state = DrawingTargetAvailability.alive
        var probes = 0
        var time = 0.0
        init() {
            engine.testClock = 0; engine.speed = 60; engine.minimumMovement = 3
            engine.testSink = { [weak self] type, point in
                self?.events.append(Event(type: type, point: point))
            }
            engine.onFinish = { [weak self] in self?.finishes.append($0) }
            engine.testTargetProbe = { [weak self] _ in
                self?.probes += 1; return self?.state ?? .missing
            }
        }
        func start(_ transport: DrawingTransport, pid: pid_t?) -> Bool {
            engine.start(paths: [[CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.3)]],
                         rect: CGRect(x: 0, y: 0, width: 300, height: 200), brushWidth: 1,
                         transport: transport, targetPID: pid, countdown: 0)
        }
        func tick() { time += 0.004; engine.testTick(at: time) }
        func advance(until condition: () -> Bool) {
            for _ in 0..<30_000 { if condition() { return }; tick() }
            fatalError("目标检查测试应完成")
        }
        func finish() { advance { !engine.running } }
    }

    static func main() {
        // Foreground is intentionally process-independent: even a missing or
        // invalid provided PID and a failing probe cannot halt screen input.
        for pid: pid_t? in [nil, -1, 0, 999_999] {
            for state in [DrawingTargetAvailability.missing, .unconfirmed(EIO), .changed] {
                let h = Harness(); h.state = state
                precondition(h.start(.foreground, pid: pid))
                h.finish()
                precondition(h.probes == 0 && h.finishes == [true] && !h.engine.paused,
                             "前台不得查询或依赖进程状态")
                precondition(h.events.last?.type == .leftMouseUp
                                && h.events.last?.point == CGPoint(x: 240, y: 60),
                             "前台必须完整绘制到真实终点")
            }
        }
        // Process checks are absent, but the user retains immediate keyboard
        // and pointer interruption, plus the exact continuation point.
        for type in [CGEventType.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .scrollWheel] {
            let h = Harness(); h.state = .missing
            precondition(h.start(.foreground, pid: 999_999))
            h.advance { h.events.last?.type == .leftMouseDragged }
            let point = h.events.last!.point
            precondition(h.engine.testInput(type) && h.engine.paused && h.engine.running)
            precondition(h.events.last?.type == .leftMouseUp && h.finishes.isEmpty && h.probes == 0)
            let count = h.events.count
            for _ in 0..<100 { h.tick() }
            precondition(h.events.count == count, "前台暂停不能继续发出笔画")
            h.engine.resume(countdown: 0); h.finish()
            precondition(h.events[count].type == .mouseMoved && h.events[count].point == point)
            precondition(h.finishes == [true] && h.probes == 0)
        }

        precondition(DrawingEngine.targetAvailability(signalResult: 0, signalError: 0) == .alive)
        precondition(DrawingEngine.targetAvailability(signalResult: -1, signalError: EPERM) == .alive)
        precondition(DrawingEngine.targetAvailability(signalResult: -1, signalError: ESRCH) == .missing)
        precondition(DrawingEngine.targetAvailability(signalResult: -1, signalError: EIO) == .unconfirmed(EIO))
        // Backend failure releases immediately and leaves the task resumable.
        // Changing status back to alive simulates the target becoming available;
        // the engine still requires an explicit Continue before any new event.
        for failure in [DrawingTargetAvailability.missing, .unconfirmed(EIO), .changed] {
            let h = Harness()
            precondition(h.start(.background, pid: 999_999))
            h.advance { h.events.last?.type == .leftMouseDragged }
            let point = h.events.last!.point
            h.state = failure; h.tick()
            precondition(h.engine.running && h.engine.paused && h.finishes.isEmpty)
            precondition(h.events.last?.type == .leftMouseUp && h.events.last?.point == point)
            let count = h.events.count
            h.state = .alive
            for _ in 0..<100 { h.tick() }
            precondition(h.events.count == count, "目标恢复不能自动继续")
            h.engine.resume(countdown: 0); h.finish()
            precondition(h.events[count].type == .leftMouseDown && h.events[count].point == point)
            precondition(h.events.last?.type == .leftMouseUp && h.finishes == [true] && h.probes > 0)
        }
        let missing = Harness(); missing.state = .missing
        precondition(missing.start(.background, pid: 999_999)); missing.tick()
        precondition(missing.engine.paused && missing.events.isEmpty,
                     "后台目标不可用时不能发送任何输入")
        missing.engine.resume(countdown: 0); missing.tick()
        precondition(missing.engine.paused && missing.events.isEmpty && missing.finishes.isEmpty)
        missing.engine.stop(); precondition(missing.finishes == [false])
        for pid: pid_t? in [nil, -1, 0] {
            let h = Harness()
            precondition(!h.start(.background, pid: pid), "后台必须有正值目标PID")
        }
        print("PASS foreground never probes a target, including nil/stale/invalid PIDs / complete screen paths / keyboard and pointer pauses retained / exact foreground continuation / OS liveness classification / background unavailable releases and preserves progress / explicit recovery only / no events to unavailable backend / invalid background PID rejection")
    }
}
