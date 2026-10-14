import AppKit
import SwiftUI

/// 五项反馈共用四个分区和一块 Quartz 屏幕点测试区；只生成路径和管理人工反馈。
enum CalibrationMetric: String, CaseIterable, Identifiable {
    case movement, spacingX, spacingY, speed, ending

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .movement: return "M"
        case .spacingX: return "X"
        case .spacingY: return "Y"
        case .speed: return "V"
        case .ending: return "E"
        }
    }
    var title: String {
        switch self {
        case .movement: return "M 最小位移"
        case .spacingX: return "X 横向间距"
        case .spacingY: return "Y 纵向间距"
        case .speed: return "V 线身速度"
        case .ending: return "E 收笔"
        }
    }
    var unit: String { self == .speed ? "点/秒" : "点" }
}

enum CalibrationSelection: Equatable {
    case row(Int)
    case none
    case noCompensation
    case overrun
}

enum CalibrationEndingMode: String, CaseIterable, Identifiable {
    case hold
    case `extension`
    var id: String { rawValue }
    var title: String { self == .hold ? "抬笔等待" : "末端延伸" }
    var unit: String { self == .hold ? "秒" : "点" }
}

struct UnifiedCalibrationResult {
    let movement: Double
    let spacingX: Double
    let spacingY: Double
    let speed: Double
    let releaseDelay: Double
    let endExtension: Double

    init(movement: Double, spacingX: Double, spacingY: Double, speed: Double,
         releaseDelay: Double = 0.12, endExtension: Double = 0) {
        self.movement = movement; self.spacingX = spacingX; self.spacingY = spacingY; self.speed = speed
        self.releaseDelay = releaseDelay; self.endExtension = endExtension
    }
}

struct UnifiedCalibrationBatch {
    /// nil 使用稳定的参照速度；isAnnotation 区分保留的标记与每轮清理的速度 guides。
    let metric: CalibrationMetric?
    let paths: [[CGPoint]]
    let speed: Double
    let minimumMovement: Double
    let isAnnotation: Bool
    let releaseDelay: Double?
    let endExtension: Double

    init(metric: CalibrationMetric?, paths: [[CGPoint]], speed: Double,
         minimumMovement: Double, isAnnotation: Bool = false,
         releaseDelay: Double? = nil, endExtension: Double = 0) {
        self.metric = metric
        self.paths = paths
        self.speed = speed
        self.minimumMovement = minimumMovement
        self.isAnnotation = isAnnotation
        self.releaseDelay = releaseDelay
        self.endExtension = endExtension
    }

    /// 返回实际发送的归一化路径，供擦除记录使用；末段按屏幕点方向延长。
    func compensatedPaths(in area: CGRect) -> [[CGPoint]] {
        guard endExtension > 0, area.width > 0, area.height > 0 else { return paths }
        return paths.map { path in
            guard let last = path.last else { return path }
            for pair in zip(path, path.dropFirst()).reversed() {
                let dx = (pair.1.x - pair.0.x) * area.width
                let dy = (pair.1.y - pair.0.y) * area.height
                let length = hypot(dx, dy)
                if length > 0 {
                    return path + [CGPoint(x: last.x + dx / length * endExtension / area.width,
                                           y: last.y + dy / length * endExtension / area.height)]
                }
            }
            return path
        }
    }
}

struct UnifiedCalibrationAnnotationSignature: Equatable {
    let area: CGRect
    let brushWidth: Double
    let paths: [[CGPoint]]
}

struct UnifiedCalibrationRound {
    let area: CGRect
    let paths: [[CGPoint]]
    /// 仅固定 M/#/V/E 标题，不再向画布绘制数字。
    let annotationPaths: [[CGPoint]]
    /// 候选测试线和速度两端参照线；下一轮只重放这些路径擦除。
    let testPaths: [[CGPoint]]
    /// 包括实际延伸尾段的清理路径；testPaths 仍保留原始意图终点。
    let actualTestPaths: [[CGPoint]]
    let annotationSignature: UnifiedCalibrationAnnotationSignature
    let batches: [UnifiedCalibrationBatch]
    let requiredSize: CGSize
}

enum UnifiedCalibrationError: LocalizedError {
    case missingArea, invalidParameters, alreadyDrawn, unrepresentableRange
    case areaTooSmall(CGSize)

