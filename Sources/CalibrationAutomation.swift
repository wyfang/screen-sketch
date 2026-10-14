import AppKit

struct CalibrationInkRecord {
    enum Kind { case test, annotation }
    let id = UUID()
    let footprint: CalibrationFootprint
    var kind: Kind = .test
    var completed = false
}

struct CalibrationOperation {
    let actions: [DrawingAction]
    let erasedIDs: Set<UUID>
    let newInk: CalibrationInkRecord?
    var newAnnotations: CalibrationInkRecord? = nil
}

/// 只记录本次启动的测试路径。失败/中断保留保守的完整计划，成功才撤掉旧记录。
final class CalibrationAutomation {
    private(set) var records: [CalibrationInkRecord] = []
    private var pending: CalibrationOperation?

    enum AutomationError: LocalizedError {
        case missingButtons, noRecordedInk, annotationConflict
        var errorDescription: String? {
            switch self {
            case .missingButtons: return "请先指定目标软件的画笔、橡皮擦按钮，或关闭自动清理。"
            case .noRecordedInk: return "当前测试区没有本次启动记录的测试笔迹。"
            case .annotationConflict: return "记录的测试笔迹与固定标题重叠，请重新绘制校准标题后重试。"
            }
        }
    }

    func prepare(newFootprint: CalibrationFootprint?, area: CGRect, targetPID: pid_t,
                 penButton: CGPoint?, eraserButton: CGPoint?,
                 autoClear: Bool, minimumMovement: Double = 0,
                 drawingActions: [DrawingAction]? = nil,
                 persistentAnnotations: CalibrationFootprint? = nil,
                 annotationActions: [DrawingAction]? = nil,
                 preserveAnnotations: Bool = false) throws -> CalibrationOperation {
        // 新选区可以移动或缩小；重叠只用于找记录，不改变旧笔画的坐标或擦除边界。
        // 每份记录仍须在原测试区内通过中心线及原画笔映射检查。
        let matching = records.filter { $0.footprint.targetPID == targetPID && area.intersects($0.footprint.area) }
        // 只有完整完成且坐标、字形及笔宽相同的固定标记才可沿用。
        // 中断时记录了完整计划，却不能据此认为标记已经画全。
        var retained = matching.filter { record in
            guard record.kind == .annotation, record.completed else { return false }
            if let annotations = persistentAnnotations {
                return Self.sameFootprint(record.footprint, annotations)
            }
            return preserveAnnotations
        }
        if autoClear {
            // 记录的旧笔迹若与固定标记重叠，撤回复用并重画标记。
            // 只检查已知笔迹的占用范围；实际橡皮宽度由目标画板控制。
            let originalCount = retained.count
            var previousCount: Int
            repeat {
                previousCount = retained.count
                let protectedIDs = Set(retained.map(\.id))
                let erasures = matching.filter { !protectedIDs.contains($0.id) }
                retained.removeAll { annotation in
                    erasures.contains { record in
                        Self.inkOverlaps(record.footprint, annotation: annotation.footprint)
                    }
                }
            } while retained.count != previousCount
            if preserveAnnotations && persistentAnnotations == nil && retained.count != originalCount {
                throw AutomationError.annotationConflict
            }
        }
        let retainedIDs = Set(retained.map(\.id))
        let toErase = matching.filter { !retainedIDs.contains($0.id) }
        let needsAnnotations = persistentAnnotations != nil && retained.isEmpty
        var actions: [DrawingAction] = []
        var erased = Set<UUID>()
        if autoClear {
            guard penButton != nil, let eraserButton else { throw AutomationError.missingButtons }
            if !toErase.isEmpty {
                // 在任何点击前验证全部擦除计划，不能执行到一半才发现后续路径不安全。
                let replay = try toErase.map { record in
                    (record, try CalibrationCleanup.replay(footprint: record.footprint))
                }
                // 首次点击可能只激活目标窗口，工具选择独立发送三次完整点击。
                actions.append(.selectTool(eraserButton))
                for (record, paths) in replay {
                    // 复用原笔宽仅为保持原屏幕中心线；不控制目标橡皮的实际尺寸。
                    actions.append(.profiledStrokes(paths: paths, rect: record.footprint.area, brushWidth: record.footprint.brushWidth,
                        minimumMovement: record.footprint.longestSegmentLength, speed: nil,
                        pressDelay: 0.12, releaseDelay: 0.12, endExtension: 0))
                    erased.insert(record.id)
                }
            } else if newFootprint == nil { throw AutomationError.noRecordedInk }
        } else if newFootprint == nil { throw AutomationError.noRecordedInk }
        // 自动清理只决定是否擦旧笔迹。已定位画笔时，手动清理模式也必须先切回画笔。
        if let penButton { actions.append(.selectTool(penButton)) }
        let record = newFootprint.map { CalibrationInkRecord(footprint: $0) }
        var annotationRecord: CalibrationInkRecord?
        if needsAnnotations, let annotations = persistentAnnotations {
            annotationRecord = CalibrationInkRecord(footprint: annotations, kind: .annotation)
            if let annotationActions { actions.append(contentsOf: annotationActions) }
            else {
                actions.append(.strokes(paths: annotations.paths, rect: annotations.area,
                    brushWidth: annotations.brushWidth, minimumMovement: annotations.longestSegmentLength))
            }
        }
        if let newFootprint {
            // 联合校准使用同一份完整笔迹账本，但各测试组可以有自己的速度等绘制参数。
            if let drawingActions { actions.append(contentsOf: drawingActions) }
            else {
                actions.append(.strokes(paths: newFootprint.paths, rect: newFootprint.area,
                                        brushWidth: newFootprint.brushWidth, minimumMovement: minimumMovement))
            }
        }
        return CalibrationOperation(actions: actions, erasedIDs: erased, newInk: record,
                                    newAnnotations: annotationRecord)
    }

