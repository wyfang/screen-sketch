import AppKit
import SwiftUI

enum SpacingAxis: String, CaseIterable, Identifiable {
    case x, y

    var id: String { rawValue }
    var title: String { self == .x ? "横向 X" : "纵向 Y" }
    var explanation: String {
        self == .x
            ? "比较两条竖线：测量横向能清楚分开的最小中心距离。"
            : "比较两条横线：测量纵向能清楚分开的最小中心距离。"
    }
}

/// 测试中心距，不把目标画板上的笔宽或 Retina 像素当作鼠标坐标。
/// 路径使用真实 Quartz 屏幕点；仅生成路径，绝不读取或清空画板、投递输入。
@MainActor
final class SpacingCalibration: ObservableObject {
    @Published var axis: SpacingAxis = .x {
        didSet {
            if axis != oldValue {
                retest()
                message = "已切换到\(axis.title)，另一方向的校准结果需要单独采用。" + cleanupInstruction
            }
        }
    }
    @Published private(set) var area: CGRect?
    @Published private(set) var candidates: [Double] = [0.5, 1, 2, 4, 8, 16]
    @Published private(set) var round = 1
    @Published private(set) var hasDrawn = false
    @Published private(set) var finished = false
    @Published private(set) var measuredMinimum: Double?
    @Published private(set) var suggestedMinimum: Double?
    @Published var selectedRow: Int?
    @Published var automaticCleanup = false {
        didSet {
            guard automaticCleanup != oldValue else { return }
            message = message.replacingOccurrences(of: Self.cleanupText(automatic: oldValue),
                                                   with: cleanupInstruction)
        }
    }
    @Published private(set) var message = "先框选一块空白测试区，保持目标画板的黑笔、笔宽和绘制速度不变。"
    @Published private(set) var lowerBound = 0.0
    @Published private(set) var upperBound = 16.0

    var cleanupInstruction: String { Self.cleanupText(automatic: automaticCleanup) }

    private static func cleanupText(automatic: Bool) -> String {
        automatic
            ? "点击“绘制本轮”时会先自动擦除已记录的测试笔画，再绘制本轮。"
            : "下一轮绘制前，请手动清除旧测试线，或重新框选空白测试区。"
    }

    let tolerance = 0.25
    private var pathsPrepared = false
    private var maximumTestSpacing = 0.0
    private var testedBrushWidth: Double?
    private var testedMovement: Double?