    var errorDescription: String? {
        switch self {
        case .missingArea: return "请先在主界面设置画布；全部校准直接使用该画布。"
        case .invalidParameters: return "画笔宽度、最小位移或收笔等待无效，请填写有效值。"
        case .alreadyDrawn: return "本轮已画完，请同时提交全部反馈，或选择重画本轮。"
        case .unrepresentableRange: return "当前区间已达到机器数值精度，请采用已确认结果或扩大区间。"
        case .areaTooSmall(let size):
            return "测试区太小，本轮全部测试需要至少 \(UnifiedCalibration.format(ceil(size.width))) × \(UnifiedCalibration.format(ceil(size.height))) 屏幕点。请在主界面设置更大的画布；测试长度和中心距不会被缩放。"
        }
    }
}

@MainActor
final class UnifiedCalibration: ObservableObject {
    private struct Search {
        var lower: Double
        var upper: Double
        var values: [Double]
        var confirmed: Double?
        var candidateLower = 0.0
    }

    @Published private(set) var area: CGRect?
    @Published private(set) var round = 1
    @Published private(set) var hasDrawn = false
    @Published private(set) var feedbackSubmitted = false
    @Published private(set) var selections: [CalibrationMetric: CalibrationSelection] = [:]
    @Published private(set) var message = "主画布上排 M/#、下排 V/E；每格从上到下三组，同时测位移、间距、线身速度和收笔。"
    @Published private(set) var endingMode: CalibrationEndingMode = .hold
    @Published private(set) var endingTestSpeed = 60.0
    @Published var automaticCleanup = false
    @Published private var searches = UnifiedCalibration.initialSearches()
    private var pathsPrepared = false
    private var testedBrushWidth: Double?
    private var testedMovement: Double?
    private var fixedAnnotationScale: Double?
    private var testedReleaseDelay: Double?
    private var baseReleaseDelay = 0.12
    private var endingZeroChosen = false
    private var pendingEndingFallback = false

    var canSubmitFeedback: Bool {
        hasDrawn && !feedbackSubmitted && CalibrationMetric.allCases.allSatisfy { selections[$0] != nil }
    }
    var cleanupInstruction: String {
        automaticCleanup ? "下一轮仅擦除测试线，M/#/V/E 标题保留。" : "下一轮前请仅清除旧测试线，保留 M/#/V/E 标题。"
    }
    var results: UnifiedCalibrationResult? {
        guard let movement = searches[.movement]?.confirmed,
              let x = searches[.spacingX]?.confirmed,
              let y = searches[.spacingY]?.confirmed,
              let speed = searches[.speed]?.confirmed,
              searches[.ending]?.confirmed != nil || endingZeroChosen else { return nil }
        let policy = endingPolicy
        return UnifiedCalibrationResult(movement: Self.margin(movement), spacingX: Self.margin(x),
                                        spacingY: Self.margin(y), speed: speed * 0.9,
                                        releaseDelay: policy.releaseDelay, endExtension: policy.endExtension)
    }

    func candidates(for metric: CalibrationMetric) -> [Double] { searches[metric]!.values }
    func bounds(for metric: CalibrationMetric) -> ClosedRange<Double> {
        let search = searches[metric]!
        return search.lower...search.upper
    }
    func confirmedValue(for metric: CalibrationMetric) -> Double? { searches[metric]?.confirmed }
    /// 采用本模型的位移结果后，只更新事件步长依据，不把自己的结果误认为换了画笔。
    func acknowledgeAppliedMovement(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        testedMovement = value
    }

