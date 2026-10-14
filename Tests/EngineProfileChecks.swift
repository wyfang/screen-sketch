import AppKit
import ApplicationServices

@main struct EngineProfileChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    static let rect = CGRect(x: -200, y: 100, width: 600, height: 400)
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.000001 }

    final class Harness {
        let engine = DrawingEngine()
        var events: [Event] = []
        var time = 0.0
        var afterEvent: ((Event) -> Void)?
        init() {
            engine.testClock = 0; engine.speed = 8000
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
            fatalError("虚拟时钟内应该完成或达到指定事件")
        }
        func finish() { advance { !engine.running }; validatePairing() }
        func validatePairing() {
            var pressed = false
            for event in events {
                switch event.type {
                case .leftMouseDown: require(!pressed, "不能重复按下"); pressed = true
                case .leftMouseUp: require(pressed, "不能重复释放"); pressed = false
                case .leftMouseDragged: require(pressed, "拖动必须在按下期间")
                case .mouseMoved: require(!pressed, "定位必须抬笔")
                default: break
                }
            }
            require(!pressed, "完成后必须释放画笔")
        }
    }

    static func line(y: Double = 0.2, backwards: Bool = false) -> [CGPoint] {
        let forward = [CGPoint(x: 0.2, y: y), CGPoint(x: 0.35, y: y)]
        return backwards ? Array(forward.reversed()) : forward
    }
    static func profile(paths: [[CGPoint]], speed: Double? = nil, press: Double? = nil,
                        release: Double? = nil, extensionLength: Double = 12) -> DrawingAction {
        .profiledStrokes(paths: paths, rect: rect, brushWidth: 2, minimumMovement: 0,
                         speed: speed, pressDelay: press, releaseDelay: release, endExtension: extensionLength)
    }
    static func strokeEvents(_ h: Harness, y: Double) -> [Event] {
        let absoluteY = rect.minY + rect.height * y
        return h.events.filter { abs($0.point.y - absoluteY) < 0.000001 && $0.type != .mouseMoved }
    }
    static func checkHolds(_ events: [Event], press: Double, release: Double) {
        let down = events.first { $0.type == .leftMouseDown }!
        let firstDrag = events.first { $0.type == .leftMouseDragged }!
        let lastDrag = events.last { $0.type == .leftMouseDragged }!
        let up = events.first { $0.type == .leftMouseUp }!
        require(firstDrag.time - down.time >= press - 0.000001, "首个拖动前必须完整等待按下延迟")
        require(up.time - lastDrag.time >= release - 0.000001 && up.point == lastDrag.point,
                "释放延迟必须在真实补偿端点发生")
    }

    static func main() {
        let basePaths = [line()]
        let original = DrawingEngine.mapPaths(basePaths, to: rect, brushWidth: 2)
        for disabled in [0.0, -1, Double.nan, .infinity] {
            require(DrawingEngine.compensatedPaths(basePaths, to: rect, brushWidth: 2, endExtension: disabled) == original,
                    "无效、负数和零补偿均应保持原路径")
        }
        let planned = DrawingEngine.compensatedPaths(basePaths, to: rect, brushWidth: 2, endExtension: 12)
        require(planned[0].dropLast().elementsEqual(original[0]) && planned[0].last! == CGPoint(x: original[0].last!.x + 12, y: original[0].last!.y),
                "水平补偿保留全部原顶点，再追加真实12点终点")
        let backwards = DrawingEngine.compensatedPaths([line(backwards: true)], to: rect, brushWidth: 2, endExtension: 12)[0]
        require(backwards.last! == CGPoint(x: original[0].first!.x - 12, y: original[0].first!.y), "从右到左时补偿必须沿左方向")

        let repeated = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3),
                        CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.3, y: 0.5)]
        let repeatedMapped = DrawingEngine.mapPaths([repeated], to: rect, brushWidth: 2)[0]
        let repeatedCompensated = DrawingEngine.compensatedPaths([repeated], to: rect, brushWidth: 2, endExtension: 12)[0]
        require(repeatedCompensated.last! == CGPoint(x: repeatedMapped.last!.x, y: repeatedMapped.last!.y + 12),
                "重复末顶点应沿最后非零段补偿，不能使用首段方向")
        let stationary = [[CGPoint(x: 0.5, y: 0.5)], [CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.6, y: 0.6)]]
        require(DrawingEngine.compensatedPaths(stationary, to: rect, brushWidth: 2, endExtension: 12)
                    == DrawingEngine.mapPaths(stationary, to: rect, brushWidth: 2), "单点和全重复路径没有方向，不可伪造补偿")

        // The y boundary is reached first. The x component must stop before its
        // own boundary, preserving the diagonal rather than bending its tail.
        let diagonal = [CGPoint(x: 0.75, y: 0.65), CGPoint(x: 0.98, y: 0.975)]
        let diagonalMapped = DrawingEngine.mapPaths([diagonal], to: rect, brushWidth: 2)[0]
        let limited = DrawingEngine.compensatedPaths([diagonal], to: rect, brushWidth: 2, endExtension: 100)[0]
        let safe = rect.insetBy(dx: 2, dy: 2)
        let vector = CGPoint(x: diagonalMapped[1].x - diagonalMapped[0].x, y: diagonalMapped[1].y - diagonalMapped[0].y)
        let extra = CGPoint(x: limited.last!.x - diagonalMapped[1].x, y: limited.last!.y - diagonalMapped[1].y)
        require(abs(extra.x * vector.y - extra.y * vector.x) < 0.000001 && limited.last!.x < safe.maxX,
                "斜线限界应沿原向量缩短补偿，不能逐轴夹紧造成偏折")
        require(abs(limited.last!.y - safe.maxY) < 0.000001, "沿向量补偿应尽可能到达最先遇到的安全边界")
        let edgeCases = [diagonal,
                         [CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.02, y: 0.025)],
                         [CGPoint(x: 0.25, y: 0.65), CGPoint(x: 0.02, y: 0.975)],
                         [CGPoint(x: 0.75, y: 0.35), CGPoint(x: 0.98, y: 0.025)]]
        for path in DrawingEngine.compensatedPaths(edgeCases, to: rect, brushWidth: 2, endExtension: 10000) {
            require(path.allSatisfy { $0.x >= safe.minX && $0.x <= safe.maxX && $0.y >= safe.minY && $0.y <= safe.maxY },
                    "所有方向的補偿路径均应留在原矩形的笔宽安全边界内")
        }

        // Fixed profile values cannot be overwritten by global controls. A
        // subsequent ordinary stroke must use global controls and no extension.
        let fixed = Harness(); fixed.engine.speed = 450
        fixed.afterEvent = { [weak fixed] event in
            if event.type == .leftMouseDown && abs(event.point.y - 180) < 0.000001 {
                fixed?.engine.speed = 8000; fixed?.engine.pressDelay = 0.35; fixed?.engine.releaseDelay = 0.4
            }
        }
        fixed.start([profile(paths: basePaths, speed: 10, press: 0.2, release: 0.24),
                     .strokes(paths: [line(y: 0.4)], rect: rect, brushWidth: 2, minimumMovement: 0),
                     profile(paths: [line(y: 0.6)], extensionLength: 0)])
        fixed.finish()
        let firstEvents = strokeEvents(fixed, y: 0.2)
        checkHolds(firstEvents, press: 0.2, release: 0.24)
        let firstDrags = firstEvents.filter { $0.type == .leftMouseDragged }
        require(firstDrags.last!.time - firstDrags.first!.time > 10.1, "profile的10点每秒应包含真实尾补偿距离")
        let endpointIndex = firstDrags.firstIndex { $0.point == original[0].last! }!
        require(endpointIndex < firstDrags.count - 1 && firstDrags.last!.point == planned[0].last!,
                "即使低速逐步移动，也必须先到原終点再送补偿终点")
        for y in [0.4, 0.6] {
            let events = strokeEvents(fixed, y: y)
            checkHolds(events, press: 0.35, release: 0.4)
            require(events.last!.point == DrawingEngine.mapPaths([line(y: y)], to: rect, brushWidth: 2)[0].last!,
                    "后续普通动作和零补偿profile不能继承上一笔尾补偿")
        }

        // The original endpoint and the added endpoint are always distinct drag
        // events, including at high speed with enough budget for both segments.
        let highSpeed = Harness(); highSpeed.start([profile(paths: basePaths)]); highSpeed.finish()
        let highDrags = highSpeed.events.filter { $0.type == .leftMouseDragged }
        let originalIndex = highDrags.firstIndex { $0.point == original[0].last! }!
        require(highDrags[originalIndex + 1].time > highDrags[originalIndex].time
                    && highDrags.last!.point == planned[0].last!, "高速也必须在不同tick分别到原终点与补偿终点")
        checkHolds(highSpeed.events, press: 0.12, release: 0.12)

        // Resume from the original endpoint and from inside the extension. The
        // planned appended vertex remains outstanding until it is delivered.
        for interruptInside in [false, true] {
            let resumed = Harness(); resumed.engine.speed = interruptInside ? 60 : 8000
            resumed.start([profile(paths: basePaths)])
            resumed.advance {
                guard let event = resumed.events.last, event.type == .leftMouseDragged else { return false }
                return interruptInside ? (event.point.x > original[0].last!.x && event.point.x < planned[0].last!.x)
                    : event.point == original[0].last!
            }
            let pausedPoint = resumed.events.last!.point
            resumed.engine.pause(); let count = resumed.events.count
            resumed.engine.resume(countdown: 0); resumed.finish()
            let continuation = Array(resumed.events.dropFirst(count))
            require(continuation.first?.type == .mouseMoved && continuation.first!.point == pausedPoint,
                    "尾段恢复应先抬笔定位到真实暂停位置")
            require(continuation.last?.type == .leftMouseUp && continuation.last!.point == planned[0].last!,
                    "暂停不能丢失尚未完成的尾补偿")
            checkHolds(continuation, press: 0.12, release: 0.12)
        }
        let atEnd = Harness(); atEnd.start([profile(paths: basePaths)])
        atEnd.advance { atEnd.events.last?.type == .leftMouseDragged && atEnd.events.last!.point == planned[0].last! }
        atEnd.engine.pause(); let count = atEnd.events.count
        atEnd.engine.resume(countdown: 0); atEnd.finish()
        require(atEnd.events.count == count, "已到补偿终点后暂停恢复不可重复按下或再次补偿")

        let stopped = Harness(); stopped.start([profile(paths: basePaths)])
        stopped.advance { stopped.events.last?.type == .leftMouseDragged && stopped.events.last!.point == original[0].last! }
        let stopTime = stopped.time; stopped.engine.stop()
        require(stopped.events.last?.type == .leftMouseUp && stopped.events.last!.time == stopTime, "补偿前停止必须立即释放")
        let stoppedCount = stopped.events.count
        for _ in 0..<200 { stopped.tick() }
        stopped.validatePairing()
        require(stopped.events.count == stoppedCount && stopped.events.last!.point == original[0].last!, "停止后不可发送计划中的补偿")

        // The opt-in legacy entry point uses the same geometry; subsequent erase
        // and timed actions continue to map original paths without compensation.
        let entry = Harness()
        require(entry.engine.start(paths: basePaths, rect: rect, brushWidth: 2, transport: .foreground,
                                   targetPID: nil, countdown: 0, endExtension: 12), "legacy入口的显式补偿应启动")
        entry.finish(); require(entry.events.last!.point == planned[0].last!, "legacy显式补偿应使用同样的计划终点")
        let unchanged = Harness()
        unchanged.start([.strokes(paths: basePaths, rect: rect, brushWidth: 2, minimumMovement: 0),
                         .timedStrokes(paths: [line(y: 0.4)], rect: rect, brushWidth: 2, minimumMovement: 0, speed: 8000)])
        unchanged.finish()
        require(strokeEvents(unchanged, y: 0.2).last!.point == original[0].last!
                    && strokeEvents(unchanged, y: 0.4).last!.point == DrawingEngine.mapPaths([line(y: 0.4)], to: rect, brushWidth: 2)[0].last!,
                "普通笔画和擦除所用旧actions始终保持零补偿")

        let originalEstimate = DrawingEngine.estimateSeconds(paths: basePaths, rect: rect, brushWidth: 2, speed: 60)
        let compensatedEstimate = DrawingEngine.estimateSeconds(paths: basePaths, rect: rect, brushWidth: 2, speed: 60, endExtension: 12)
        require(abs(compensatedEstimate - originalEstimate - 0.2) < 0.000001, "预计耗时应包含实际12点补偿距离")
        let boundaryEstimate = DrawingEngine.estimateSeconds(paths: [diagonal], rect: rect, brushWidth: 2, speed: 60, endExtension: 100)
        let baseBoundaryEstimate = DrawingEngine.estimateSeconds(paths: [diagonal], rect: rect, brushWidth: 2, speed: 60)
        require(boundaryEstimate - baseBoundaryEstimate < 0.3, "被边界限制的补偿预计耗时不可仍按请求100点计算")
        print("PASS per-stroke optional speed and holds / exact original endpoint before extension / last nonzero direction / reverse and diagonal / vector-limited safe boundaries / stationary paths / pause at original endpoint and inside tail / no repeat at compensated endpoint / immediate stop / legacy opt-in / zero compensation for existing and erase actions / estimates use actual extended paths")
    }
}
