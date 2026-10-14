import AppKit
import ApplicationServices

@main struct EngineActionChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.00001 }
    static let rect = CGRect(x: -150, y: 200, width: 600, height: 400)
    static let eraser = CGPoint(x: -500, y: 40)
    static let pen = CGPoint(x: -400, y: 40)
    static let line = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.25, y: 0.3)]

    final class Harness {
        let engine = DrawingEngine()
        var events: [Event] = []
        var finishes: [Bool] = []
        var updates: [Double] = []
        var time = 0.0
        var afterEvent: ((Event) -> Void)?
        init() {
            engine.testClock = 0
            engine.speed = 8000
            engine.testSink = { [weak self] type, point in
                guard let self else { return }
                let event = Event(type: type, point: point, time: self.time)
                self.events.append(event)
                require(!self.engine.testInput(type, marked: true), "自身按钮和笔画事件不能触发输入防护")
                self.afterEvent?(event)
            }
            engine.onFinish = { [weak self] in self?.finishes.append($0) }
            engine.onUpdate = { [weak self] progress, _ in self?.updates.append(progress) }
        }
        @discardableResult func start(_ actions: [DrawingAction], transport: DrawingTransport = .foreground) -> Bool {
            engine.start(actions: actions, transport: transport,
                         targetPID: transport == .background ? getpid() : nil, countdown: 0)
        }
        func tick() { time += 0.004; engine.testTick(at: time) }
        func advance(until condition: () -> Bool) {
            for _ in 0..<10000 { if condition() { return }; tick() }
            fatalError("事件序列不能在虚拟时钟中停滞")
        }
        func finish() { advance { !engine.running } }
        func buttonEvents(_ point: CGPoint) -> [Event] { events.filter { close($0.point, point) } }
        func validatePairing() {
            var pressed = false
            for event in events {
                switch event.type {
                case .leftMouseDown: require(!pressed, "不能重复按下鼠标"); pressed = true
                case .leftMouseUp: require(pressed, "不能重复释放鼠标"); pressed = false
                case .leftMouseDragged: require(pressed, "拖动前必须按下鼠标")
                case .mouseMoved: require(!pressed, "按钮/笔画之间必须抬笔移动")
                default: break
                }
            }
            require(!pressed, "完成或停止时必须释放鼠标")
        }
    }

    static var drawing: DrawingAction { .strokes(paths: [line], rect: rect, brushWidth: 2, minimumMovement: 3) }

    static func main() {
        // Erase an old test, switch back to the pen, then draw the next test.
        let erased = [line, line.map { CGPoint(x: $0.x, y: $0.y + 0.1) }]
        for speed in [60.0, 300, 8000] {
            let full = Harness(); full.engine.speed = speed
            require(full.start([.click(eraser), .strokes(paths: erased, rect: rect, brushWidth: 12, minimumMovement: 3),
                                .click(pen), drawing]), "工具切换与多段绘制应作为一个序列启动")
            full.finish(); full.validatePairing()
            for point in [eraser, pen] {
                let button = full.buttonEvents(point)
                require(button.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp], "按钮点击必须只发送移动、按下、释放，不能伪造拖动")
                let positioned = button[1].time - button[0].time
                let held = button[2].time - button[1].time
                require(positioned >= 0.10 - 0.000001 && positioned <= 0.104 + 0.000001,
                        "首个和笔画之间的按钮移动后均应固定等待100毫秒，不受绘制速度影响")
                require(held >= 0.10 - 0.000001 && held <= 0.104 + 0.000001,
                        "首个和笔画之间的按钮均应固定按住100毫秒，不受绘制速度影响")
                let upIndex = full.events.firstIndex { $0.type == .leftMouseUp && close($0.point, point) }!
                require(full.events[upIndex + 1].time - button.last!.time >= 0.30 - 0.000001, "切换工具后应至少等待0.30秒再执行下一项")
            }
            let downPoints = full.events.filter { $0.type == .leftMouseDown }.map(\.point)
            require(downPoints.count == 5 && close(downPoints[0], eraser) && close(downPoints[3], pen), "擦除、恢复画笔、下一轮顺序不可打乱")
            require(close(downPoints[1], DrawingEngine.mapPaths(erased, to: rect, brushWidth: 12)[0][0]), "擦除应使用自己的原始画布映射")
            require(full.finishes == [true] && full.updates.last == 1, "完整序列仅完成一次，进度汇总到100%")
            require(zip(full.updates, full.updates.dropFirst()).allSatisfy { $0 <= $1 }, "汇总进度不能在新动作开始时归零")
        }

        // Tool selection uses three independent ordinary clicks. Activation may
        // consume the first; every remaining click still gets its own waits.
        for speed in [60.0, 300, 8000] {
            let triple = Harness(); triple.engine.speed = speed
            require(triple.start([.selectTool(eraser), .strokes(paths: erased, rect: rect, brushWidth: 12, minimumMovement: 3),
                                  .selectTool(pen), drawing]), "三次工具点击、擦除与绘制应作为一个序列启动")
            triple.finish(); triple.validatePairing()
            for point in [eraser, pen] {
                let button = triple.buttonEvents(point)
                require(button.map(\.type) == Array(repeating: [.mouseMoved, .leftMouseDown, .leftMouseUp], count: 3).flatMap { $0 },
                        "选工具必须恰好三次独立的移动、按下和释放，不能伪造拖动")
                for index in 0..<3 {
                    let base = index * 3
                    let positioned = button[base + 1].time - button[base].time
                    let held = button[base + 2].time - button[base + 1].time
                    require(positioned >= 0.10 - 0.000001 && positioned <= 0.104 + 0.000001,
                            "三次工具点击均应移动后等待100毫秒，不随绘图速度缩短")
                    require(held >= 0.10 - 0.000001 && held <= 0.104 + 0.000001,
                            "三次工具点击均应固定按住100毫秒，不随绘图速度缩短")
                    if index < 2 {
                        require(button[base + 3].time - button[base + 2].time >= 0.30 - 0.000001,
                                "每次工具点击后都应独立稳定300毫秒，不能合为快速连击")
                    }
                }
                let finalUpIndex = triple.events.lastIndex { $0.type == .leftMouseUp && close($0.point, point) }!
                require(triple.events[finalUpIndex + 1].time - button.last!.time >= 0.30 - 0.000001,
                        "第三次工具点击后也应稳定300毫秒再开始笔画")
            }
            let downPoints = triple.events.filter { $0.type == .leftMouseDown }.map(\.point)
            require(downPoints.count == 9 && downPoints.prefix(3).allSatisfy { close($0, eraser) }
                    && downPoints[5..<8].allSatisfy { close($0, pen) }, "三次橡皮、两段擦除、三次画笔、下一轮顺序不可打乱")
            require(close(downPoints[3], DrawingEngine.mapPaths(erased, to: rect, brushWidth: 12)[0][0])
                    && close(downPoints[8], DrawingEngine.mapPaths([line], to: rect, brushWidth: 2)[0][0]),
                    "三次选工具后才能执行各自画布上的笔画")
            require(triple.finishes == [true] && triple.updates.last == 1, "三次工具序列应只完成一次并达到100%")
        }

        // Pausing during either early click preserves delivered clicks and
        // schedules only the remaining planned tool clicks after Continue.
        for interruptedClick in [1, 2] {
            for edge in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let h = Harness()
                require(h.start([.selectTool(pen), drawing]), "三次工具暂停序列应启动")
                h.advance {
                    h.buttonEvents(pen).filter { $0.type == edge }.count == interruptedClick
                        && h.events.last?.type == edge
                }
                require(h.engine.testInput(.keyDown) && h.engine.paused, "第一或第二次工具点击中按键应暂停")
                let count = h.events.count
                for _ in 0..<10 { h.tick() }
                require(h.events.count == count, "三次工具序列暂停时不得发送剩余点击或笔画")
                h.engine.resume(countdown: 0); h.finish(); h.validatePairing()
                let button = h.buttonEvents(pen)
                let downs = button.filter { $0.type == .leftMouseDown }
                let ups = button.filter { $0.type == .leftMouseUp }
                require(downs.count == 3 && ups.count == 3, "继续后总共仍只有三次工具点击，不能重放已经送出的点击")
                for index in 0..<2 {
                    require(downs[index + 1].time - ups[index].time >= 0.30 - 0.000001,
                            "继续后不能跳过前一次工具点击的稳定时间")
                }
                let firstCanvasEvent = h.events.first { rect.contains($0.point) }!
                require(firstCanvasEvent.time - ups.last!.time >= 0.30 - 0.000001,
                        "暂停继续后第三次工具点击仍应稳定300毫秒再绘制")
                require(h.finishes == [true], "三次工具暂停继续仅完成一次")
            }
        }

        // Stop in the first or second click releases its down immediately and
        // discards every planned remaining tool click and subsequent stroke.
        for stoppedClick in [1, 2] {
            let h = Harness()
            require(h.start([.selectTool(pen), drawing]), "三次工具停止序列应启动")
            h.advance { h.buttonEvents(pen).filter { $0.type == .leftMouseDown }.count == stoppedClick }
            h.engine.stop()
            let count = h.events.count
            for _ in 0..<300 { h.tick() }
            h.validatePairing()
            require(h.events.count == count && h.finishes == [false], "停止后三次工具序列必须停止且只通知一次")
            require(h.buttonEvents(pen).filter { $0.type == .leftMouseDown }.count == stoppedClick
                    && !h.events.contains { rect.contains($0.point) }, "停止后不能发送剩余工具点击或任何笔画")
        }

        // Pause before down, after down, and after up. A completed toggle is never clicked twice.
        for edge in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let h = Harness()
            require(h.start([.click(eraser), drawing]), "暂停边界序列应启动")
            h.advance { h.events.last?.type == edge && close(h.events.last!.point, eraser) }
            let interruptedTime = h.time
            require(h.engine.testInput(.keyDown) && h.engine.paused, "任何键盘操作都应暂停工具切换")
            let count = h.events.count
            for _ in 0..<10 { h.tick() }
            require(h.events.count == count, "暂停时不能继续擦除或切换工具")
            h.engine.resume(countdown: 0)
            h.finish(); h.validatePairing()
            require(h.buttonEvents(eraser).filter { $0.type == .leftMouseDown }.count == 1, "恢复时不得重复点击已按下的按钮")
            require(h.buttonEvents(eraser).filter { $0.type == .leftMouseUp }.count == 1, "暂停只能释放一次按钮")
            if edge != .mouseMoved {
                let up = h.buttonEvents(eraser).first { $0.type == .leftMouseUp }!
                let firstCanvasEvent = h.events.first { rect.contains($0.point) }!
                require(firstCanvasEvent.time - up.time >= 0.30 - 0.000001, "零秒恢复倒计时也不能跳过按钮稳定等待")
                require(up.time <= interruptedTime + 0.000001, "按下时暂停必须立即释放按钮")
            }
            require(h.finishes == [true], "恢复后的动作序列只能完成一次")
        }

        // Pause can arrive immediately as the delivered button-down is observed.
        let reentrant = Harness()
        reentrant.afterEvent = { [weak reentrant] event in
            if event.type == .leftMouseDown && close(event.point, eraser) {
                require(reentrant?.engine.testInput(.mouseMoved) == true, "按下交界的手动鼠标活动应立即暂停")
            }
        }
        require(reentrant.start([.click(eraser), drawing]), "重入输入测试应启动")
        reentrant.advance { reentrant.engine.paused }
        require(reentrant.events.last?.type == .leftMouseUp, "已送出的按钮down应被立即释放")
        reentrant.afterEvent = nil
        reentrant.engine.resume(countdown: 0); reentrant.finish(); reentrant.validatePairing()
        require(reentrant.buttonEvents(eraser).filter { $0.type == .leftMouseDown }.count == 1, "输入交界暂停不能导致二次点击")

        // Stop after down releases once and prevents all remaining erase/draw/tool actions.
        let stopped = Harness()
        require(stopped.start([.click(eraser), drawing, .click(pen), drawing]), "停止测试应启动")
        stopped.advance { stopped.events.last?.type == .leftMouseDown }
        stopped.engine.stop()
        let stoppedCount = stopped.events.count
        for _ in 0..<300 { stopped.tick() }
        stopped.engine.stop(); stopped.validatePairing()
        require(stopped.events.count == stoppedCount && stopped.finishes == [false], "停止必须中止整条动作序列且只通知一次")
        require(!stopped.events.contains { rect.contains($0.point) || close($0.point, pen) }, "停止后不能发送遗留笔画或下一个工具点击")

        // A final button action still waits for the application to settle before reporting success.
        let onlyButton = Harness()
        require(onlyButton.start([.click(pen)]), "纯按钮序列应合法")
        onlyButton.advance { onlyButton.events.last?.type == .leftMouseUp }
        let upTime = onlyButton.time
        require(onlyButton.engine.running && onlyButton.finishes.isEmpty, "最后按钮up不应提前报告完成")
        onlyButton.finish(); onlyButton.validatePairing()
        require(onlyButton.time - upTime >= 0.30 - 0.000001 && onlyButton.finishes == [true], "最终按钮也必须保留稳定等待")

        // Each stroke batch keeps its own minimum movement; no global setting bleeds between tools.
        let thresholds = Harness(); thresholds.engine.speed = 60; thresholds.engine.minimumMovement = 1000
        let testLine = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.24, y: 0.2)]
        let otherLine = testLine.map { CGPoint(x: $0.x, y: $0.y + 0.1) }
        require(thresholds.start([.strokes(paths: [testLine], rect: rect, brushWidth: 2, minimumMovement: 12),
                                  .strokes(paths: [otherLine], rect: rect, brushWidth: 2, minimumMovement: 0)]), "不同位移阈值的动作应启动")
        thresholds.finish(); thresholds.validatePairing()
        let firstY = DrawingEngine.mapPaths([testLine], to: rect, brushWidth: 2)[0][0].y
        let firstDrags = thresholds.events.filter { $0.type == .leftMouseDragged && abs($0.point.y - firstY) < 0.00001 }
        let secondDrags = thresholds.events.filter { $0.type == .leftMouseDragged && abs($0.point.y - firstY) > 0.00001 }
        require(firstDrags.count == 2 && secondDrags.count > 20, "每个动作应独立采用12点或0点阈值，不读全局1000点值")

        let background = Harness()
        require(background.start([.click(pen), drawing], transport: .background), "后台动作应仍定向目标PID")
        background.finish(); background.validatePairing()
        require(background.events.filter { $0.type == .mouseMoved }.count == 1, "后台按钮拥有定向move，笔画仍不移动系统鼠标")

        let invalid = Harness()
        require(!invalid.start([]) && !invalid.start([.click(CGPoint(x: Double.nan, y: 0))])
                && !invalid.start([.selectTool(CGPoint(x: 0, y: Double.infinity))]), "空序列与非有限按钮坐标不可启动")
        require(invalid.events.isEmpty && invalid.finishes.isEmpty, "无效序列不可产生输入或完成回调")
        print("PASS ordinary single clicks / exactly three independent tool clicks / erase-pen-draw ordering / fixed 100ms move and hold + independent 300ms settling at speeds 60/300/8000 / first and mid-sequence buttons / no fabricated button drags / pause-resume at first and second tool clicks / no duplicate delivered clicks / reentrant input / stop cancels remaining clicks and strokes / per-action thresholds / aggregate progress / directed background")
    }
}