    @discardableResult
    func setArea(_ rect: CGRect?) -> Bool {
        pathsPrepared = false
        hasDrawn = false
        selectedRow = nil
        maximumTestSpacing = 0
        guard let rect, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            area = nil
            message = "未选定有效测试区，请在同一显示器框选一块空白矩形。"
            return false
        }
        area = rect
        if finished {
            message = "空白区已更新。已确认的\(axis.title)结果仍可采用；改变笔宽、画板或速度后请重新测量。"
        } else {
            message = "空白区已选定，测试区间保持不变。请确认新选区域原本为空白。" + cleanupInstruction + previousResultText
        }
        return true
    }

    /// 每行画一个真实序号和三对平行线；序号、笔画均不缩短到启动阈值以下。
    /// 所有候选距离严格保持原值；放不下时要求更大的空白区，而非缩放测试。
    func numberedPaths(brushWidth: Double, minimumMovement: Double) -> [[CGPoint]] {
        pathsPrepared = false
        guard !finished else {
            message = "本方向校准已完成；改变笔宽或画板后请点击“重新测量”。"
            return []
        }
        guard !hasDrawn else {
            message = "本轮已画完，请提交反馈；需要重画时先点击“重画本轮”。"
            return []
        }
        guard let area else {
            message = "请先框选空白测试区。"
            return []
        }
        guard brushWidth.isFinite, brushWidth > 0, minimumMovement.isFinite, minimumMovement >= 0,
              !candidates.isEmpty, candidates.count <= Self.glyphs.count,
              candidates.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            message = "笔宽或最小位移无效，请先确认目标画板的实际笔宽和最小位移。"
            return []
        }

        // 更改画笔/位移后旧的可见性反馈不能继续夹逼或应用。
        if let previousBrush = testedBrushWidth, let previousMovement = testedMovement,
           previousBrush != brushWidth || previousMovement != minimumMovement {
            retest()
            message = "笔宽或最小位移已改变，已重新开始本方向校准。" + cleanupInstruction
            return []
        }

        let movementMargin = max(0.25, minimumMovement * 0.1)
        let lineLength = max(28, minimumMovement + movementMargin)
        let shortestGlyphSegment = hypot(6.0, 5.0)
        let glyphScale = max(1, (minimumMovement + movementMargin) / shortestGlyphSegment)
        let labelHeight = 28 * glyphScale
        let labelSlot = 14 * glyphScale + max(18, brushWidth + 12)
        let margin = brushWidth / 2 + 8
        let columnGap = max(14, brushWidth + 10)
        let rowGap = max(14, brushWidth + 10)
        let longest = candidates.max() ?? 0
        let pairWidth = axis == .x ? longest : lineLength
        let rowHeight = max(labelHeight, axis == .x ? lineLength : longest)
        let requiredWidth = margin * 2 + labelSlot + columnGap * 2 + pairWidth * 3
        let requiredHeight = margin * 2 + rowHeight * Double(candidates.count) + rowGap * Double(candidates.count - 1)
        guard requiredWidth.isFinite, requiredHeight.isFinite,
              area.width + 0.000_001 >= requiredWidth,
              area.height + 0.000_001 >= requiredHeight else {
            let dimensions = requiredWidth.isFinite && requiredHeight.isFinite
                ? "至少 \(Self.format(ceil(requiredWidth))) × \(Self.format(ceil(requiredHeight))) 点"
                : "更大的空白区，或有效的笔宽与最小位移"
            message = "测试区太小，本轮需要\(dimensions)。请重新框选；测试距离不会随区域缩放。"
            return []
        }

        let columnWidth = (area.width - margin * 2 - labelSlot - columnGap * 2) / 3
        let rowSpacing = candidates.count > 1
            ? (area.height - margin * 2 - rowHeight) / Double(candidates.count - 1) : 0
        var result: [[CGPoint]] = []
        result.reserveCapacity(candidates.count * 7)
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / area.width, y: point.y / area.height)
        }
        for (row, spacing) in candidates.enumerated() {
            let centerY = margin + rowHeight / 2 + Double(row) * rowSpacing
            let label = Self.glyphs[row].map {
                normalized(CGPoint(x: margin + $0.x * glyphScale, y: centerY - labelHeight / 2 + $0.y * glyphScale))
            }
            result.append(label)
            for column in 0..<3 {
                let centerX = margin + labelSlot + (Double(column) + 0.5) * columnWidth + Double(column) * columnGap
                for side in [-1.0, 1.0] {
                    if axis == .x {
                        let x = centerX + side * spacing / 2
                        result.append([
                            normalized(CGPoint(x: x, y: centerY - lineLength / 2)),
                            normalized(CGPoint(x: x, y: centerY + lineLength / 2))
                        ])
                    } else {
                        let y = centerY + side * spacing / 2
                        result.append([
                            normalized(CGPoint(x: centerX - lineLength / 2, y: y)),
                            normalized(CGPoint(x: centerX + lineLength / 2, y: y))
                        ])
                    }
                }
            }
        }
        // 下一轮只有四组，因此纵向扩大范围可利用四组布局能容纳的空间。
        maximumTestSpacing = axis == .x ? columnWidth : (area.height - margin * 2 - rowGap * 3) / 4
        testedBrushWidth = brushWidth
        testedMovement = minimumMovement
        pathsPrepared = true
        message = "本轮从上到下绘制 \(candidates.count) 组，每组三对\(axis == .x ? "竖线" : "横线")。等待全部画完后，选择三对都能清楚分开的最小一组。"
        return result
    }

    /// 仅在引擎完整画完当前计划后调用；中断或只生成路径不算完成。
    @discardableResult
    func markDrawn() -> Bool {
        guard !finished, pathsPrepared, area != nil, !hasDrawn else {
            message = finished ? "本方向校准已完成。" : "请先完整绘制本轮；未完成的笔画不能提交反馈。"
            return false
        }
        pathsPrepared = false
        hasDrawn = true
        message = "请选择最小且三对都能清楚分开的组号。两条粘在一起算不清晰；若所有组都粘连或缺线，选择“全部不清晰”。"
        return true
    }

    @discardableResult
    func selectShortestVisible(index: Int) -> Bool {
        guard feedbackIsAllowed() else { return false }
        guard candidates.indices.contains(index) else {
            message = "组号无效，请选择本轮表格中的组号。"
            return false
        }
        let nextUpper = candidates[index]
        let nextLower = index == 0 ? lowerBound : candidates[index - 1]
        lowerBound = nextLower
        upperBound = nextUpper
        measuredMinimum = nextUpper
        selectedRow = nil
        if nextUpper - nextLower <= tolerance + 0.000_001 {
            finished = true
            suggestedMinimum = Self.withMargin(nextUpper)
            pathsPrepared = false
            message = "\(axis.title)校准完成：最小清晰中心距位于 \(Self.format(nextLower))～\(Self.format(nextUpper)) 点。推荐 \(Self.format(suggestedMinimum!)) 点，已留稳定间距余量。"
        } else {
            advanceRound(lower: nextLower, upper: nextUpper)
        }
        return true
    }

    @discardableResult
    func noneVisible() -> Bool {
        guard feedbackIsAllowed(), let last = candidates.last else { return false }
        measuredMinimum = nil
        suggestedMinimum = nil
        selectedRow = nil
        let nextUpper = min(last * 2, maximumTestSpacing)
        guard nextUpper > last + 0.000_001 else {
            message = "测到 \(Self.format(last)) 点仍分不开，当前区域无法容纳更大的中心距。请另选\(axis == .x ? "更宽" : "更高")的空白区；若笔画缺失，请先确认最小位移校准。"
            return false
        }
        advanceRound(lower: last, upper: nextUpper)
        message = "本轮全部不清晰，下一轮扩大中心距。" + cleanupInstruction + "笔宽、绘制速度保持不变。"
        return true
    }

    @discardableResult
    func repeatRound() -> Bool {
        guard !finished else {
            message = "本方向校准已完成，需要新的结果时请点击“重新测量”。"
            return false
        }
        hasDrawn = false
        pathsPrepared = false
        selectedRow = nil
        message = "当前区间保持不变，可以重画本轮。" + cleanupInstruction + previousResultText
        return true
    }

    func retest() {
        candidates = [0.5, 1, 2, 4, 8, 16]
        round = 1
        lowerBound = 0
        upperBound = 16
        measuredMinimum = nil
        suggestedMinimum = nil
        hasDrawn = false
        finished = false
        pathsPrepared = false
        maximumTestSpacing = 0
        selectedRow = nil
        testedBrushWidth = nil
        testedMovement = nil
        message = area == nil
            ? "先框选一块空白测试区。"
            : "已重新开始\(axis.title)校准，可以绘制第一轮。" + cleanupInstruction
    }

    /// 可使用已完成轮的确认上界提前结束；不把尚未画完的新轮当作已确认。
    @discardableResult
    func finishWithCurrentResult() -> Bool {
        guard let confirmed = measuredMinimum else {
            message = "请先完整画完一轮并确认最小清晰组，才能结束并选用。"
            return false
        }
        finished = true
        pathsPrepared = false
        selectedRow = nil
        suggestedMinimum = Self.withMargin(confirmed)
        message = "已结束\(axis.title)校准：已确认清晰中心距 \(Self.format(confirmed)) 点，推荐 \(Self.format(suggestedMinimum!)) 点。区间尚有 \(Self.format(upperBound - lowerBound)) 点，后续可重新测量。"
        return true
    }

    private var previousResultText: String {
        measuredMinimum.map { "此前完整轮已确认 \(Self.format($0)) 点清晰；可直接采用该结果，也可继续细化。" } ?? ""
    }

    private func feedbackIsAllowed() -> Bool {
        guard !finished, hasDrawn else {
            message = finished ? "本方向校准已完成，请采用结果或重新测量。" : "请先完整绘制本轮，再提交一次可见性反馈。"
            return false
        }
        return true
    }

    private func advanceRound(lower: Double, upper: Double) {
        lowerBound = lower
        upperBound = upper
        candidates = (1...4).map { lower + (upper - lower) * Double($0) / 4 }
        round += 1
        hasDrawn = false
        pathsPrepared = false
        selectedRow = nil
        message = "下一轮缩小到 \(Self.format(lower))～\(Self.format(upper)) 点。" + cleanupInstruction + previousResultText
    }

    private static func withMargin(_ value: Double) -> Double {
        ceil((value + max(0.25, value * 0.1) - 0.000_000_001) * 20) / 20
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static let glyphs: [[CGPoint]] = [
        [CGPoint(x: 3, y: 5), CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 28)],
        [CGPoint(x: 0, y: 0), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 12), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28)],
        [CGPoint(x: 0, y: 0), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 28), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28), CGPoint(x: 14, y: 14), CGPoint(x: 0, y: 14)],
        [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 14), CGPoint(x: 14, y: 14), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 28)],
        [CGPoint(x: 14, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 14), CGPoint(x: 14, y: 14), CGPoint(x: 14, y: 28), CGPoint(x: 0, y: 28)],
        [CGPoint(x: 14, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28), CGPoint(x: 14, y: 14), CGPoint(x: 0, y: 14)]
    ]
}