    func begin(_ operation: CalibrationOperation) {
        pending = operation
        for index in records.indices where operation.erasedIDs.contains(records[index].id) {
            records[index].completed = false
        }
        if let record = operation.newAnnotations { records.append(record) }
        if let record = operation.newInk { records.append(record) }
    }
    func finish(completed: Bool) {
        if completed, let pending {
            records.removeAll { pending.erasedIDs.contains($0.id) }
            let added = [pending.newInk?.id, pending.newAnnotations?.id].compactMap { $0 }
            for index in records.indices where added.contains(records[index].id) { records[index].completed = true }
        }
        pending = nil
    }
    func hasInk(in area: CGRect, targetPID: pid_t, includeAnnotations: Bool = true) -> Bool {
        records.contains { (includeAnnotations || $0.kind == .test) && $0.footprint.targetPID == targetPID && area.intersects($0.footprint.area) }
    }
    /// 正式绘制后，旧测试路径可能已经覆盖新作品，不能再据此自动擦除。
    func forgetInk(overlapping area: CGRect, targetPID: pid_t) {
        records.removeAll { $0.footprint.targetPID == targetPID && $0.footprint.area.intersects(area) }
    }

    private static func sameFootprint(_ a: CalibrationFootprint, _ b: CalibrationFootprint) -> Bool {
        a.targetPID == b.targetPID && a.area == b.area && a.brushWidth == b.brushWidth && a.paths == b.paths
    }
    private static func inkOverlaps(_ test: CalibrationFootprint, annotation: CalibrationFootprint) -> Bool {
        func segments(_ footprint: CalibrationFootprint) -> [(CGPoint, CGPoint)] {
            footprint.paths.flatMap { path -> [(CGPoint, CGPoint)] in
                let points = path.map { CGPoint(x: footprint.area.minX + $0.x * footprint.area.width,
                                                y: footprint.area.minY + $0.y * footprint.area.height) }
                if points.count == 1 { return [(points[0], points[0])] }
                return Array(zip(points, points.dropFirst()))
            }
        }
        func pointDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            let t = length2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        func distance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y, ex = d.x - c.x, ey = d.y - c.y
            let cross = dx * ey - dy * ex
            if cross != 0 {
                let t = ((c.x - a.x) * ey - (c.y - a.y) * ex) / cross
                let u = ((c.x - a.x) * dy - (c.y - a.y) * dx) / cross
                if t >= 0 && t <= 1 && u >= 0 && u <= 1 { return 0 }
            }
            return min(pointDistance(a, c, d), pointDistance(b, c, d),
                       pointDistance(c, a, b), pointDistance(d, a, b))
        }
        let clearance = (test.brushWidth + annotation.brushWidth) / 2 + 1
        let annotations = segments(annotation)
        return segments(test).contains { a, b in
            annotations.contains { c, d in distance(a, b, c, d) <= clearance }
        }
    }
}
