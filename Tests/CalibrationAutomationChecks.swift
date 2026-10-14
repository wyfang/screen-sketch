import AppKit
import ApplicationServices

@main struct CalibrationAutomationChecks {
    struct Event { let type: CGEventType; let point: CGPoint; let time: Double }
    struct Stroke { let points: [CGPoint] }
    static let area = CGRect(x: -300, y: 100, width: 600, height: 450)
    static let otherArea = CGRect(x: 400, y: 100, width: 600, height: 450)
    static let pen = CGPoint(x: -350, y: 40)
    static let eraser = CGPoint(x: -400, y: 40)
    static let target: pid_t = 4321
    static let toolClicks = 3
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.00001 }
    static func same(_ a: [[CGPoint]], _ b: [[CGPoint]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { left, right in
            left.count == right.count && zip(left, right).allSatisfy { close($0, $1) }
        }
    }

    final class Harness {
        let engine = DrawingEngine()
        let automation: CalibrationAutomation
        var events: [Event] = []
        var finishes: [Bool] = []
        var time = 0.0
        init(_ automation: CalibrationAutomation) {
            self.automation = automation
            engine.testClock = 0; engine.speed = 8000
            engine.testSink = { [weak self] type, point in
                guard let self else { return }
                self.events.append(Event(type: type, point: point, time: self.time))
                require(!self.engine.testInput(type, marked: true), "自身注入事件不可触发暂停")
            }
            engine.onFinish = { [weak self] complete in
                self?.finishes.append(complete)
                self?.automation.finish(completed: complete)
            }
        }
        func start(_ operation: CalibrationOperation) {
            require(engine.start(actions: operation.actions, transport: .foreground, targetPID: target, countdown: 0), "合法校准序列应能启动")
            automation.begin(operation)
        }
        func tick() { time += 0.004; engine.testTick(at: time) }
        func advance(until condition: () -> Bool) {
            for _ in 0..<30000 { if condition() { return }; tick() }
            fatalError("校准自动操作必须在虚拟时钟中结束")
        }
        func finish() { advance { !engine.running } }
        var strokes: [Stroke] {
            var result: [Stroke] = []
            var points: [CGPoint]?
            for event in events {
                switch event.type {
                case .leftMouseDown:
                    require(points == nil, "点击和笔画都不可重复down")
                    points = [event.point]
                case .leftMouseDragged:
                    require(points != nil, "拖动前必须down")
                    points!.append(event.point)
                case .leftMouseUp:
                    require(points != nil, "up前必须down")
                    result.append(Stroke(points: points!)); points = nil
                case .mouseMoved: require(points == nil, "抬笔后才能定位下一个动作")
                default: break
                }
            }
            require(points == nil, "停止或完成后不可留下按下状态")
            return result
        }
    }

    static func prepare(_ automation: CalibrationAutomation, _ footprint: CalibrationFootprint?,
                        in rect: CGRect = area, autoClear: Bool = true,
                        pid: pid_t = target) throws -> CalibrationOperation {
        try automation.prepare(newFootprint: footprint, area: rect, targetPID: pid,
            penButton: pen, eraserButton: eraser, autoClear: autoClear,
            minimumMovement: footprint?.longestSegmentLength ?? 0)
    }
    static func footprint(_ paths: [[CGPoint]], in rect: CGRect = area, pid: pid_t = target) -> CalibrationFootprint {
        let mapped = DrawingEngine.mapPaths(paths, to: rect, brushWidth: 2.5)
        let actual = mapped.map { $0.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) } }
        return CalibrationFootprint(paths: actual, area: rect, brushWidth: 2.5, targetPID: pid)
    }
    static func validateTool(_ strokes: ArraySlice<Stroke>, at point: CGPoint) {
        require(strokes.count == toolClicks && strokes.allSatisfy { $0.points.count == 1 && close($0.points[0], point) },
                "每次切换工具必须连续发送三次无拖动的完整点击")
    }
    static func validateBatch(_ strokes: ArraySlice<Stroke>, footprint: CalibrationFootprint) {
        let actual = strokes.map(\.points)
        let expected = DrawingEngine.mapPaths(footprint.paths, to: footprint.area, brushWidth: footprint.brushWidth)
        require(same(actual, expected), "实际发送的每段中心线、数字拐角及端点必须等于原计划")
    }
    @MainActor static func main() throws {
        let movement = MovementCalibration()
        require(movement.setArea(area), "位移测试区应有效")
        let firstFootprint = footprint(movement.numberedPaths(brushWidth: 2.5))
        require(firstFootprint.paths.count == 24 && firstFootprint.paths[0].count == 3, "测试必须包括真实序号和六组短线")
        let automation = CalibrationAutomation()
        let first = try prepare(automation, firstFootprint)
        require(first.erasedIDs.isEmpty && first.actions.count == 2, "第一轮仅切画笔再绘制，不应先橡皮擦")
        let firstRunner = Harness(automation); firstRunner.start(first); firstRunner.finish()
        let firstStrokes = firstRunner.strokes
        require(firstStrokes.count == firstFootprint.paths.count + toolClicks, "第一轮应先完成三次画笔点击，才开始全部测试笔迹")
        validateTool(firstStrokes.prefix(toolClicks), at: pen)
        validateBatch(firstStrokes.dropFirst(toolClicks), footprint: firstFootprint)
        require(automation.records.count == 1 && firstRunner.finishes == [true], "成功绘制应留下本轮记录")

        // 手动清理模式仍要使用已定位的画笔，不能继承目标软件当前可能选中的橡皮。
        let manual = CalibrationAutomation()
        let manualOperation = try prepare(manual, firstFootprint, autoClear: false)
        let manualRunner = Harness(manual); manualRunner.start(manualOperation); manualRunner.finish()
        require(manualOperation.erasedIDs.isEmpty && manualOperation.actions.count == 2,
                "关闭自动清理只跳过擦除，不跳过已定位画笔的切换")
        require(close(manualRunner.strokes.first!.points.first!, pen)
                && !manualRunner.events.contains { close($0.point, eraser) },
                "手动清理模式应只点击画笔，绝不点击橡皮")
        validateTool(manualRunner.strokes.prefix(toolClicks), at: pen)
        validateBatch(manualRunner.strokes.dropFirst(toolClicks), footprint: firstFootprint)
        let unlocated = try manual.prepare(newFootprint: firstFootprint, area: area, targetPID: target,
            penButton: nil, eraserButton: nil, autoClear: false)
        require(unlocated.actions.count == 1, "未定位工具时仍保留手动选择画笔的绘制方式")
        require(movement.markDrawn() && movement.selectShortestVisible(index: 3), "下一轮应由用户反馈推进")

        let secondFootprint = footprint(movement.numberedPaths(brushWidth: 2.5))
        let oldID = automation.records[0].id
        let second = try prepare(automation, secondFootprint)
        require(second.erasedIDs == [oldID] && second.actions.count == 4, "第二轮应包括擦除、原路径重放、画笔与新路径")
        let secondRunner = Harness(automation); secondRunner.start(second); secondRunner.finish()
        let secondStrokes = secondRunner.strokes
        let penIndex = firstFootprint.paths.count + toolClicks
        validateTool(secondStrokes.prefix(toolClicks), at: eraser)
        validateBatch(secondStrokes[toolClicks..<penIndex], footprint: firstFootprint)
        validateTool(secondStrokes[penIndex..<(penIndex + toolClicks)], at: pen)
        validateBatch(secondStrokes[(penIndex + toolClicks)...], footprint: secondFootprint)
        require(automation.records.map(\.id) == [second.newInk!.id], "成功后只移除旧记录，留下新一轮记录")

        // Cleaning alone erases every recorded numeral and test line, then restores the pen.
        let clean = try prepare(automation, nil)
        let cleanRunner = Harness(automation); cleanRunner.start(clean); cleanRunner.finish()
        let cleanStrokes = cleanRunner.strokes
        require(clean.newInk == nil && cleanStrokes.count == secondFootprint.paths.count + 2 * toolClicks, "单独清理不可新建笔迹记录")
        require(close(cleanStrokes[0].points[0], eraser) && close(cleanStrokes.last!.points[0], pen), "单独清理完成必须回到画笔")
        validateTool(cleanStrokes.prefix(toolClicks), at: eraser)
        validateTool(cleanStrokes.suffix(toolClicks), at: pen)
        validateBatch(cleanStrokes.dropFirst(toolClicks).dropLast(toolClicks), footprint: secondFootprint)
        require(automation.records.isEmpty, "完整清理后旧记录应移除")

        // A fresh rectangle does not trigger erasure of another region.
        let history = CalibrationAutomation()
        let seed = try prepare(history, firstFootprint)
        let seedRunner = Harness(history); seedRunner.start(seed); seedRunner.finish()
        let outside = footprint(secondFootprint.paths, in: otherArea)
        let fresh = try prepare(history, outside, in: otherArea)
        require(fresh.erasedIDs.isEmpty && fresh.actions.count == 2, "完全不同的空白区不能擦除旧区")
        let freshRunner = Harness(history); freshRunner.start(fresh); freshRunner.finish()
        require(!freshRunner.events.contains { close($0.point, eraser) } && history.records.count == 2, "新空白区不点击橡皮，历史记录仍保留")
        let outsideID = fresh.newInk!.id

        // Interrupt during erasure. Keep both old and conservatively planned new paths.
        let interrupted = try prepare(history, secondFootprint)
        let interruptedRunner = Harness(history); interruptedRunner.start(interrupted)
        interruptedRunner.advance { interruptedRunner.events.last?.type == .leftMouseDragged }
        let beforePause = interruptedRunner.events.count
        require(interruptedRunner.engine.testInput(.flagsChanged) && interruptedRunner.engine.paused, "修饰键应中断清理并释放")
        require(interruptedRunner.events.count == beforePause + 1 && interruptedRunner.events.last?.type == .leftMouseUp, "暂停必须立即释放当前橡皮笔画")
        let pausedCount = interruptedRunner.events.count
        for _ in 0..<40 { interruptedRunner.tick() }
        require(interruptedRunner.events.count == pausedCount && history.records.count == 3, "暂停不发送未来笔画，保守记录不能丢失")
        interruptedRunner.engine.resume(countdown: 0)
        interruptedRunner.advance { interruptedRunner.events.count > pausedCount }
        require(interruptedRunner.events[pausedCount].type == .mouseMoved, "继续清理先抬笔回到原暂停点")
        interruptedRunner.engine.stop()
        let stoppedCount = interruptedRunner.events.count
        for _ in 0..<40 { interruptedRunner.tick() }
        _ = interruptedRunner.strokes
        require(interruptedRunner.finishes == [false] && interruptedRunner.events.count == stoppedCount && history.records.count == 3, "停止后禁止后续输入，旧记录与新完整计划保留")

        let recovered = try prepare(history, firstFootprint)
        require(recovered.erasedIDs.count == 2 && !recovered.erasedIDs.contains(outsideID), "重试只重放当前区旧记录，不处理其他区")
        let recoveryRunner = Harness(history); recoveryRunner.start(recovered); recoveryRunner.finish()
        require(Set(history.records.map(\.id)) == [outsideID, recovered.newInk!.id], "下一次成功仅移除本次计划中的旧记录")

        let shifted = area.offsetBy(dx: 100, dy: 0)
        require(history.hasInk(in: shifted, targetPID: target), "移动或缩小后相交的测试区仍应能找到旧笔迹")
        let shiftedFootprint = footprint(firstFootprint.paths, in: shifted)
        let shiftedOperation = try prepare(history, shiftedFootprint, in: shifted)
        require(shiftedOperation.erasedIDs == [recovered.newInk!.id], "部分重叠应完整清理原测试区记录")
        let shiftedRunner = Harness(history); shiftedRunner.start(shiftedOperation); shiftedRunner.finish()
        let shiftedStrokes = shiftedRunner.strokes
        let shiftedPenIndex = firstFootprint.paths.count + toolClicks
        validateTool(shiftedStrokes.prefix(toolClicks), at: eraser)
        validateBatch(shiftedStrokes[toolClicks..<shiftedPenIndex], footprint: firstFootprint)
        validateTool(shiftedStrokes[shiftedPenIndex..<(shiftedPenIndex + toolClicks)], at: pen)
        validateBatch(shiftedStrokes[(shiftedPenIndex + toolClicks)...], footprint: shiftedFootprint)
        require(shiftedStrokes[toolClicks..<shiftedPenIndex].contains { stroke in
            stroke.points.contains { !shifted.contains($0) }
        }, "旧序号与测试线在新选区之外的部分也必须按原坐标重放，不可裁剪或搬移")
        require(Set(history.records.map(\.id)) == [outsideID, shiftedOperation.newInk!.id],
                "部分重叠清理只替换相交记录，保留不相交的记录")

        // A small incoming region can intersect multiple original areas. Clean each original
        // footprint completely, while disjoint rectangles and foreign processes remain untouched.
        let shortPaths = [[CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.3, y: 0.3)],
                          [CGPoint(x: 0.7, y: 0.6), CGPoint(x: 0.7, y: 0.7)]]
        let multiple = CalibrationAutomation()
        let originalA = footprint(shortPaths)
        let originalB = footprint(shortPaths, in: shifted)
        let disjoint = footprint(shortPaths, in: otherArea)
        let foreignAtA = footprint(shortPaths, pid: target + 1)
        for recorded in [originalA, originalB, disjoint, foreignAtA] {
            let operation = try prepare(multiple, recorded, in: recorded.area,
                                        autoClear: false, pid: recorded.targetPID)
            multiple.begin(operation); multiple.finish(completed: true)
        }
        let preservedIDs = Set(multiple.records.suffix(2).map(\.id))
        let subset = CGRect(x: -40, y: 200, width: 80, height: 150)
        require(multiple.hasInk(in: subset, targetPID: target), "小选区相交也应允许清理")
        let multiCleanup = try prepare(multiple, nil, in: subset)
        require(multiCleanup.erasedIDs == Set(multiple.records.prefix(2).map(\.id)) && multiCleanup.actions.count == 4,
                "匹配所有同一PID的相交旧区域，不以新矩形包含旧区域为条件")
        let multiRunner = Harness(multiple); multiRunner.start(multiCleanup); multiRunner.finish()
        validateTool(multiRunner.strokes.prefix(toolClicks), at: eraser)
        validateBatch(multiRunner.strokes[toolClicks..<(originalA.paths.count + toolClicks)], footprint: originalA)
        validateBatch(multiRunner.strokes[(originalA.paths.count + toolClicks)..<(originalA.paths.count + originalB.paths.count + toolClicks)],
                      footprint: originalB)
        validateTool(multiRunner.strokes.suffix(toolClicks), at: pen)
        require(Set(multiple.records.map(\.id)) == preservedIDs && !multiple.hasInk(in: subset, targetPID: target),
                "多区清理结束后保留不相交区和不同PID的记录")

        // Validate all recorded centerlines before any tool click, independent of eraser size.
        let validation = CalibrationAutomation()
        let malformed = CalibrationFootprint(paths: [[CGPoint(x: -0.01, y: 0.5)]],
            area: shifted, brushWidth: 2.5, targetPID: target)
        for recorded in [originalA, malformed] {
            let operation = try prepare(validation, recorded, in: recorded.area, autoClear: false)
            validation.begin(operation); validation.finish(completed: true)
        }
        let beforeValidation = validation.records.map(\.id)
        let validationHarness = Harness(validation)
        do {
            _ = try prepare(validation, nil, in: subset)
            fatalError("后续无效记录也必须在任何工具点击前拒绝")
        } catch let error as CalibrationCleanupError {
            require(error == .invalidPaths, "失败应来自无效记录的中心线")
        }
        require(validationHarness.events.isEmpty && validation.records.map(\.id) == beforeValidation,
                "全量预检失败不可发送输入或移除任何旧记录")

        // A unified round records one complete footprint while retaining per-group actions.
        let grouped = CalibrationAutomation()
        let groupedSeed = try prepare(grouped, originalA)
        grouped.begin(groupedSeed); grouped.finish(completed: true)
        let groupActions: [DrawingAction] = [
            .strokes(paths: [shortPaths[0]], rect: area, brushWidth: 2.5, minimumMovement: 100),
            .strokes(paths: [shortPaths[1]], rect: area, brushWidth: 2.5, minimumMovement: 200)
        ]
        let groupedRound = try grouped.prepare(newFootprint: originalA, area: area, targetPID: target,
            penButton: pen, eraserButton: eraser, autoClear: true,
            drawingActions: groupActions)
        require(groupedRound.actions.count == 5 && groupedRound.newInk!.footprint.paths == shortPaths,
                "联合测试账本保留全部笔迹，动作则保留调用方提供的各组参数")
        for (index, expectedMinimum) in [(3, 100.0), (4, 200.0)] {
            guard case .strokes(let paths, let rect, let brushWidth, let minimum) = groupedRound.actions[index] else {
                fatalError("自定义测试组必须原样追加在切回画笔之后")
            }
            require(paths == [shortPaths[index - 3]] && rect == area && brushWidth == 2.5 && minimum == expectedMinimum,
                    "联合校准不能把每组参数重置为一份默认笔画动作")
        }
        let groupedRunner = Harness(grouped); groupedRunner.start(groupedRound); groupedRunner.finish()
        validateTool(groupedRunner.strokes.prefix(toolClicks), at: eraser)
        validateBatch(groupedRunner.strokes[toolClicks..<(shortPaths.count + toolClicks)], footprint: originalA)
        validateTool(groupedRunner.strokes[(shortPaths.count + toolClicks)..<(shortPaths.count + 2 * toolClicks)], at: pen)
        validateBatch(groupedRunner.strokes[(shortPaths.count + 2 * toolClicks)...], footprint: originalA)
        require(grouped.records.map(\.id) == [groupedRound.newInk!.id], "联合测试成功后只留一份完整新账本")

        // Shared geometry also supports changing from spacing X to Y without orphaning X labels.
        let spacing = SpacingCalibration()
        require(spacing.setArea(area), "间距测试区应有效")
        let x = footprint(spacing.numberedPaths(brushWidth: 2.5, minimumMovement: 3))
        require(x.paths.count == 42, "X测试包含六个序号及每组三对线")
        let shared = CalibrationAutomation()
        let xOperation = try prepare(shared, x)
        let xRunner = Harness(shared); xRunner.start(xOperation); xRunner.finish()
        require(spacing.markDrawn(), "X完整绘制后才允许反馈")
        spacing.axis = .y
        let y = footprint(spacing.numberedPaths(brushWidth: 2.5, minimumMovement: 3))
        require(y.paths.count == 42 && !same(x.paths, y.paths), "Y必须生成另一方向真实线对")
        let yOperation = try prepare(shared, y)
        let yRunner = Harness(shared); yRunner.start(yOperation)
        yRunner.advance { yRunner.events.last?.type == .leftMouseDown && close(yRunner.events.last!.point, eraser) }
        require(yRunner.engine.testInput(.mouseMoved) && yRunner.engine.paused, "切到橡皮按下边界也应暂停")
        yRunner.engine.resume(countdown: 0); yRunner.finish()
        let yStrokes = yRunner.strokes
        require(yStrokes.filter { close($0.points[0], eraser) }.count == toolClicks, "暂停恢复保持原三次点击计划，不重复已发送的橡皮点击")
        validateTool(yStrokes.prefix(toolClicks), at: eraser)
        validateBatch(yStrokes[toolClicks..<(x.paths.count + toolClicks)], footprint: x)
        validateTool(yStrokes[(x.paths.count + toolClicks)..<(x.paths.count + 2 * toolClicks)], at: pen)
        validateBatch(yStrokes[(x.paths.count + 2 * toolClicks)...], footprint: y)
        require(shared.records.map(\.id) == [yOperation.newInk!.id] && spacing.markDrawn(), "切Y成功应删X记录并保留Y，允许Y反馈")

        // A record belonging to another process at the same screen geometry is never erased.
        let differentTarget = CalibrationAutomation()
        let foreign = footprint(firstFootprint.paths, pid: target + 1)
        let foreignOperation = try prepare(differentTarget, foreign, pid: target + 1)
        differentTarget.begin(foreignOperation); differentTarget.finish(completed: true)
        let localOperation = try prepare(differentTarget, firstFootprint)
        require(localOperation.erasedIDs.isEmpty && localOperation.actions.count == 2, "同一区域不同目标PID不共享擦除记录")
        differentTarget.begin(localOperation); differentTarget.finish(completed: true)
        differentTarget.forgetInk(overlapping: area, targetPID: target)
        require(differentTarget.records.map(\.footprint.targetPID) == [target + 1], "正式绘制会撤掉可能覆盖新作品的旧测试记录，同时保留其他进程")

        // A line four screen points from the border formerly imposed a six-point eraser limit.
        // Actual eraser size is unknown to this app; original centers remain exact.
        let nearBorder = CalibrationFootprint(
            paths: [[CGPoint(x: 4 / area.width, y: 0.5), CGPoint(x: 0.5, y: 0.5)]],
            area: area, brushWidth: 2, targetPID: target)
        let edgeHistory = CalibrationAutomation()
        let edgeFirst = try prepare(edgeHistory, nearBorder)
        let edgeFirstRunner = Harness(edgeHistory); edgeFirstRunner.start(edgeFirst); edgeFirstRunner.finish()
        let edgeSecond = try prepare(edgeHistory, nearBorder)
        guard case .profiledStrokes(let replayPaths, let replayRect, let mappingWidth,
            _, _, _, _, let extensionDistance) = edgeSecond.actions[1] else {
            fatalError("清理必须重放记录的中心线")
        }
        require(replayPaths == nearBorder.paths && replayRect == area && mappingWidth == 2 && extensionDistance == 0,
                "清理用原笔宽保持坐标映射，实际橡皮宽度来自画板，且不额外延长笔迹")
        let edgeSecondRunner = Harness(edgeHistory); edgeSecondRunner.start(edgeSecond); edgeSecondRunner.finish()
        validateTool(edgeSecondRunner.strokes.prefix(toolClicks), at: eraser)
        validateBatch(edgeSecondRunner.strokes[toolClicks..<(toolClicks + 1)], footprint: nearBorder)
        validateTool(edgeSecondRunner.strokes[(toolClicks + 1)..<(2 * toolClicks + 1)], at: pen)
        require(close(edgeSecondRunner.strokes[toolClicks].points[0], CGPoint(x: area.minX + 4, y: area.midY)),
                "靠近边界的清理中心线不可被假定的橡皮尺寸推走")
        print("PASS triple tool selections before all erase/draw paths / first round pen / numbered paths exact / second round erase-old-pen-new / cleanup restores pen / conservative interrupted records / partial overlap replays original paths / multiple intersecting originals / disjoint and foreign target untouched / recorded centerlines validated before input / target-controlled eraser size / grouped drawing actions retained / spacing X to Y shared-area / pause-resume-stop no real events")
    }
}