    var endingUsesZero: Bool { endingZeroChosen }
    var endingMatchesAdoptedSpeed: Bool {
        guard let speed = searches[.speed]?.confirmed else { return false }
        return abs(endingTestSpeed - speed * 0.9) <= max(0.000_001, endingTestSpeed * 0.000_001)
    }
    /// 先用慢速辨别机制，选用前在实际采用的速度重新测试 E；其他候选及结果保持。
    @discardableResult
    func setEndingTestSpeed(_ speed: Double) -> Bool {
        guard speed.isFinite, speed > 0 else { return false }
        guard speed != endingTestSpeed else { return true }
        endingTestSpeed = speed
        searches[.ending] = Self.initialEndingSearch(endingMode)
        endingZeroChosen = false
        pendingEndingFallback = false
        round += 1
        invalidateDrawing()
        message = "E 将按采用速度 \(Self.format(speed)) 点/秒复测。M/#/V 候选不变，请核对后仍选择原先合格组，再确认 E 最小齐线且不过线组。"
        return true
    }
    private var endingPolicy: (releaseDelay: Double, endExtension: Double) {
        guard !endingZeroChosen, let value = searches[.ending]?.confirmed else { return (baseReleaseDelay, 0) }
        return endingMode == .hold ? (value, 0) : (baseReleaseDelay, value)
    }
    func unit(for metric: CalibrationMetric) -> String { metric == .ending ? endingMode.unit : metric.unit }
    func acknowledgeAppliedEnding(releaseDelay: Double, endExtension: Double) {
        guard releaseDelay.isFinite, releaseDelay >= 0, endExtension.isFinite, endExtension >= 0 else { return }
        testedReleaseDelay = releaseDelay
        baseReleaseDelay = releaseDelay
    }
    @discardableResult
    func setEndingMode(_ mode: CalibrationEndingMode) -> Bool {
        guard mode != endingMode else { return true }
        endingMode = mode
        searches[.ending] = Self.initialEndingSearch(mode)
        endingZeroChosen = false
        pendingEndingFallback = false
        round += 1
        invalidateDrawing()
        message = "E 已切换到\(mode.title)，其他已确认结果保留，下一轮重新绘制全部测试线。" + cleanupInstruction
        return true
    }
    @discardableResult
    func selectNoEndingCompensation() -> Bool {
        guard hasDrawn, !feedbackSubmitted else { return false }
        selections[.ending] = .noCompensation
        return true
    }
    @discardableResult
    func selectEndingAllOverrun() -> Bool {
        guard hasDrawn, !feedbackSubmitted, endingMode == .extension else { return false }
        selections[.ending] = .overrun
        return true
    }

