import AppKit
import ApplicationServices

@main struct EngineChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.0001 }
    static func paired(_ events: [Event]) -> Bool {
        var down = false
        for event in events {
            switch event.type {
            case .leftMouseDown: if down { return false }; down = true
            case .leftMouseDragged: if !down { return false }
            case .leftMouseUp: if !down { return false }; down = false
            case .mouseMoved: if down { return false }
            default: break
            }
        }
        return !down
    }
    static func finish(_ engine: DrawingEngine, from start: Double, limit: Double = 100) -> Double {
        for i in 1...Int(limit / 0.004) {
            let time = start + Double(i) * 0.004
            engine.testTick(at: time)
            if !engine.running { return time }
        }
        fatalError("虚拟时钟应完成绘制，不能卡住")
    }

    static func main() {
        let rect = CGRect(x: -200, y: 100, width: 600, height: 400)
        let strokes = [[CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.8, y: 0.8)]]
        var events: [Event] = []
        let engine = DrawingEngine()
        engine.testClock = 0
        engine.testSink = { [weak engine] type, point in
            events.append(Event(type: type, point: point, time: engine?.testClock ?? 0))
            require(engine?.testInput(type, marked: true) == false, "标记的自身注入事件不能拦截或触发暂停")
        }
        engine.speed = 600
        engine.minimumMovement = 3
        var completed: Bool?
        var pauseCalls = 0
        engine.onFinish = { completed = $0 }
        engine.onPause = { _ in pauseCalls += 1 }
        require(engine.start(paths: strokes, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 1), "合法路径应启动")
        engine.testTick(at: 0.8)
        require(!engine.testInput(.keyDown, keyCode: 0) && !engine.paused, "首次准备倒计时允许用户操作")
        require(events.isEmpty, "倒计时期间不能发送任何鼠标输入")
        for i in 250...300 { engine.testTick(at: Double(i) * 0.004) }
        require(events.contains { $0.type == .leftMouseDown }, "应开始第一笔")
        require(engine.testInput(.keyDown, keyCode: 0), "前台按任意普通键必须拦截并暂停")
        require(engine.paused && events.last?.type == .leftMouseUp && pauseCalls == 1, "暂停必须立即释放并通知UI")
        let pausedPoint = events.last!.point
        let count = events.count
        engine.testTick(at: 10)
        require(!engine.testInput(.keyDown, keyCode: 53) && !engine.testInput(.flagsChanged), "已暂停的输入应放行")
        require(engine.paused && events.count == count && pauseCalls == 1, "暂停时任何键不可恢复，也不能发送笔画")
        engine.resume(countdown: 1)
        require(!engine.testInput(.leftMouseUp), "继续按钮的mouseup不能被吞掉")
        engine.testTick(at: 10.5)
        require(events.count == count, "继续必须先完成新的倒计时")
        require(engine.testInput(.flagsChanged), "恢复倒计时中单独按修饰键也应暂停")
        require(engine.paused && pauseCalls == 2 && events.count == count, "恢复倒计时暂停不能发送额外up")
        engine.resume(countdown: 1)
        engine.testTick(at: 11.4)
        require(events.count == count, "恢复倒计时结束前不能移动指针")
        engine.testTick(at: 11.5)
        require(events.count == count + 1 && events.last?.type == .mouseMoved && close(events.last!.point, pausedPoint), "恢复第一步必须空移到原暂停点")
        _ = finish(engine, from: 11.5)
        require(completed == true && paired(events), "继续完成后每次按下必须配对释放")
        require(events.filter { $0.type == .leftMouseDown }.count == 2, "续画仅重新按下一次")
        require(events.last?.type == .leftMouseUp, "完成后最后输入必须释放")
        require(events.allSatisfy { rect.contains($0.point) }, "所有事件都应留在选区内")

        // Esc, a bare modifier, and a real pointer each pause. They never serve as Resume.
        for input in [CGEventType.keyDown, .flagsChanged, .mouseMoved, .leftMouseDragged, .scrollWheel] {
            events.removeAll(); completed = nil; engine.testClock = 0
            require(engine.start(paths: strokes, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "应可重新开始")
            for i in 0...20 { engine.testTick(at: Double(i) * 0.004) }
            require(engine.testInput(input, keyCode: 53) && engine.paused && events.last?.type == .leftMouseUp, "任意键/单独修饰键/真实鼠标必须暂停释放")
            require(engine.running && completed == nil, "前台Esc也暂停，不终止任务")
            engine.testInput(.keyDown, keyCode: 0)
            require(engine.paused, "普通键不恢复已暂停任务")
            engine.stop()
            require(completed == false && paired(events), "暂停后停止不重复释放")
        }

        events.removeAll(); completed = nil; engine.testClock = 0
        require(engine.start(paths: strokes, rect: rect, brushWidth: 2, transport: .background, targetPID: getpid(), countdown: 0), "后台模式应可启动")
        for i in 0...20 { engine.testTick(at: Double(i) * 0.004) }
        require(!events.contains { $0.type == .mouseMoved }, "后台定向输入不移动全局指针")
        require(!engine.testInput(.keyDown, keyCode: 0) && !engine.testInput(.mouseMoved) && !engine.testInput(.flagsChanged), "后台允许用户在别处使用键鼠")
        require(!engine.paused && engine.running, "后台普通输入不暂停")
        require(engine.testInput(.keyDown, keyCode: 53) && !engine.running && completed == false && paired(events), "后台专用Esc停止必须配对释放")
        let afterStop = events.count
        engine.testTick(at: 3)
        require(events.count == afterStop, "停止后不得残留未来输入")
        require(!engine.start(paths: [], rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil), "空路径不得启动")
        require(!engine.start(paths: strokes, rect: rect, brushWidth: 2, transport: .background, targetPID: nil), "后台没有目标不得启动")

        // Slow drawing accumulates enough distance instead of emitting a tiny move every tick.
        events.removeAll(); engine.testClock = 0; engine.speed = 60; engine.minimumMovement = 3
        let line = [[CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.19, y: 0.5)]]
        require(engine.start(paths: line, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "最小移动测试应启动")
        _ = finish(engine, from: 0)
        var previous = events.first { $0.type == .leftMouseDown }!.point
        let drags = events.filter { $0.type == .leftMouseDragged }
        for (index, event) in drags.enumerated() {
            let distance = hypot(event.point.x - previous.x, event.point.y - previous.y)
            require(index == drags.count - 1 || distance >= 2.999, "非末段移动不得低于最小移动量")
            previous = event.point
        }
        require(close(drags.last!.point, DrawingEngine.mapPaths(line, to: rect, brushWidth: 2)[0].last!), "短末段必须停在真实终点，不扩展墨迹")
        require(paired(events), "最小移动模式也必须配对释放")

        // Short corners/tails remain exact even if a high threshold is larger than a segment.
        events.removeAll(); engine.testClock = 0; engine.speed = 8000; engine.minimumMovement = 12
        let corner = [[CGPoint(x: 0.10, y: 0.20), CGPoint(x: 0.101, y: 0.20), CGPoint(x: 0.101, y: 0.201), CGPoint(x: 0.104, y: 0.201)],
                      [CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.801, y: 0.8)]]
        let exact = DrawingEngine.mapPaths(corner, to: rect, brushWidth: 2)
        require(engine.start(paths: corner, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "短转折测试应启动")
        _ = finish(engine, from: 0)
        let emitted = events.filter { $0.type == .leftMouseDragged }.map(\.point)
        require(exact.flatMap { $0.dropFirst() }.allSatisfy { point in emitted.contains { close($0, point) } }, "阈值不能省略转折或拉长短线")
        require(paired(events) && events.filter { $0.type == .leftMouseDown }.count == 2, "白区必须抬笔，不得连接两笔")

        // Calibration disables the threshold; even a sub-point path is kept exact.
        events.removeAll(); engine.testClock = 0; engine.speed = 450; engine.minimumMovement = 0
        let micro = [[CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5 + 0.5 / rect.width, y: 0.5)],
                     [CGPoint(x: 0.6, y: 0.6)], [CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.7, y: 0.7)]]
        let microExact = DrawingEngine.mapPaths(micro, to: rect, brushWidth: 2)
        require(engine.start(paths: micro, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "校准细小笔画应启动")
        _ = finish(engine, from: 0)
        require(events.filter { $0.type == .leftMouseDragged }.contains { close($0.point, microExact[0].last!) }, "0.5点校准线不能被扩大或合并")
        require(events.filter { $0.type == .leftMouseDragged }.count == 3 && paired(events), "单点与重复点路径均应按下、零长度拖动、释放")

        // Movement calibration emits each candidate as one exact displacement, independent of speed.
        for testSpeed in [60.0, 450, 8000] {
            events.removeAll(); engine.testClock = 0; engine.speed = testSpeed; engine.minimumMovement = 16
            let lengths = [0.5, 1.0, 2, 4, 8, 16]
            let candidates = lengths.enumerated().map { index, length in
                [CGPoint(x: 0.5, y: 0.2 + Double(index) * 0.1), CGPoint(x: 0.5 + length / rect.width, y: 0.2 + Double(index) * 0.1)]
            }
            require(engine.start(paths: candidates, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "真实位移校准应启动")
            _ = finish(engine, from: 0)
            let down = events.filter { $0.type == .leftMouseDown }
            let drag = events.filter { $0.type == .leftMouseDragged }
            require(drag.count == lengths.count && paired(events), "每条候选必须一次拖完，不拆成无效的小步")
            for index in lengths.indices {
                require(abs(hypot(drag[index].point.x - down[index].point.x, drag[index].point.y - down[index].point.y) - lengths[index]) < 0.00001, "校准位移不可缩短或扩大")
            }
        }

        // A pause after the endpoint but before the scheduled release must not add another dot.
        events.removeAll(); engine.testClock = 0; engine.speed = 8000; engine.minimumMovement = 3
        require(engine.start(paths: line, rect: rect, brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "终点暂停测试应启动")
        let lastPoint = DrawingEngine.mapPaths(line, to: rect, brushWidth: 2)[0].last!
        var endpointTime = 0.0
        for i in 0...100 {
            endpointTime = Double(i) * 0.004
            engine.testTick(at: endpointTime)
            if events.last?.type == .leftMouseDragged && close(events.last!.point, lastPoint) { break }
        }
        require(events.last?.type == .leftMouseDragged && close(events.last!.point, lastPoint), "测试必须停在已画完但未释放的终点")
        engine.pause(reason: "终点暂停")
        let dragsBeforeResume = events.filter { $0.type == .leftMouseDragged }.count
        engine.resume(countdown: 0)
        _ = finish(engine, from: endpointTime)
        require(events.filter { $0.type == .leftMouseDragged }.count == dragsBeforeResume && paired(events), "终点暂停恢复应直接完成，不重复按下画点")

        func duration(speed: Double, paths: [[CGPoint]], minimum: Double) -> Double {
            let timed = DrawingEngine(); timed.testClock = 0
            var lastEventTime = -Double.infinity
            timed.testSink = { [weak timed] _, _ in
                let now = timed?.testClock ?? 0
                require(now - lastEventTime >= 0.003999, "正常执行每次tick最多一个输入事件，不能紧密洪泛")
                lastEventTime = now
            }
            timed.speed = speed; timed.minimumMovement = minimum
            // Isolate movement-speed behavior from the new deliberate per-stroke holds.
            timed.pressDelay = 0; timed.releaseDelay = 0
            require(timed.start(paths: paths, rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), brushWidth: 2, transport: .foreground, targetPID: nil, countdown: 0), "速度测试应启动")
            return finish(timed, from: 0)
        }
        let dense = (0..<80).map { row in [CGPoint(x: 0.1, y: 0.1 + Double(row) * 0.008), CGPoint(x: 0.103, y: 0.1 + Double(row) * 0.008)] }
        let slow = duration(speed: 60, paths: dense, minimum: 3)
        let fast = duration(speed: 8000, paths: dense, minimum: 3)
        require(slow > fast * 4, "速度滑块必须显著改变密集短笔画实际耗时")
        let longLine = [[CGPoint(x: 0.05, y: 0.5), CGPoint(x: 0.95, y: 0.5)]]
        let oldCap = duration(speed: 2500, paths: longLine, minimum: 3)
        let aboveCap = duration(speed: 8000, paths: longLine, minimum: 3)
        require(oldCap > aboveCap * 2, "8000速度不能仍被2500上限限制")
        let slowEstimate = DrawingEngine.estimateSeconds(paths: dense, rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), brushWidth: 2, speed: 60, minimumMovement: 3, pressDelay: 0, releaseDelay: 0)
        let fastEstimate = DrawingEngine.estimateSeconds(paths: dense, rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), brushWidth: 2, speed: 8000, minimumMovement: 3, pressDelay: 0, releaseDelay: 0)
        require(slowEstimate > fastEstimate * 2, "耗时估计应包含速度、最小移动和笔间延迟")
        print(String(format: "PASS input pause / modifiers / Esc pauses foreground / background Esc stops / marked events / resume countdown and reposition / paired up-down / exact corners and tails / dense 60=%.3fs 8000=%.3fs / no 2500 cap", slow, fast))
    }
}