struct SpacingCalibrationView: View {
    @ObservedObject var calibration: SpacingCalibration
    let onSelectArea: () -> Void
    let onDraw: () -> Void
    let onApply: (SpacingAxis, Double) -> Void
    let onClose: () -> Void
    let isRunning: Bool
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("校准最小笔画间距").font(.system(size: 23, weight: .semibold))
                    Text("找出两条笔画仍能清楚分开的最小中心距离。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose).disabled(isRunning)
            }
            Picker("测量方向", selection: $calibration.axis) {
                ForEach(SpacingAxis.allCases) { axis in Text(axis.title).tag(axis) }
            }.pickerStyle(.segmented).disabled(isRunning)
            Text(calibration.axis.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button(calibration.area == nil ? "框选空白测试区" : "重新框选空白区", action: onSelectArea)
                    .disabled(isRunning)
                if let area = calibration.area {
                    Text("\(Int(area.width)) × \(Int(area.height)) 点").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("第 \(calibration.round) 轮").font(.system(size: 13, weight: .medium))
            }
            Text("画布左侧会写组号，每组画三对线。选择三对均有两条完整线、且能清楚分开的最小组；保持黑笔、笔宽和速度不变。" + calibration.cleanupInstruction)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(calibration.candidates.enumerated()), id: \.offset) { index, distance in
                    HStack(spacing: 14) {
                        Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).frame(width: 20)
                        Text("\(SpacingCalibration.format(distance)) 点").font(.system(size: 13)).monospacedDigit()
                            .frame(width: 86, alignment: .leading)
                        Text(calibration.axis == .x ? "│ │    │ │    │ │" : "═    ═    ═")
                            .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 155)
                        Spacer(minLength: 0)
                        Button(calibration.selectedRow == index ? "✓ 已选这组" : "选择这组") { calibration.selectedRow = index }
                            .disabled(isRunning || !calibration.hasDrawn || calibration.finished)
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                    if index < calibration.candidates.count - 1 { Divider() }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Text("上表线对仅为示意；画布中的间距使用真实屏幕点。X、Y 两个方向分别测量并采用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("测试区间：\(SpacingCalibration.format(calibration.lowerBound))～\(SpacingCalibration.format(calibration.upperBound)) 点")
                    .font(.system(size: 13)).monospacedDigit()
                Spacer()
                if let suggested = calibration.suggestedMinimum {
                    Text("推荐 \(SpacingCalibration.format(suggested)) 点").font(.system(size: 13, weight: .semibold))
                }
            }
            Text(calibration.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            Spacer(minLength: 0)
            HStack {
                if isRunning {
                    Button(isPaused ? "继续" : "暂停", action: onPauseResume)
                    Button("停止", action: onStop).tint(.red)
                } else if calibration.finished {
                    Button("重新测量") { calibration.retest() }
                    Spacer()
                    Button("采用\(calibration.axis.title)结果") {
                        if let minimum = calibration.suggestedMinimum { onApply(calibration.axis, minimum) }
                    }.buttonStyle(.borderedProminent).disabled(calibration.suggestedMinimum == nil)
                } else {
                    Button("重画本轮") { calibration.repeatRound() }.disabled(!calibration.hasDrawn)
                    Button("全部不清晰") { calibration.noneVisible() }.disabled(!calibration.hasDrawn)
                    Button("继续缩小区间") {
                        if let selected = calibration.selectedRow { calibration.selectShortestVisible(index: selected) }
                    }.disabled(calibration.selectedRow == nil || !calibration.hasDrawn)
                    Button("结束并选用") {
                        if let selected = calibration.selectedRow, calibration.hasDrawn {
                            guard calibration.selectShortestVisible(index: selected) else { return }
                        }
                        if calibration.finishWithCurrentResult(), let minimum = calibration.suggestedMinimum {
                            onApply(calibration.axis, minimum)
                        }
                    }.disabled(calibration.measuredMinimum == nil && (calibration.selectedRow == nil || !calibration.hasDrawn))
                    Spacer()
                    Button("绘制本轮", action: onDraw).buttonStyle(.borderedProminent)
                        .disabled(calibration.area == nil || calibration.hasDrawn)
                }
            }.controlSize(.small)
        }.padding(24).frame(minWidth: 680, idealWidth: 720, minHeight: 660)
    }
}