    @discardableResult
    func setArea(_ rect: CGRect?) -> Bool {
        invalidateDrawing()
        guard let rect, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            area = nil
            message = "主画布无效，请在主界面重新设置画布。"
            return false
        }
        area = rect
        message = "已使用主界面画布，全部校准共用该画布。" + cleanupInstruction
        return true
    }

    /// nil 表示这一项的三组都不合格；未点击任何项与明确选择“全部不清晰”不同。
    @discardableResult
    func select(metric: CalibrationMetric, index: Int?) -> Bool {
        guard hasDrawn, !feedbackSubmitted else {
            message = "请完整绘制本轮后，再同时选择全部反馈。"
            return false
        }
        if let index {
            guard candidates(for: metric).indices.contains(index) else {
                message = "组号无效，请选择本轮的 1、2 或 3 组。"
                return false
            }
            selections[metric] = .row(index)
        } else {
            selections[metric] = CalibrationSelection.none
        }
        return true
    }

    /// 一次性提交全部反馈，保留当前画布和候选供核对；不自动终止校准。
    @discardableResult
    func submitFeedback() -> Bool {
        guard canSubmitFeedback else {
            message = "请选择 M、X、Y 最小清晰组、V 最快线身连续组，以及 E 最小完整且不过线组。"
            return false
        }
        var next = searches
        var nextZero = endingZeroChosen
        var fallback = false
        for metric in CalibrationMetric.allCases {
            var search = next[metric]!
            switch selections[metric]! {
            case .row(let index):
                let value = search.values[index]
                if metric == .speed {
                    let upper = index + 1 < search.values.count ? search.values[index + 1] : value * 3
                    guard upper.isFinite, upper > value else { message = UnifiedCalibrationError.unrepresentableRange.localizedDescription; return false }
                    let previous = search.confirmed.flatMap { $0 < upper ? $0 : nil }
                    search.confirmed = max(previous ?? value, value)
                    search.lower = value; search.upper = upper
                } else {
                    search.lower = index == 0 ? search.candidateLower : search.values[index - 1]
                    search.upper = value
                    search.confirmed = value
                }
                if metric == .ending { nextZero = false }
            case .none:
                if metric == .speed {
                    let upper = search.values[0]
                    let previous = search.confirmed.flatMap { $0 < upper ? $0 : nil }
                    search.confirmed = previous; search.lower = previous ?? 0; search.upper = upper
                } else if metric == .ending && endingMode == .hold {
                    // 等待全部无效时转换测延伸，不把尚未成功的 .8 秒擅自应用。
                    search.confirmed = nil
                    nextZero = false
                    fallback = true
                } else {
                    let lower = search.values.last!, upper = search.values.last! * 2
                    guard upper.isFinite, upper > lower else { message = UnifiedCalibrationError.unrepresentableRange.localizedDescription; return false }
                    search.confirmed = search.confirmed.flatMap { $0 > lower ? $0 : nil }
                    search.lower = lower; search.upper = upper
                    if metric == .ending { nextZero = false }
                }
            case .noCompensation:
                guard metric == .ending else { return false }
                search.confirmed = 0
                nextZero = true
            case .overrun:
                guard metric == .ending, endingMode == .extension else { return false }
                search.lower = 0
                search.upper = search.values[0]
                search.confirmed = nil
                nextZero = false
            }
            next[metric] = search
        }
        searches = next
        endingZeroChosen = nextZero
        pendingEndingFallback = fallback
        feedbackSubmitted = true
        message = fallback
            ? "E 三组等待均无效；下一轮将改测末端延伸，继续使用原本抬笔等待。"
            : results == nil ? "反馈已提交；还有未确认项目，可同时进入下一轮。"
                : "全部结果已确认，可结束并采用，也可继续细化；没有预设轮数终点。"
        return true
    }

    /// 确认只提交当前反馈并读取合格结果；细化或按采用速度复测必须由用户单独发起。
    func resultForApplication() -> UnifiedCalibrationResult? {
        if hasDrawn && !feedbackSubmitted {
            guard submitFeedback() else { return nil }
        }
        guard let result = results else {
            if !hasDrawn && !feedbackSubmitted {
                message = "尚无完整确认结果，请先完整绘制本轮并选择全部反馈。"
            } else {
                message = "还有未确认合格结果的项目，暂时不能结束并采用；请选择合格组，或主动进入下一轮继续测试。"
            }
            return nil
        }
        return result
    }

    /// 逐项夹逼：距离找最小清晰值，速度找最快完整值。没有 .25 点或轮数终止条件。
    @discardableResult
    func refine() -> Bool {
        if !feedbackSubmitted, !submitFeedback() { return false }
        var next = searches
        do {
            for metric in CalibrationMetric.allCases {
                if metric == .ending && pendingEndingFallback {
                    next[metric] = Self.initialEndingSearch(.extension)
                    continue
                }
                if metric == .ending && endingZeroChosen { continue }
                var search = next[metric]!
                search.values = try Self.thirds(lower: search.lower, upper: search.upper)
                search.candidateLower = search.lower
                next[metric] = search
            }
        } catch {
            message = error.localizedDescription
            return false
        }
        searches = next
        if pendingEndingFallback { endingMode = .extension }
        pendingEndingFallback = false
        round += 1
        invalidateDrawing()
        message = "第 \(round) 轮已准备好；同时细化；距离未清晰则扩大，速度未连续则降低，E 单独判断末端。" + cleanupInstruction
        return true
    }

    /// 可以主动重新搜索更大位移、间距及更高速度，保留已经确认的结果。
    @discardableResult
    func expandRanges() -> Bool {
        var next = searches
        do {
            for metric in CalibrationMetric.allCases {
                if metric == .ending && endingZeroChosen { continue }
                var search = next[metric]!
                var upper = max(search.upper, search.values.last!) * (metric == .speed ? 3 : 2)
                if metric == .ending && endingMode == .hold { upper = min(5, upper) }
                guard upper.isFinite else { throw UnifiedCalibrationError.unrepresentableRange }
                search.lower = metric == .speed ? (search.confirmed ?? 0) : 0
                search.upper = upper
                search.values = try Self.thirds(lower: search.lower, upper: upper)
                search.candidateLower = search.lower
                next[metric] = search
            }
        } catch { message = error.localizedDescription; return false }
        searches = next
        round += 1
        invalidateDrawing()
        message = "全部搜索区间已扩大，已确认结果仍可采用。" + cleanupInstruction
        return true
    }

    @discardableResult
    func repeatRound() -> Bool {
        invalidateDrawing()
        message = "本轮候选保持不变，可以清理后重画。" + cleanupInstruction
        return true
    }

    func retest() {
        searches = Self.initialSearches()
        round = 1
        testedBrushWidth = nil
        testedMovement = nil
        testedReleaseDelay = nil
        endingMode = .hold
        endingTestSpeed = 60
        endingZeroChosen = false
        pendingEndingFallback = false
        fixedAnnotationScale = nil
        invalidateDrawing()
        message = "已重新开始全部校准，测试区保持不变。" + cleanupInstruction
    }

    /// 固定标记单独记录，动态测试线及速度参照线保留独立的清理路径。
    func makeRound(brushWidth: Double, knownMovement: Double, releaseDelay: Double = 0.12) throws -> UnifiedCalibrationRound {
        pathsPrepared = false
        do {
            guard let area else { throw UnifiedCalibrationError.missingArea }
            guard !hasDrawn else { throw UnifiedCalibrationError.alreadyDrawn }
            guard brushWidth.isFinite, brushWidth > 0,
                  knownMovement.isFinite, knownMovement >= 0, releaseDelay.isFinite, releaseDelay >= 0 else { throw UnifiedCalibrationError.invalidParameters }
            if let previous = testedBrushWidth, previous != brushWidth || testedMovement != knownMovement
                || (testedReleaseDelay != nil && testedReleaseDelay != releaseDelay) {
                retest()
            }
            baseReleaseDelay = releaseDelay
            let plan = try layout(area: area, brushWidth: brushWidth, knownMovement: knownMovement)
            testedBrushWidth = brushWidth
            testedMovement = knownMovement
            testedReleaseDelay = releaseDelay
            pathsPrepared = true
            message = "正在准备上排 M/#、下排 V/E；每格从上到下三组，不绘制序号。等待全部画完后同时反馈。"
            return plan
        } catch { message = error.localizedDescription; throw error }
    }

    @discardableResult
    func markDrawn() -> Bool {
        guard area != nil, pathsPrepared, !hasDrawn else {
            message = "本轮尚未完整准备或已经确认画完；中断的笔画不能提交反馈。"
            return false
        }
        pathsPrepared = false
        hasDrawn = true
        message = "M 看短线，# 的竖线判断 X、横线判断 Y；V 只判断线身连续，E 单独判断右端缺口及是否过线。"
        return true
    }

    private func invalidateDrawing() {
        pathsPrepared = false
        hasDrawn = false
        feedbackSubmitted = false
        selections = [:]
    }

    private static func initialSearches() -> [CalibrationMetric: Search] {
        var result: [CalibrationMetric: Search] = [:]
        for metric in CalibrationMetric.allCases {
            if metric == .ending { result[metric] = initialEndingSearch(.hold) }
            else {
                result[metric] = metric == .speed
                    ? Search(lower: 0, upper: 1350, values: [150, 450, 1350], confirmed: nil)
                    : Search(lower: 0, upper: 8, values: [0.5, 2, 8], confirmed: nil)
            }
        }
        return result
    }

    private static func initialEndingSearch(_ mode: CalibrationEndingMode) -> Search {
        mode == .hold ? Search(lower: 0, upper: 0.8, values: [0.12, 0.35, 0.8], confirmed: nil)
            : Search(lower: 0, upper: 8, values: [0.5, 2, 8], confirmed: nil)
    }

    private static func thirds(lower: Double, upper: Double) throws -> [Double] {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper > lower else { throw UnifiedCalibrationError.unrepresentableRange }
        let span = upper - lower
        let values = [lower + span / 3, lower + span * (2 / 3), upper]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }), values[0] > lower,
              values[1] > values[0], values[2] > values[1] else { throw UnifiedCalibrationError.unrepresentableRange }
        return values
    }

    private static func margin(_ value: Double) -> Double { value + max(0.25, value * 0.1) }

    nonisolated static func format(_ value: Double) -> String {
        if value != 0 && abs(value) < 0.001 { return String(format: "%.3g", value) }
        return String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private func layout(area: CGRect, brushWidth: Double, knownMovement: Double) throws -> UnifiedCalibrationRound {
        let effectiveMovement = max(knownMovement, searches[.movement]?.confirmed.map(Self.margin) ?? 0)
        let safeMovement = effectiveMovement + max(0.25, effectiveMovement * 0.1)
        let scale = fixedAnnotationScale
            ?? max(1, (knownMovement + max(0.25, knownMovement * 0.1)) / hypot(6.0, 5.0))
        let glyphWidth = 14 * scale, glyphHeight = 28 * scale
        let repeatGap = max(12, brushWidth + 6)
        // 标题与样本之间保留固定留白；目标画板自行决定橡皮宽度。
        let annotationClearance = 21 + brushWidth / 2
        let margin = max(18, brushWidth / 2 + 3)
        let sampleLength = max(36, safeMovement)
        let endingLength = max(96, safeMovement * 2)
        let movement = candidates(for: .movement), xValues = candidates(for: .spacingX)
        let yValues = candidates(for: .spacingY), speedValues = candidates(for: .speed)
        let endingValues = candidates(for: .ending)
        let policy = endingPolicy
        let availableColumn = (area.width - margin * 2 - annotationClearance) / 2
        let speedLength = max(96, min(120, availableColumn - policy.endExtension * 2), safeMovement * 3)
        let endingReserve = endingMode == .extension ? endingValues.max()! : 0
        let leftMinimum = max(movement.max()! * 3 + repeatGap * 2,
                              speedLength + policy.endExtension * 2, glyphWidth)
        let rightMinimum = max(xValues.max()!, sampleLength + policy.endExtension * 2,
                               endingLength + endingReserve * 2, glyphWidth)
        let minimumSampleHeight = max(sampleLength + policy.endExtension * 2,
                                      yValues.max()! + policy.endExtension * 2, glyphHeight) + max(6, brushWidth + 3)
        let minimumBandHeight = glyphHeight + annotationClearance + minimumSampleHeight * 3
        let required = CGSize(width: margin * 2 + annotationClearance + max(leftMinimum, rightMinimum) * 2,
                              height: margin * 2 + minimumBandHeight * 2 + annotationClearance)
        guard required.width.isFinite, required.height.isFinite else { throw UnifiedCalibrationError.unrepresentableRange }
        guard area.width + 0.000_001 >= required.width, area.height + 0.000_001 >= required.height else {
            throw UnifiedCalibrationError.areaTooSmall(required)
        }
        fixedAnnotationScale = scale
        let columnWidth = (area.width - margin * 2 - annotationClearance) / 2
        let columnOrigins = [margin, margin + columnWidth + annotationClearance]
        let bandHeight = (area.height - margin * 2 - annotationClearance) / 2
        let rowSlotHeight = (bandHeight - glyphHeight - annotationClearance) / 3
        let referenceSpeed = min(100, (searches[.speed]?.confirmed ?? (100 / 0.7)) * 0.7)
        let endingReferenceSpeed = endingTestSpeed
        var annotations: [[CGPoint]] = []
        var guides: [[CGPoint]] = []
        var groups: [CalibrationMetric: [[[CGPoint]]]] = [:]
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / area.width, y: y / area.height) }
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [CGPoint] {
            [point(x1, y1), point(x2, y2)]
        }
        // 画布只有四个固定标题；# 同时容纳独立的 X、Y 测试，完全不画数字。
        let panels: [CalibrationMetric] = [.movement, .spacingX, .speed, .ending]
        for (position, metric) in panels.enumerated() {
            let band = position / 2, column = position % 2
            let sampleX = columnOrigins[column]
            let bandY = margin + Double(band) * (bandHeight + annotationClearance)
            let headerX = sampleX + (columnWidth - glyphWidth) / 2
            for glyph in Self.letters[metric]! {
                annotations.append(glyph.map { point(headerX + $0.x * scale, bandY + $0.y * scale) })
            }
            var rows: [[[CGPoint]]] = []
            var yRows: [[[CGPoint]]] = []
            for index in 0..<3 {
                let centerY = bandY + glyphHeight + annotationClearance + rowSlotHeight * (Double(index) + 0.5)
                var row: [[CGPoint]] = []
                switch metric {
                case .movement:
                    let length = movement[index], slotWidth = (columnWidth - repeatGap * 2) / 3
                    for repeatIndex in 0..<3 {
                        let centerX = sampleX + slotWidth * (Double(repeatIndex) + 0.5) + repeatGap * Double(repeatIndex)
                        row.append(line(centerX - length / 2, centerY, centerX + length / 2, centerY))
                    }
                case .spacingX:
                    let centerX = sampleX + columnWidth / 2
                    for side in [-1.0, 1.0] {
                        let x = centerX + side * xValues[index] / 2
                        row.append(line(x, centerY - sampleLength / 2, x, centerY + sampleLength / 2))
                    }
                    let x = sampleX + (columnWidth - sampleLength) / 2
                    yRows.append([-1.0, 1.0].map { side in
                        let y = centerY + side * yValues[index] / 2
                        return line(x, y, x + sampleLength, y)
                    })
                case .speed, .ending:
                    let length = metric == .speed ? speedLength : endingLength
                    let x = sampleX + (columnWidth - length) / 2
                    guides.append(line(x, centerY - sampleLength / 2, x, centerY + sampleLength / 2))
                    guides.append(line(x + length, centerY - sampleLength / 2, x + length, centerY + sampleLength / 2))
                    row.append(line(x, centerY, x + length, centerY))
                case .spacingY: break
                }
                rows.append(row)
            }
            groups[metric] = rows
            if metric == .spacingX { groups[.spacingY] = yRows }
        }
        let annotationMovement = annotations.reduce(0.0) { longest, path in
            zip(path, path.dropFirst()).reduce(longest) { value, pair in
                max(value, hypot((pair.1.x - pair.0.x) * area.width, (pair.1.y - pair.0.y) * area.height))
            }
        }
        var batches = [UnifiedCalibrationBatch(metric: nil, paths: annotations, speed: referenceSpeed,
                                                minimumMovement: annotationMovement, isAnnotation: true,
                                                releaseDelay: policy.releaseDelay),
                       UnifiedCalibrationBatch(metric: nil, paths: guides, speed: min(60, referenceSpeed),
                                                minimumMovement: sampleLength, releaseDelay: policy.releaseDelay)]
        for metric in CalibrationMetric.allCases {
            for index in 0..<3 {
                var release = policy.releaseDelay
                var extensionDistance = metric == .movement ? 0 : policy.endExtension
                if metric == .ending {
                    release = endingMode == .hold ? endingValues[index] : baseReleaseDelay
                    extensionDistance = endingMode == .extension ? endingValues[index] : 0
                }
                batches.append(UnifiedCalibrationBatch(metric: metric, paths: groups[metric]![index],
                                                        speed: metric == .speed ? speedValues[index]
                                                            : metric == .ending ? endingReferenceSpeed : referenceSpeed,
                                                        minimumMovement: metric == .movement ? movement[index]
                                                            : (metric == .speed || metric == .ending) ? effectiveMovement : sampleLength,
                                                        releaseDelay: release, endExtension: extensionDistance))
            }
        }
        let testPaths = batches.filter { !$0.isAnnotation }.flatMap { $0.paths }
        let actualTestPaths = batches.filter { !$0.isAnnotation }.flatMap { $0.compensatedPaths(in: area) }
        return UnifiedCalibrationRound(area: area, paths: annotations + testPaths, annotationPaths: annotations,
                                       testPaths: testPaths, actualTestPaths: actualTestPaths,
                                       annotationSignature: UnifiedCalibrationAnnotationSignature(area: area,
                                                                                                  brushWidth: brushWidth,
                                                                                                  paths: annotations),
                                       batches: batches, requiredSize: required)
    }

    private static let letters: [CalibrationMetric: [[CGPoint]]] = [
        .movement: [[CGPoint(x: 0, y: 28), CGPoint(x: 0, y: 0), CGPoint(x: 7, y: 14), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 28)]],
        .spacingX: [[CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 28)],
                    [CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 28)],
                    [CGPoint(x: 0, y: 9), CGPoint(x: 14, y: 9)],
                    [CGPoint(x: 0, y: 19), CGPoint(x: 14, y: 19)]],
        .speed: [[CGPoint(x: 0, y: 0), CGPoint(x: 7, y: 28), CGPoint(x: 14, y: 0)]],
        .ending: [[CGPoint(x: 14, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28)],
                  [CGPoint(x: 0, y: 14), CGPoint(x: 14, y: 14)]]
    ]

}

