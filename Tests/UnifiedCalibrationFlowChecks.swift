import AppKit
import ApplicationServices

/// 联合校准的真实引擎、路径账本及反馈状态联合测试。虚拟 sink 是唯一事件接收端。
@main struct UnifiedCalibrationFlowChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    struct Stroke { let events: [Event]; var points: [CGPoint] { events.filter { $0.type != .leftMouseUp }.map(\.point) } }
    static let area = CGRect(x: -1100, y: -80, width: 480, height: 900)
    static let pen = CGPoint(x: -1160, y: -140)
    static let eraser = CGPoint(x: -1210, y: -140)
    static let pid: pid_t = 4321
    static let brush = 2.5
    static let toolClicks = 3
    static func require(_ result: Bool, _ message: String) { if !result { fatalError(message) } }
    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.000_001 }

    final class Harness {
        let engine = DrawingEngine()
        let ledger: CalibrationAutomation
        var events: [Event] = []
        var finishes: [Bool] = []
        var time = 0.0
        var complete: (() -> Void)?
        init(_ ledger: CalibrationAutomation) {
            self.ledger = ledger
            engine.testClock = 0
            engine.speed = 300
            engine.pressDelay = 0.18
            engine.releaseDelay = 0.14
            engine.testSink = { [weak self] type, point in
                guard let self else { return }
                self.events.append(Event(type: type, point: point, time: self.time))
                require(!self.engine.testInput(type, marked: true), "联合校准的自身事件不能造成暂停")
                // 所有校准批次均应使用固定速度，不被普通绘制设置覆盖。
                if type == .leftMouseDown { self.engine.speed = self.engine.speed == 8000 ? 20 : 8000 }
            }
            engine.onFinish = { [weak self] success in
                guard let self else { return }
                self.finishes.append(success)
                self.ledger.finish(completed: success)
                if success { self.complete?() }
            }
        }
        func start(_ operation: CalibrationOperation, targetPID: pid_t = pid) {
            require(engine.start(actions: operation.actions, transport: .foreground, targetPID: targetPID, countdown: 0),
                    "联合校准动作应通过真实引擎的启动校验")
            ledger.begin(operation)
        }
        func tick() { time += 0.004; engine.testTick(at: time) }
        func advance(until condition: () -> Bool) {
            for _ in 0..<400_000 { if condition() { return }; tick() }
            fatalError("联合流程应在有界虚拟时间内完成")
        }
        func finish() { advance { !engine.running } }
        var strokes: [Stroke] {
            var result: [Stroke] = []
            var pending: [Event]?
            for event in events {
                switch event.type {
                case .leftMouseDown:
                    require(pending == nil, "不可重复按下")
                    pending = [event]
                case .leftMouseDragged:
                    require(pending != nil, "拖动前必须按下")
                    pending!.append(event)
                case .leftMouseUp:
                    require(pending != nil, "抬笔前必须按下")
                    pending!.append(event)
                    result.append(Stroke(events: pending!)); pending = nil
                case .mouseMoved: require(pending == nil, "定位前必须已释放画笔")
                default: break
                }
            }
            require(pending == nil, "完成、暂停或停止后必须已经抬笔")
            return result
        }
    }

    static func footprint(_ paths: [[CGPoint]], in rect: CGRect, targetPID: pid_t = pid,
                          brushWidth: Double = brush) -> CalibrationFootprint {
        // 与 App 相同，记录引擎实际落点，而非未经映射的任意相对坐标。
        let actual = DrawingEngine.mapPaths(paths, to: rect, brushWidth: brushWidth).map { path in
            path.map { CGPoint(x: ($0.x - rect.minX) / rect.width,
                               y: ($0.y - rect.minY) / rect.height) }
        }
        return CalibrationFootprint(paths: actual, area: rect, brushWidth: brushWidth, targetPID: targetPID)
    }
    static func prepare(_ ledger: CalibrationAutomation, round: UnifiedCalibrationRound?, in rect: CGRect,
                        targetPID: pid_t = pid, brushWidth: Double = brush) throws -> CalibrationOperation {
        func actions(_ batches: [UnifiedCalibrationBatch]) -> [DrawingAction] {
            batches.map { DrawingAction.profiledStrokes(paths: $0.paths, rect: rect, brushWidth: brushWidth,
                                      minimumMovement: $0.minimumMovement, speed: $0.speed,
                                      pressDelay: nil, releaseDelay: $0.releaseDelay, endExtension: $0.endExtension)
            }
        }
        let ink = round.map { plan -> CalibrationFootprint in
            let absolute = plan.batches.filter { !$0.isAnnotation }.flatMap {
                DrawingEngine.compensatedPaths($0.paths, to: rect, brushWidth: brushWidth, endExtension: $0.endExtension)
            }
            let normalized = absolute.map { $0.map { CGPoint(x: ($0.x - rect.minX) / rect.width,
                                                             y: ($0.y - rect.minY) / rect.height) } }
            let planned = DrawingEngine.mapPaths(plan.actualTestPaths, to: rect, brushWidth: brushWidth)
            require(planned.count == absolute.count && zip(planned, absolute).allSatisfy { a, b in
                a.count == b.count && zip(a, b).allSatisfy { close($0, $1) }
            }, "校准布局记录的每个补偿尾点必须等于真实引擎补偿轨迹，不得因边界静默缩短")
            return CalibrationFootprint(paths: normalized, area: rect, brushWidth: brushWidth, targetPID: targetPID)
        }
        let annotations = round.map { footprint($0.annotationPaths, in: rect, targetPID: targetPID, brushWidth: brushWidth) }
        if let ink { _ = try CalibrationCleanup.replay(footprint: ink) }
        if let annotations { _ = try CalibrationCleanup.replay(footprint: annotations) }
        return try ledger.prepare(newFootprint: ink, area: rect, targetPID: targetPID,
                                  penButton: pen, eraserButton: eraser,
                                  autoClear: true,
                                  drawingActions: round.map { actions($0.batches.filter { !$0.isAnnotation }) },
                                  persistentAnnotations: annotations,
                                  annotationActions: round.map { actions($0.batches.filter { $0.isAnnotation }) },
                                  preserveAnnotations: round == nil)
    }
    static func checkTool(_ strokes: ArraySlice<Stroke>, at point: CGPoint) {
        require(strokes.count == toolClicks, "擦除和绘制前必须完成三次工具点击")
        for click in strokes {
            require(click.events.count == 2 && click.events.first!.type == .leftMouseDown
                    && click.events.last!.type == .leftMouseUp && click.points.count == 1
                    && close(click.points[0], point) && close(click.events.last!.point, point),
                    "工具选择的三次点击必须原地完整按下和抬起，不能变成拖动")
            require(click.events.last!.time - click.events.first!.time >= 0.10 - 0.000_001,
                    "工具点击等待不可被每组绘制速度缩短")
        }
        for (previous, next) in zip(strokes, strokes.dropFirst()) {
            require(next.events.first!.time - previous.events.last!.time >= 0.30 - 0.000_001,
                    "连续工具点击之间必须让目标窗口有时间处理激活和切换")
        }
    }
    static func exact(_ strokes: [Stroke], _ paths: [[CGPoint]]) {
        require(strokes.count == paths.count, "原路径的数字、分区字母、参照线和测试线都必须保留")
        for (index, pair) in zip(strokes, paths).enumerated() {
            let (actual, expected) = pair
            require(actual.points.count == expected.count && zip(actual.points, expected).allSatisfy { close($0, $1) },
                    "重放必须逐顶点保留原坐标，不裁剪、平移或增加横扫：\(index) actual=\(actual.points) expected=\(expected)")
            require(close(actual.events.last!.point, expected.last!), "抬笔必须发生于原终点")
        }
    }
    /// 屏幕原点映射的舍入误差可能产生极短的同轴末尾事件，按空间包络验证绘制，
    /// 擦除验证仍逐事件与旧路径严格一一对应。所有真实拐角必须按原顺序出现。
    static func samePolyline(_ stroke: Stroke, _ path: [CGPoint]) {
        var vertex = 1
        require(close(stroke.points.first!, path[0]), "绘制起点保持原计划")
        for point in stroke.points.dropFirst() {
            if vertex == path.count {
                require(point == path.last!, "计划终点后的重复事件不能继续移动")
                continue
            }
            let a = path[vertex - 1], b = path[vertex]
            let dx = b.x - a.x, dy = b.y - a.y
            let distance = hypot(dx, dy)
            let along = distance == 0 ? 0 : ((point.x - a.x) * dx + (point.y - a.y) * dy) / distance
            let cross = distance == 0 ? hypot(point.x - a.x, point.y - a.y)
                : abs((point.x - a.x) * dy - (point.y - a.y) * dx) / distance
            require(cross < 0.000_001 && along >= -0.000_001 && along <= distance + 0.000_001,
                    "绘制事件必须位于原中心线段包络内")
            if point == b { vertex += 1 }
        }
        require(vertex == path.count, "原计划的每个真实拐角和终点都必须实际发送")
    }
    static func checkHolds(_ stroke: Stroke, releaseDelay: Double = 0.14) {
        let down = stroke.events.first!
        let drags = stroke.events.filter { $0.type == .leftMouseDragged }
        require(!drags.isEmpty, "每个标签和测试笔画都应实际拖动")
        require(drags.first!.time - down.time >= 0.18 - 0.000_001, "标签和测试笔画均须等待落笔停留")
        let actualRelease = stroke.events.last!.time - drags.last!.time
        require(actualRelease >= max(0.004, releaseDelay) - 0.000_001
                && actualRelease < max(0.004, releaseDelay) + 0.012, "标签和测试笔画均须完整使用对应组的终点停留")
        require(close(stroke.events.last!.point, drags.last!.point), "终点停留不能移动终点")
    }
    static func checkDrawing(_ strokes: [Stroke], round: UnifiedCalibrationRound,
                             includesAnnotations: Bool = true, brushWidth: Double = brush) {
        let batches = round.batches.filter { includesAnnotations || !$0.isAnnotation }
        require(strokes.count == batches.flatMap { $0.paths }.count, "四类测试应一次性完整绘制指定批次路径")
        var offset = 0
        for batch in batches {
            let expected = DrawingEngine.compensatedPaths(batch.paths, to: round.area,
                                                         brushWidth: brushWidth, endExtension: batch.endExtension)
            let actual = Array(strokes[offset..<(offset + expected.count)])
            for (stroke, path) in zip(actual, expected) {
                checkHolds(stroke, releaseDelay: batch.releaseDelay ?? 0.14)
                require(close(stroke.points.first!, path.first!) && close(stroke.points.last!, path.last!),
                        "每项测试必须从计划起点画到计划终点")
                if batch.metric != .speed { samePolyline(stroke, path) }
                else {
                    let drags = stroke.events.filter { $0.type == .leftMouseDragged }
                    require(drags.allSatisfy { close(CGPoint(x: $0.point.x, y: path[0].y), $0.point) },
                            "速度样本始终保持水平，不向标记线画出额外笔迹")
                    let length = zip(path, path.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
                    let elapsed = drags.last!.time - stroke.events.first!.time - 0.18
                    require(abs(elapsed - length / batch.speed) < 0.08,
                            "测速样本的物理移动时间应保留自己的候选速度，不受全局设置影响")
                }
            }
            offset += expected.count
        }
        require(offset == strokes.count, "所有批次都应完成且没有额外绘制动作")
    }

    static func erasedPaths(_ operation: CalibrationOperation, from ledger: CalibrationAutomation) -> [[CGPoint]] {
        ledger.records.filter { operation.erasedIDs.contains($0.id) }.flatMap {
            DrawingEngine.mapPaths($0.footprint.paths, to: $0.footprint.area, brushWidth: $0.footprint.brushWidth)
        }
    }
    static func run(_ operation: CalibrationOperation, ledger: CalibrationAutomation,
                    round: UnifiedCalibrationRound, includeAnnotations: Bool,
                    brushWidth: Double = brush, targetPID: pid_t = pid) -> Harness {
        let erased = erasedPaths(operation, from: ledger)
        let runner = Harness(ledger); runner.start(operation, targetPID: targetPID); runner.finish()
        let actual = runner.strokes
        let penIndex = erased.isEmpty ? 0 : erased.count + toolClicks
        if !erased.isEmpty {
            checkTool(actual.prefix(toolClicks), at: eraser)
            exact(Array(actual[toolClicks..<penIndex]), erased)
        }
        checkTool(actual[penIndex..<(penIndex + toolClicks)], at: pen)
        checkDrawing(Array(actual.dropFirst(penIndex + toolClicks)), round: round,
                     includesAnnotations: includeAnnotations, brushWidth: brushWidth)
        return runner
    }

    @MainActor static func main() throws {
        let model = UnifiedCalibration()
        let ledger = CalibrationAutomation()
        require(model.setArea(area), "窄竖向联合测试区设置成功")
        let first = try model.makeRound(brushWidth: brush, knownMovement: 3)
        require(first.paths == first.annotationPaths + first.testPaths, "固定标签与本轮样本分开记录，全部路径仍可供预览")
        require(first.annotationPaths == first.batches.filter { $0.isAnnotation }.flatMap { $0.paths }, "静态标签批次与静态账本一致")
        require(first.testPaths == first.batches.filter { !$0.isAnnotation }.flatMap { $0.paths }, "动态速度及E端点标记也必须列入本轮测试账本")
        require(first.annotationPaths.count == 8, "静态路径只包含 M/#/V/E 四个标题，不绘制123")
        for metric in [CalibrationMetric.spacingX, .spacingY] {
            require(first.batches.filter { $0.metric == metric }.allSatisfy { $0.paths.count == 2 }, "每组 X/Y 都只绘制一对相邻笔画")
        }
        let firstOperation = try prepare(ledger, round: first, in: area)
        let firstRunner = run(firstOperation, ledger: ledger, round: first, includeAnnotations: true)
        require(model.markDrawn() && firstRunner.finishes == [true], "引擎全部完成后解锁联合反馈")
        let firstAnnotation = ledger.records.first { $0.kind == .annotation }!
        let firstTest = ledger.records.first { $0.kind == .test }!
        require(ledger.records.count == 2 && firstAnnotation.completed, "首轮保留一份已完成标签账本与一份测试账本")
        for (metric, index) in [(CalibrationMetric.movement, 2), (.spacingX, 1), (.spacingY, 0), (.speed, 1), (.ending, 1)] {
            require(model.select(metric: metric, index: index), "四项可独立选择不同组号")
        }
        require(model.refine() && model.round == 2 && !model.hasDrawn && model.results != nil, "一次反馈同时细化四项，保留已确认结果")
        require(model.bounds(for: .movement) == 2...8 && model.bounds(for: .spacingX) == 0.5...2
                && model.bounds(for: .spacingY) == 0...0.5 && model.bounds(for: .speed) == 450...1350
                && model.bounds(for: .ending) == 0.12...0.35,
                "各项分别更新自己的搜索区间")

        // 正常进入下一轮只擦动态样本与速度参照线，不重写固定 1/2/3 或字母。
        let second = try model.makeRound(brushWidth: brush, knownMovement: 3)
        require(second.annotationPaths == first.annotationPaths, "普通细化不改变固定标签位置或大小")
        require(second.batches.filter { $0.metric != .ending }.allSatisfy { $0.releaseDelay == 0.35 },
                "已确认收笔等待使用于其他测试，E仍独立尝试更短等待")
        require(second.batches.filter { $0.metric == .movement }.allSatisfy { $0.endExtension == 0 },
                "M必须以真实候选鼠标距离测试，不能被末端补偿放大")
        let secondOperation = try prepare(ledger, round: second, in: area)
        require(secondOperation.erasedIDs == [firstTest.id], "同布局下一轮只擦除旧样本账本，不擦固定标签")
        let secondRunner = run(secondOperation, ledger: ledger, round: second, includeAnnotations: false)
        require(model.markDrawn() && secondRunner.finishes == [true], "第二轮同时绘完全部动态测试")
        require(ledger.records.filter { $0.kind == .annotation }.map(\.id) == [firstAnnotation.id], "固定标签只绘一次，继续保留首轮完成标记")
        require(ledger.records.count == 2 && ledger.records.filter { $0.kind == .test }.count == 1, "旧动态样本成功清除后只留本轮样本")
        let speedBatch = second.batches.first { $0.metric == .speed }!
        require(abs(speedBatch.minimumMovement - 8.8) < 0.000_001, "测速事件位移使用最新确认的 M")
        let secondTest = ledger.records.first { $0.kind == .test }!

        // 显式“清理测试笔迹”也保留标签，清理后重画同轮不重复写数字。
        let cleanup = try prepare(ledger, round: nil, in: area)
        require(cleanup.erasedIDs == [secondTest.id], "显式清理只处理动态笔迹")
        let cleanupExpected = erasedPaths(cleanup, from: ledger)
        let cleanupRunner = Harness(ledger); cleanupRunner.start(cleanup); cleanupRunner.finish()
        let cleaned = cleanupRunner.strokes
        checkTool(cleaned.prefix(toolClicks), at: eraser)
        exact(Array(cleaned.dropFirst(toolClicks).dropLast(toolClicks)), cleanupExpected)
        checkTool(cleaned.suffix(toolClicks), at: pen)
        require(ledger.records.map(\.id) == [firstAnnotation.id] && !ledger.hasInk(in: area, targetPID: pid, includeAnnotations: false),
                "清理按钮的剩余墨迹检测只算动态笔迹")
        require(model.repeatRound(), "清理后允许重画同轮")
        let repeated = try model.makeRound(brushWidth: brush, knownMovement: 3)
        let repeatedOperation = try prepare(ledger, round: repeated, in: area)
        require(repeatedOperation.erasedIDs.isEmpty, "已清理区域再次绘制不需再次擦除")
        _ = run(repeatedOperation, ledger: ledger, round: repeated, includeAnnotations: false)
        require(model.markDrawn(), "保留标签的重画可以确认完成")

        // 重新框选移动区域，旧标签不再复用，但必须在原矩形完整擦除。
        let shifted = area.offsetBy(dx: 7, dy: 9)
        require(model.setArea(shifted), "重新框选保留当前搜索范围")
        let shiftedRound = try model.makeRound(brushWidth: brush, knownMovement: 3)
        let shiftedOperation = try prepare(ledger, round: shiftedRound, in: shifted)
        require(shiftedOperation.erasedIDs == Set(ledger.records.map(\.id)), "区域改变后完整清理相交旧标签与动态样本")
        _ = run(shiftedOperation, ledger: ledger, round: shiftedRound, includeAnnotations: true)
        require(model.markDrawn(), "新区域全部绘制完成")
        let shiftedAnnotation = ledger.records.first { $0.kind == .annotation }!
        require(shiftedAnnotation.id != firstAnnotation.id && shiftedAnnotation.footprint.area == shifted,
                "重新绘制的标签重新绑定原始屏幕矩形")

        // 笔宽/静态布局签名变化必须清除旧标签并绘新标签。
        require(model.repeatRound(), "更换笔宽前允许重画")
        let changed = try model.makeRound(brushWidth: 4, knownMovement: 3)
        let changedOperation = try prepare(ledger, round: changed, in: shifted, brushWidth: 4)
        require(changedOperation.erasedIDs == Set(ledger.records.map(\.id)), "改变标签画笔签名不可继续复用旧标签")
        _ = run(changedOperation, ledger: ledger, round: changed, includeAnnotations: true, brushWidth: 4)
        require(ledger.records.count == 2 && ledger.records.first { $0.kind == .annotation }!.footprint.brushWidth == 4,
                "新的静态账本记录实际新笔宽")

        // 相同位置的另一目标程序不清理或复用原目标的固定标签。
        let localIDs = Set(ledger.records.map(\.id))
        let foreignPID = pid + 1
        let foreignOperation = try prepare(ledger, round: changed, in: shifted, targetPID: foreignPID, brushWidth: 4)
        require(foreignOperation.erasedIDs.isEmpty, "目标 PID 变化不得擦除原目标的任何标签或样本")
        _ = run(foreignOperation, ledger: ledger, round: changed, includeAnnotations: true, brushWidth: 4, targetPID: foreignPID)
        require(Set(ledger.records.filter { $0.footprint.targetPID == pid }.map(\.id)) == localIDs && ledger.records.count == 4,
                "不同目标分别保存自己的两类账本")
        let localCleanup = try prepare(ledger, round: nil, in: shifted)
        require(localCleanup.erasedIDs.count == 1 && localCleanup.erasedIDs.allSatisfy { id in
            ledger.records.contains { $0.id == id && $0.kind == .test && $0.footprint.targetPID == pid }
        }, "清理本地样本不能碰另一个目标的标签或测试")
        let localCleaner = Harness(ledger); localCleaner.start(localCleanup); localCleaner.finish()
        require(ledger.records.count == 3 && ledger.records.filter { $0.footprint.targetPID == foreignPID }.count == 2,
                "本地显式清理后保留两个目标的静态标签和外部目标样本")

        // 一个更早的校准笔迹可能与保留标签重叠；记录的墨迹重叠时，
        // 同签名也必须撤回复用，先完整擦除，再重画标签与当前样本。
        let touched = CalibrationAutomation()
        let label = footprint([[CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.25, y: 0.2)]], in: area)
        let sample = footprint([[CGPoint(x: 0.2, y: 0.202), CGPoint(x: 0.25, y: 0.202)]], in: area)
        func touchingOperation() throws -> CalibrationOperation {
            try touched.prepare(newFootprint: sample, area: area, targetPID: pid,
                penButton: pen, eraserButton: eraser, autoClear: true,
                drawingActions: [.timedStrokes(paths: sample.paths, rect: area, brushWidth: brush,
                                              minimumMovement: sample.longestSegmentLength, speed: 100)],
                persistentAnnotations: label,
                annotationActions: [.timedStrokes(paths: label.paths, rect: area, brushWidth: brush,
                                                 minimumMovement: label.longestSegmentLength, speed: 100)])
        }
        let touchingSeed = try touchingOperation()
        let touchingFirst = Harness(touched); touchingFirst.start(touchingSeed); touchingFirst.finish()
        let touchingNext = try touchingOperation()
        require(touchingNext.erasedIDs == Set(touched.records.map(\.id)) && touchingNext.newAnnotations != nil,
                "动态样本的记录墨迹与标题重叠时必须擦除并重新绘制同签名标题")
        let touchingExpected = erasedPaths(touchingNext, from: touched)
        let touchingRunner = Harness(touched); touchingRunner.start(touchingNext); touchingRunner.finish()
        checkTool(touchingRunner.strokes.prefix(toolClicks), at: eraser)
        exact(Array(touchingRunner.strokes[toolClicks..<(touchingExpected.count + toolClicks)]), touchingExpected)
        checkTool(touchingRunner.strokes[(touchingExpected.count + toolClicks)..<(touchingExpected.count + 2 * toolClicks)], at: pen)
        let redrawStart = touchingExpected.count + 2 * toolClicks
        exact(Array(touchingRunner.strokes.dropFirst(redrawStart)),
              DrawingEngine.mapPaths(label.paths + sample.paths, to: area, brushWidth: brush))
        require(touched.records.count == 2 && touched.records.first { $0.kind == .annotation }?.completed == true,
                "擦除冲突处理后留下新的完整标签，而不是复用被擦掉的旧标签")
        let beforeConflictedCleanup = touched.records.map(\.id)
        do {
            _ = try prepare(touched, round: nil, in: area)
            fatalError("未提供重绘标签计划的显式清理不能擦掉受保护标签")
        } catch CalibrationAutomation.AutomationError.annotationConflict {
            require(touched.records.map(\.id) == beforeConflictedCleanup,
                    "有冲突的显式清理在任何点击前拒绝，不能丢失静态或动态账本")
        }

        // 首次标签绘制在字形拐角暂停，完成后才允许把标签标记为可复用。
        let pauseLedger = CalibrationAutomation()
        let pauseModel = UnifiedCalibration()
        require(pauseModel.setArea(area), "独立暂停测试区设置成功")
        let pausePlan = try pauseModel.makeRound(brushWidth: brush, knownMovement: 3)
        let pauseOperation = try prepare(pauseLedger, round: pausePlan, in: area)
        let paused = Harness(pauseLedger)
        paused.complete = { require(pauseModel.markDrawn(), "恢复完成后才允许反馈") }
        paused.start(pauseOperation)
        paused.advance { paused.events.last?.type == .leftMouseDragged }
        let corner = paused.events.last!.point
        require(paused.engine.testInput(.keyDown) && paused.engine.paused, "标签拐角的任意键应暂停")
        require(paused.events.last?.type == .leftMouseUp && close(paused.events.last!.point, corner), "暂停立即在原拐角抬笔")
        let pausedCount = paused.events.count
        for _ in 0..<50 { paused.tick() }
        require(paused.events.count == pausedCount && !pauseModel.hasDrawn
                && pauseLedger.records.first { $0.kind == .annotation }?.completed == false,
                "暂停中的标签完整计划保留，但不能误标记为已经完整写好")
        paused.engine.resume(countdown: 0); paused.finish()
        let resumed = paused.strokes
        checkTool(resumed.prefix(toolClicks), at: pen)
        require(close(resumed[toolClicks].points.last!, resumed[toolClicks + 1].points.first!), "恢复回到标签原拐角")
        let joined = resumed[toolClicks].points + resumed[toolClicks + 1].points.dropFirst()
        let originalFirst = DrawingEngine.mapPaths([pausePlan.annotationPaths[0]], to: area, brushWidth: brush)[0]
        require(joined.count == originalFirst.count && zip(joined, originalFirst).allSatisfy { close($0, $1) }, "暂停恢复保留第一个字形全部原拐角")
        require(pauseLedger.records.first { $0.kind == .annotation }?.completed == true && pauseModel.hasDrawn,
                "标签和全部样本恢复完成后才允许复用静态标签")

        // 标签绘到一半停止：重试必须擦除并重画完整标签，不能保留半个数字。
        let incomplete = CalibrationAutomation()
        let stoppedOperation = try prepare(incomplete, round: pausePlan, in: area)
        let stopped = Harness(incomplete); stopped.start(stoppedOperation)
        stopped.advance { stopped.events.last?.type == .leftMouseDragged }
        stopped.engine.stop()
        require(stopped.finishes == [false] && incomplete.records.count == 2
                && incomplete.records.first { $0.kind == .annotation }?.completed == false,
                "中断首次标签保留两份完整计划，但静态标签不可复用")
        let stoppedCount = stopped.events.count
        for _ in 0..<50 { stopped.tick() }
        require(stopped.events.count == stoppedCount, "停止后不发送未来笔迹")
        _ = stopped.strokes
        let retry = try prepare(incomplete, round: pausePlan, in: area)
        require(retry.erasedIDs == Set(incomplete.records.map(\.id)), "同布局重试必须清除未完成标签和整轮样本计划")
        _ = run(retry, ledger: incomplete, round: pausePlan, includeAnnotations: true)
        require(incomplete.records.count == 2 && incomplete.records.first { $0.kind == .annotation }?.completed == true,
                "完整重试后留下已完成固定标签及新动态样本")

        // 已完整的标签在普通样本擦除中停止，应仍能复用；只保守追加测试账本。
        let currentAnnotationID = incomplete.records.first { $0.kind == .annotation }!.id
        let stopCleanup = try prepare(incomplete, round: pausePlan, in: area)
        let interrupted = Harness(incomplete); interrupted.start(stopCleanup)
        interrupted.advance { interrupted.events.last?.type == .leftMouseDragged }
        interrupted.engine.stop()
        require(interrupted.finishes == [false] && incomplete.records.count == 3
                && incomplete.records.filter { $0.kind == .annotation }.map(\.id) == [currentAnnotationID],
                "样本清理中断保持固定标签和两个保守测试计划")
        let recovered = try prepare(incomplete, round: pausePlan, in: area)
        require(recovered.erasedIDs.count == 2 && !recovered.erasedIDs.contains(currentAnnotationID), "恢复清理只重放两个测试计划")
        _ = run(recovered, ledger: incomplete, round: pausePlan, includeAnnotations: false)
        require(incomplete.records.count == 2 && incomplete.records.filter { $0.kind == .annotation }.map(\.id) == [currentAnnotationID],
                "恢复清理成功保留原完成标签，仅留下最新样本")

        // 切换布局后擦除旧标签途中停止，再回旧布局不能复用已被擦掉一部分的标签。
        let changedLayout = CalibrationAutomation()
        let oldLayout = try prepare(changedLayout, round: pausePlan, in: area)
        _ = run(oldLayout, ledger: changedLayout, round: pausePlan, includeAnnotations: true)
        let oldLabelID = changedLayout.records.first { $0.kind == .annotation }!.id
        let eraseOld = try prepare(changedLayout, round: shiftedRound, in: shifted)
        let stoppedErasure = Harness(changedLayout); stoppedErasure.start(eraseOld)
        stoppedErasure.advance { stoppedErasure.events.last?.type == .leftMouseDragged }
        stoppedErasure.engine.stop()
        require(changedLayout.records.first { $0.id == oldLabelID }?.completed == false,
                "一旦开始擦旧标记，停止后也不能继续把它视作完整标记")
        let restoreOldLayout = try prepare(changedLayout, round: pausePlan, in: area)
        require(restoreOldLayout.newAnnotations != nil && restoreOldLayout.erasedIDs.contains(oldLabelID),
                "恢复到旧布局也必须清理并补画可能残缺的标题序号")
        _ = run(restoreOldLayout, ledger: changedLayout, round: pausePlan, includeAnnotations: true)

        // 另一份未完成静态路径的记录墨迹，也可能与可以复用的标题重叠。
        let labelCollision = CalibrationAutomation()
        let distantSample = footprint([[CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.8, y: 0.7)]], in: area)
        let seed = try labelCollision.prepare(newFootprint: distantSample, area: area, targetPID: pid,
            penButton: pen, eraserButton: eraser, autoClear: true,
            persistentAnnotations: label)
        let seedRunner = Harness(labelCollision); seedRunner.start(seed); seedRunner.finish()
        let partialLabel = CalibrationInkRecord(footprint: sample, kind: .annotation)
        labelCollision.begin(CalibrationOperation(actions: [], erasedIDs: [], newInk: nil, newAnnotations: partialLabel))
        labelCollision.finish(completed: false)
        let fixLabels = try labelCollision.prepare(newFootprint: distantSample, area: area, targetPID: pid,
            penButton: pen, eraserButton: eraser, autoClear: true,
            persistentAnnotations: label)
        require(fixLabels.newAnnotations != nil && fixLabels.erasedIDs == Set(labelCollision.records.map(\.id)),
                "其他未完成字形的记录墨迹与标题重叠时，撤回复用并重建完整标题")
        // E 等待和延伸分两轮搜索，V 的线身反馈不会因为端点缺口被降速。
        let ending = UnifiedCalibration()
        let endingLedger = CalibrationAutomation()
        require(ending.setArea(area), "E测试共用同一块画布")
        let holdPlan = try ending.makeRound(brushWidth: brush,
                                            knownMovement: 3, releaseDelay: 0.14)
        let holdBatches = holdPlan.batches.filter { $0.metric == .ending }
        require(holdBatches.map { $0.releaseDelay! } == [0.12, 0.35, 0.8]
                && holdBatches.allSatisfy { $0.speed == 60 && $0.endExtension == 0 },
                "E初轮固定低速，只分别改变抬笔等待")
        _ = run(try prepare(endingLedger, round: holdPlan, in: area), ledger: endingLedger,
                round: holdPlan, includeAnnotations: true)
        require(ending.markDrawn(), "E等待三组完整绘制后再反馈")
        for metric in [CalibrationMetric.movement, .spacingX, .spacingY] {
            require(ending.select(metric: metric, index: 1), "其他三项独立确认")
        }
        require(ending.select(metric: .speed, index: 2) && ending.select(metric: .ending, index: nil),
                "线身最高速连续与E等待全部无效可以同时成立")
        require(ending.refine() && ending.endingMode == .extension
                && ending.candidates(for: .ending) == [0.5, 2, 8]
                && ending.confirmedValue(for: .speed) == 1350,
                "E等待无效只切换E扩展测试，不撤销线身速度确认")
        let extensionPlan = try ending.makeRound(brushWidth: brush,
                                                 knownMovement: 3, releaseDelay: 0.14)
        let extensionBatches = extensionPlan.batches.filter { $0.metric == .ending }
        require(extensionBatches.map(\.endExtension) == [0.5, 2, 8]
                && extensionBatches.allSatisfy { $0.speed == 60 && $0.releaseDelay == 0.14 },
                "E扩展阶段固定低速和原已知等待，只改变补偿距离")
        for batch in extensionBatches {
            let mapped = DrawingEngine.compensatedPaths(batch.paths, to: area, brushWidth: brush, endExtension: batch.endExtension)
            let intended = DrawingEngine.mapPaths(batch.paths, to: area, brushWidth: brush)
            for (actual, original) in zip(mapped, intended) {
                require(actual.count == original.count + 1 && Array(actual.dropLast()) == original,
                        "扩展保留原意图终点，追加一个真实尾点")
                require(abs(hypot(actual.last!.x - original.last!.x, actual.last!.y - original.last!.y) - batch.endExtension) < 0.000_001,
                        "每个E候选在有限画布上必须发送完整真实距离，不能靠夹紧坐标偷偷缩短")
            }
        }
        let extensionOperation = try prepare(endingLedger, round: extensionPlan, in: area)
        _ = run(extensionOperation, ledger: endingLedger, round: extensionPlan, includeAnnotations: false)
        require(ending.markDrawn(), "E扩展候选全部绘制完成")
        for metric in [CalibrationMetric.movement, .spacingX, .spacingY, .speed] {
            require(ending.select(metric: metric, index: 0), "保持各项独立反馈")
        }
        require(ending.selectEndingAllOverrun() && ending.refine()
                && ending.bounds(for: .ending) == 0...0.5
                && ending.candidates(for: .ending).last! == 0.5,
                "全部扩展过线时往0缩小，不把过大的尾距离继续扩大")
        let smaller = try ending.makeRound(brushWidth: brush,
                                          knownMovement: 3, releaseDelay: 0.14)
        let smallerOperation = try prepare(endingLedger, round: smaller, in: area)
        _ = run(smallerOperation, ledger: endingLedger, round: smaller, includeAnnotations: false)
        require(ending.markDrawn(), "更小E候选绘制完成")
        for metric in [CalibrationMetric.movement, .spacingX, .spacingY, .speed] {
            require(ending.select(metric: metric, index: 0), "其他搜索独立细化")
        }
        let chosenExtension = ending.candidates(for: .ending)[1]
        require(ending.select(metric: .ending, index: 1) && ending.refine()
                && ending.results?.endExtension == chosenExtension && ending.results?.releaseDelay == 0.14,
                "E只采用明确确认的最小完整不过线距离，不再增加可能过线的正余量")
        let adopted = try ending.makeRound(brushWidth: brush,
                                          knownMovement: 3, releaseDelay: 0.14)
        require(adopted.batches.filter { $0.metric == .movement || $0.metric == nil }.allSatisfy { $0.endExtension == 0 },
                "M实际位移与固定标题/终点参照线都不追加尾补偿")
        require(adopted.batches.filter { $0.metric == .spacingX || $0.metric == .spacingY || $0.metric == .speed }
                    .allSatisfy { $0.endExtension == chosenExtension },
                "已确认尾补偿应用于#和V的动态样本")

        // 在V意图终点暂停，恢复仅绘剩下的真实补偿尾段，账本登记同一最终轨迹。
        let adoptedOperation = try prepare(endingLedger, round: adopted, in: area)
        let erasedBeforeAdopted = erasedPaths(adoptedOperation, from: endingLedger)
        let tailBatch = adopted.batches.first { $0.metric == .speed }!
        let logicalTail = DrawingEngine.mapPaths(tailBatch.paths, to: area, brushWidth: brush)[0].last!
        let actualTail = DrawingEngine.compensatedPaths(tailBatch.paths, to: area, brushWidth: brush,
                                                       endExtension: tailBatch.endExtension)[0].last!
        let tailRunner = Harness(endingLedger)
        tailRunner.complete = { require(ending.markDrawn(), "补偿尾段及全部批次完成后才允许反馈") }
        tailRunner.start(adoptedOperation)
        tailRunner.advance {
            tailRunner.events.contains { $0.type == .leftMouseDown && close($0.point, pen) }
                && tailRunner.events.last?.type == .leftMouseDragged
                && close(tailRunner.events.last!.point, logicalTail)
        }
        require(tailRunner.engine.testInput(.mouseMoved) && tailRunner.engine.paused,
                "补偿尾段之前手动鼠标输入应暂停并立即抬笔")
        let tailPauseCount = tailRunner.events.count
        for _ in 0..<50 { tailRunner.tick() }
        require(tailRunner.events.count == tailPauseCount, "暂停时不能继续执行补偿尾段")
        tailRunner.engine.resume(countdown: 0); tailRunner.finish()
        let tailStrokes = tailRunner.strokes
        checkTool(tailStrokes.prefix(toolClicks), at: eraser)
        exact(Array(tailStrokes[toolClicks..<(erasedBeforeAdopted.count + toolClicks)]), erasedBeforeAdopted)
        checkTool(tailStrokes[(erasedBeforeAdopted.count + toolClicks)..<(erasedBeforeAdopted.count + 2 * toolClicks)], at: pen)
        let endpointDrags = tailRunner.events.filter { $0.type == .leftMouseDragged && close($0.point, actualTail) }
        require(endpointDrags.count == 1 && ending.hasDrawn,
                "恢复只追加一次补偿尾点，不能在恢复时把延伸距离再加一次")
        let adoptedInk = endingLedger.records.first { $0.kind == .test }!
        require(DrawingEngine.mapPaths(adoptedInk.footprint.paths, to: area, brushWidth: brush)
                    .contains { $0.last.map { close($0, actualTail) } == true },
                "账本包括暂停恢复后实际发送的扩展尾点")
        for metric in [CalibrationMetric.movement, .spacingX, .spacingY, .speed] {
            require(ending.select(metric: metric, index: 0), "零补偿仍与其他项目独立反馈")
        }
        require(ending.selectNoEndingCompensation() && ending.submitFeedback()
                && ending.results?.endExtension == 0 && ending.endingUsesZero,
                "用户明确选择无需补偿时严格采用0，不能偷偷变成正距离")

        // 清理真实补偿轨迹使用零扩展，即使绘制结果已设置非零补偿。
        let extensionCleanup = try prepare(endingLedger, round: nil, in: area)
        let extensionCleanupExpected = erasedPaths(extensionCleanup, from: endingLedger)
        let extensionCleaner = Harness(endingLedger); extensionCleaner.start(extensionCleanup); extensionCleaner.finish()
        checkTool(extensionCleaner.strokes.prefix(toolClicks), at: eraser)
        exact(Array(extensionCleaner.strokes.dropFirst(toolClicks).dropLast(toolClicks)), extensionCleanupExpected)
        checkTool(extensionCleaner.strokes.suffix(toolClicks), at: pen)
        require(!endingLedger.hasInk(in: area, targetPID: pid, includeAnnotations: false),
                "真实尾段全部清理后只留下标题，不能把橡皮路径再次扩展")

        // 搜索出的完整补偿候选在窄画布放不下时，不能把大距离截短后仍标成原候选。
        let bounded = UnifiedCalibration()
        let narrowArea = CGRect(x: -900, y: -100, width: 300, height: 550)
        require(bounded.setArea(narrowArea) && bounded.setEndingMode(.extension), "有限画布用于延伸搜索")
        _ = try bounded.makeRound(brushWidth: brush, knownMovement: 3)
        require(bounded.expandRanges(), "用户可以请求更大补偿区间")
        do {
            _ = try bounded.makeRound(brushWidth: brush, knownMovement: 3)
            fatalError("放不下完整延伸候选的画布必须明确拒绝")
        } catch UnifiedCalibrationError.areaTooSmall(let required) {
            require(required.width > narrowArea.width || required.height > narrowArea.height,
                    "不足尺寸说明包括完整补偿及固定测试留白")
        }
        require(!bounded.markDrawn(), "边界受限候选不能解锁反馈或成为已确认结果")
        print("PASS triple paced pen/eraser clicks before every batch / M/#/V/E flow / independent X-Y feedback / persistent titles without123 / profiled release holds / E waiting fallback to extension / overrun narrows to0 / exact actual tail ledger / pause-resume tail once / zero-extension cleanup / explicit zero compensation / annotation lifecycle and conservative interruption; no real events")
    }
}
