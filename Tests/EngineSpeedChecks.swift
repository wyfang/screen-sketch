import AppKit
import ApplicationServices

@main struct EngineSpeedChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    static let rect = CGRect(x: -200, y: 100, width: 600, height: 400)
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    final class Harness {
        let engine = DrawingEngine()
        var events: [Event] = []
        var time = 0.0
        var ticks = 0
        let irregular: Bool
        init(speed: Double, irregular: Bool = false) {
            self.irregular = irregular
            engine.speed = speed
            engine.testClock = 0
            engine.testSink = { [weak self] type, point in
                guard let self else { return }
                self.events.append(Event(type: type, point: point, time: self.time))
            }
        }
        func start(paths: [[CGPoint]], minimum: Double, extensionLength: Double = 0) {
            let normalized = paths.map { path in
                path.map { CGPoint(x: ($0.x - rect.minX) / rect.width,
                                   y: ($0.y - rect.minY) / rect.height) }
            }
            require(engine.start(actions: [.profiledStrokes(paths: normalized, rect: rect,
                        brushWidth: 1, minimumMovement: minimum, speed: nil,
                        pressDelay: nil, releaseDelay: nil, endExtension: extensionLength)],
                    transport: .foreground, targetPID: nil, countdown: 0), "速度测试应启动")
        }
        func tick() {
            // Include both moderate jitter and a long missed timer interval.
            time += irregular && ticks % 53 == 0 ? 0.09
                : (irregular && ticks % 11 == 0 ? 0.017 : 0.004)
            ticks += 1
            engine.testTick(at: time)
        }
        func advance(until condition: () -> Bool) {
            for _ in 0..<250_000 {
                if condition() { return }
                tick()
            }
            fatalError("虚拟时钟应完成测试")
        }
        func finish() { advance { !engine.running } }
    }

    // A delivered short vertex cannot save travel credit for the next long
    // chord. Test every packet, including the first packet of a fresh press.
    @discardableResult static func checkPacing(_ events: [Event], speed: Double) -> Double {
        var previous: Event?
        var peak = 0.0
        for event in events {
            switch event.type {
            case .leftMouseDown:
                require(previous == nil, "每笔只能按下一次")
                previous = event
            case .leftMouseUp:
                require(previous != nil, "每笔释放必须有按下")
                previous = nil
            case .leftMouseDragged:
                guard let last = previous else { fatalError("拖动必须在按下后") }
                let elapsed = event.time - last.time
                let distance = hypot(event.point.x - last.point.x, event.point.y - last.point.y)
                require(elapsed > 0, "同一时刻不能发送多次拖动")
                let rate = distance / elapsed
                peak = max(peak, rate)
                require(rate <= speed + max(0.000001, speed * 0.000001),
                        "短顶点后的移动不能突发超过设定速度: \(rate) > \(speed)")
                previous = event
            case .mouseMoved:
                require(previous == nil, "定位必须抬笔")
            default: break
            }
        }
        require(previous == nil, "测试结束必须松开")
        return peak
    }

    static func densePath() -> [CGPoint] {
        (0...100).map { CGPoint(x: -100 + Double($0) * 0.25,
                               y: 200 + ($0 % 2 == 0 ? 0 : 0.25)) }
            + [CGPoint(x: 160, y: 200), CGPoint(x: 160, y: 203), CGPoint(x: -70, y: 203)]
    }

    static func main() {
        let path = densePath()
        for speed in [60.0, 135, 1002.875, 8000] {
            for minimum in [0.0, 8, 16] {
                for irregular in [false, true] {
                    let h = Harness(speed: speed, irregular: irregular)
                    let other = [CGPoint(x: 250, y: 300), CGPoint(x: 320, y: 300)]
                    h.start(paths: [path, other], minimum: minimum, extensionLength: 0.5)
                    h.finish()
                    checkPacing(h.events, speed: speed)
                    let drags = h.events.filter { $0.type == .leftMouseDragged }.map(\.point)
                    require(path.dropFirst().allSatisfy { vertex in
                        drags.contains { hypot($0.x - vertex.x, $0.y - vertex.y) < 0.000001 }
                    }, "节奏修正不能省略真实拐点或末端")
                    require(h.events.filter { $0.type == .leftMouseDown }.count == 2,
                            "分离的填充区域必须分别落笔，不能跨白区")
                    require(h.events.last?.point == CGPoint(x: 320.5, y: 300), "补偿终点仍需准确送达")
                    if !irregular {
                        let normalized = [path, other].map { points in
                            points.map { CGPoint(x: ($0.x - rect.minX) / rect.width,
                                                y: ($0.y - rect.minY) / rect.height) }
                        }
                        let estimate = DrawingEngine.estimateSeconds(paths: normalized, rect: rect,
                            brushWidth: 1, speed: speed, minimumMovement: minimum, endExtension: 0.5)
                        require(abs(estimate - (h.time + 3)) < 0.08,
                                "耗时估算应包含每个短顶点的等待，不能用长段抵消: \(estimate) / \(h.time + 3)")
                    }
                }
            }
        }

        // Sub-point calibration speeds also obey the same pacing policy.
        let tiny = Harness(speed: 0.5, irregular: true)
        let tinyPath = (0...20).map { CGPoint(x: -100 + Double($0) * 0.008, y: 200) }
            + [CGPoint(x: -96, y: 200)]
        tiny.start(paths: [tinyPath], minimum: 0.04); tiny.finish()
        checkPacing(tiny.events, speed: 0.5)

        // Pause while waiting for the minimum packet; idle/resume and the
        // fresh press hold cannot generate a saved-credit burst.
        let resumed = Harness(speed: 60, irregular: true)
        resumed.start(paths: [path], minimum: 8)
        resumed.advance { resumed.events.filter { $0.type == .leftMouseDragged }.count >= 102 }
        let point = resumed.events.last!.point
        resumed.engine.pause()
        let pausedCount = resumed.events.count
        resumed.time += 30; resumed.engine.testTick(at: resumed.time)
        require(resumed.events.count == pausedCount, "暂停期间不发送任何笔画")
        resumed.engine.resume(countdown: 0); resumed.finish()
        checkPacing(resumed.events, speed: 60)
        require(resumed.events[pausedCount].type == .mouseMoved
                    && resumed.events[pausedCount].point == point, "恢复先定位到原暂停点")

        // Lower the speed with unused credit just below M. It must wait for a
        // complete packet at the new speed, instead of spending the old credit.
        let changed = Harness(speed: 600)
        changed.start(paths: [[CGPoint(x: -100, y: 200), CGPoint(x: 100, y: 200)]], minimum: 8)
        changed.advance { changed.events.last?.type == .leftMouseDown }
        let downTime = changed.time
        changed.advance { changed.time >= downTime + 0.125 }
        require(!changed.events.contains { $0.type == .leftMouseDragged }, "降速前应正在等待最小移动量")
        let changeTime = changed.time
        changed.engine.speed = 10
        changed.advance { changed.events.last?.type == .leftMouseDragged }
        let first = changed.events.last!
        require(first.time - changeTime >= 0.8 - 0.000001,
                "降速不能继承旧速率积累的移动额度")
        require(hypot(first.point.x + 100, first.point.y - 200) / (first.time - changeTime) <= 10.000001,
                "降速后第一包也必须符合新速度")
        changed.finish(); checkPacing(changed.events, speed: 10)

        print("PASS short vertices followed by long fill chords / all packets paced at configured speed / M0, M8, M16 / regular and jittered timers / exact corners and endpoints / no white-gap connections / end compensation / sub-point speeds / pause and resume / live speed reduction clears old credit")
    }
}