struct UnifiedCalibrationView: View {
    @ObservedObject var calibration: UnifiedCalibration
    let onSelectArea: () -> Void
    let onDraw: () -> Void
    let onConfirm: () -> Void
    let onClose: () -> Void
    let isRunning: Bool
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("画笔联合校准").font(.system(size: 23, weight: .semibold))
                    Text("主画布四个格，同时测位移、双向间距、线身速度与收笔。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose).disabled(isRunning)
            }
            HStack {
                Button(calibration.area == nil ? "去主界面设置画布" : "主画布已设置", action: onSelectArea)
                    .disabled(isRunning)
                if let area = calibration.area {
                    Text("\(Int(area.width)) × \(Int(area.height)) 屏幕点").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("第 \(calibration.round) 轮 · 每项 3 组").font(.system(size: 13, weight: .medium))
            }
            Text("画布上排 M/#、下排 V/E，不画序号，每格从上到下三组。# 每组两竖两横：分别判断竖线 X 与横线 Y 是否分开。V 只看线身连续，不因右端缺口否定速度；E 单独看末端是否到线、是否过线。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("E 收笔方式", selection: Binding(get: { calibration.endingMode }, set: { calibration.setEndingMode($0) })) {
                    ForEach(CalibrationEndingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 300).disabled(isRunning)
                Text(calibration.endingMode == .hold ? "等待无效时下一轮自动测试延伸。" : "只选完整且不过线的一组；也可选择零补偿。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("E 当前 \(UnifiedCalibration.format(calibration.endingTestSpeed)) 点/秒。已确认的结果可以直接应用；也可按 V 的采用速度单独复测收笔。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("复测收笔") {
                    if let result = calibration.resultForApplication(), calibration.setEndingTestSpeed(result.speed) { onDraw() }
                }.controlSize(.small)
                    .disabled(isRunning || calibration.endingMatchesAdoptedSpeed || (!calibration.canSubmitFeedback && calibration.results == nil))
            }
            selectionTable
            HStack {
                Spacer()
                Button(calibration.selections[.ending] == .noCompensation ? "✓ E 不需要补偿" : "E 不需要补偿") {
                    calibration.selectNoEndingCompensation()
                }.disabled(isRunning || !calibration.hasDrawn || calibration.feedbackSubmitted)
                Button(calibration.selections[.ending] == .overrun ? "✓ E 全部过线" : "E 全部过线") {
                    calibration.selectEndingAllOverrun()
                }.disabled(isRunning || !calibration.hasDrawn || calibration.feedbackSubmitted || calibration.endingMode != .extension)
            }.controlSize(.small)
            Text("按下后停留，再拖动；到达终点后停留，再松开。距离测试和端点参照线使用较慢的稳定速度。" + calibration.cleanupInstruction)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let result = calibration.results {
                Text("已确认结果：位移 \(UnifiedCalibration.format(result.movement)) · X \(UnifiedCalibration.format(result.spacingX)) · Y \(UnifiedCalibration.format(result.spacingY)) 点；速度 \(UnifiedCalibration.format(result.speed)) 点/秒；收笔 \(UnifiedCalibration.format(result.releaseDelay)) 秒 / 延伸 \(UnifiedCalibration.format(result.endExtension)) 点")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            Text(calibration.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            Spacer(minLength: 0)
            controls
        }
        .padding(24)
        .frame(minWidth: 940, idealWidth: 1000, minHeight: 640)
    }

    private var selectionTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("组号").frame(width: 35)
                ForEach(CalibrationMetric.allCases) { metric in
                    Text(metric.title).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
            }.font(.system(size: 12)).padding(12)
            Divider()
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index + 1)").fontWeight(.semibold).frame(width: 35)
                    ForEach(CalibrationMetric.allCases) { metric in
                        Button {
                            calibration.select(metric: metric, index: index)
                        } label: {
                            let selected = calibration.selections[metric] == .row(index)
                            Text("\(selected ? "✓ " : "")\(UnifiedCalibration.format(calibration.candidates(for: metric)[index])) \(calibration.unit(for: metric))")
                                .frame(maxWidth: .infinity).monospacedDigit()
                        }
                        .disabled(isRunning || !calibration.hasDrawn || calibration.feedbackSubmitted)
                    }
                }.font(.system(size: 12)).padding(12)
                Divider()
            }
            HStack(spacing: 8) {
                Text("无").frame(width: 35)
                ForEach(CalibrationMetric.allCases) { metric in
                    Button {
                        calibration.select(metric: metric, index: nil)
                    } label: {
                        let selected = calibration.selections[metric] == CalibrationSelection.none
                        Text("\(selected ? "✓ " : "")\((metric == .speed || metric == .ending) ? "全部不完整" : "全部不清晰")")
                            .frame(maxWidth: .infinity)
                    }.disabled(isRunning || !calibration.hasDrawn || calibration.feedbackSubmitted)
                }
            }.font(.system(size: 12)).padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if isRunning {
                Button(isPaused ? "继续" : "暂停", action: onPauseResume)
                Button("停止", action: onStop).tint(.red)
                Spacer()
            } else {
                Button("重新测量") { calibration.retest() }
                Button("重画本轮") {
                    if calibration.repeatRound() { onDraw() }
                }.disabled(calibration.area == nil)
                Button("扩大区间") {
                    if calibration.expandRanges() { onDraw() }
                }.disabled(calibration.area == nil)
                Spacer(minLength: 8)
                Button("确认并应用", action: onConfirm).buttonStyle(.borderedProminent)
                    .disabled(!calibration.canSubmitFeedback && calibration.results == nil)
                if calibration.hasDrawn {
                    Button("同时进入下一轮") {
                        if calibration.refine() { onDraw() }
                    }.buttonStyle(.bordered)
                        .disabled(!calibration.canSubmitFeedback && !calibration.feedbackSubmitted)
                } else {
                    Button("绘制本轮", action: onDraw).buttonStyle(.borderedProminent)
                        .disabled(calibration.area == nil)
                }
            }
        }.controlSize(.small)
    }
}
