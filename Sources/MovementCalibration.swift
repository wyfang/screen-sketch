import AppKit
import SwiftUI

/// 只管理人工可见性反馈与测试路径；不读取屏幕、不清除目标画板、不发送任何输入。
/// area 与候选长度均以 Quartz 屏幕点计量，路径归一化后供现有 DrawingEngine 使用。
@MainActor
final class MovementCalibration: ObservableObject {
    @Published private(set) var area: CGRect?
    @Published private(set) var candidates: [Double] = [0.5, 1, 2, 4, 8, 16]
    @Published private(set) var round = 1
    @Published private(set) var lowerBound = 0.0
    @Published private(set) var upperBound = 16.0
    @Published private(set) var measuredMinimum: Double?
    @Published private(set) var suggestedMinimum: Double?
    @Published private(set) var hasDrawn = false
    @Published private(set) var finished = false
    @Published var selectedRow: Int?
    @Published var automaticCleanup = false {
        didSet {
            guard automaticCleanup != oldValue else { return }
            message = message.replacingOccurrences(of: Self.cleanupText(automatic: oldValue),
                                                   with: cleanupInstruction)
        }
    }
    @Published private(set) var message = "先框选一块空白测试区，选好目标画板的黑色铅笔。"

    var cleanupInstruction: String { Self.cleanupText(automatic: automaticCleanup) }

    private static func cleanupText(automatic: Bool) -> String {
        automatic
            ? "点击“绘制本轮”时会先自动擦除已记录的测试笔画，再绘制本轮。"
            : "下一轮绘制前，请手动清除旧测试线，或重新框选空白测试区。"
    }

    let tolerance = 0.25
    private var pathsPrepared = false
    private var maximumTestLength = 0.0

    /// 每轮可以重新框选空白区；更换区域保留正在夹逼的长度，不擅自清除前一轮。
    @discardableResult
    func setArea(_ rect: CGRect?) -> Bool {
        pathsPrepared = false
        hasDrawn = false
        guard let rect, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            area = nil
            message = "未选定有效测试区，请在同一显示器框选一块空白矩形。"
            return false
        }
        area = rect
        message = finished
            ? "测试区已更新；本次校准已完成。改变笔宽或画板后请重新测量。"
            : "测试区已选定，请确认新选区域原本为空白。" + cleanupInstruction
        return true
    }

    /// 每个候选对应一行，三条水平线的中心分布在三列。短线长度不被放大或缩短。
    /// 若无法以真实长度与笔宽完整容纳当前轮，返回空数组并说明所需尺寸。
    func normalizedPaths(brushWidth: Double) -> [[CGPoint]] {
        pathsPrepared = false
        guard !finished else {
            message = "本次校准已完成；要测试新的笔宽或画板，请点击“重新测量”。"
            return []
        }
        guard let area else {
            message = "请先框选空白测试区。"
            return []
        }
        guard brushWidth.isFinite, brushWidth > 0,
              !candidates.isEmpty, candidates.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            message = "笔宽或测试长度无效，请填写目标画板实际黑笔宽度。"
            return []
        }
        let margin = brushWidth / 2 + 8
        let columnGap = max(12, brushWidth + 8)
        let rowGap = max(36, brushWidth + 28)
        let labelSlot = 32.0
        let labelHeight = 28.0
        let longest = candidates.max() ?? 0
        let requiredWidth = margin * 2 + labelSlot + columnGap * 2 + longest * 3
        let requiredHeight = margin * 2 + labelHeight + Double(max(0, candidates.count - 1)) * rowGap
        guard area.width + 0.000_001 >= requiredWidth,
              area.height + 0.000_001 >= requiredHeight else {
            message = "测试区太小，本轮需要至少 \(Self.format(ceil(requiredWidth))) × \(Self.format(ceil(requiredHeight))) 点。请重新框选更宽或更高的空白区。"
            return []
        }

        let columnWidth = (area.width - margin * 2 - labelSlot - columnGap * 2) / 3
        let rowSpacing = candidates.count > 1
            ? (area.height - margin * 2 - labelHeight) / Double(candidates.count - 1) : 0
        var paths: [[CGPoint]] = []
        paths.reserveCapacity(candidates.count * 3)
        for (row, length) in candidates.enumerated() {
            let y = candidates.count == 1 ? area.height / 2 : margin + labelHeight / 2 + Double(row) * rowSpacing
            for column in 0..<3 {
                let centerX = margin + labelSlot + (Double(column) + 0.5) * columnWidth + Double(column) * columnGap
                paths.append([
                    CGPoint(x: (centerX - length / 2) / area.width, y: y / area.height),
                    CGPoint(x: (centerX + length / 2) / area.width, y: y / area.height)
                ])
            }
        }
        maximumTestLength = columnWidth
        pathsPrepared = true
        message = "本轮从上到下绘制 \(candidates.count) 组，每组三条。观察三条都清晰的最短一组，再提交反馈。"
        return paths
    }

    /// 真正用目标铅笔写组号；标签与测试线分开，标签不会改变候选位移。
    func numberedPaths(brushWidth: Double) -> [[CGPoint]] {
        let lines = normalizedPaths(brushWidth: brushWidth)
        guard let area, !lines.isEmpty else { return [] }
        let glyphs: [[CGPoint]] = [
            [CGPoint(x: 3, y: 5), CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 28)],
            [CGPoint(x: 0, y: 0), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 12), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28)],
            [CGPoint(x: 0, y: 0), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 28), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28), CGPoint(x: 14, y: 14), CGPoint(x: 0, y: 14)],
            [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 14), CGPoint(x: 14, y: 14), CGPoint(x: 14, y: 0), CGPoint(x: 14, y: 28)],
            [CGPoint(x: 14, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 14), CGPoint(x: 14, y: 14), CGPoint(x: 14, y: 28), CGPoint(x: 0, y: 28)],
            [CGPoint(x: 14, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 28), CGPoint(x: 14, y: 28), CGPoint(x: 14, y: 14), CGPoint(x: 0, y: 14)]
        ]
        let margin = brushWidth / 2 + 8
        var result: [[CGPoint]] = []
        for row in candidates.indices {
            let centerY = lines[row * 3][0].y * area.height
            let label = glyphs[row].map { CGPoint(x: (margin + $0.x) / area.width, y: (centerY - 14 + $0.y) / area.height) }
            result.append(label)
            result += Array(lines[(row * 3)..<(row * 3 + 3)])
        }
        return result
    }

    /// 可以不继续细化，直接采用目前已经由用户确认可见的上界。
    @discardableResult
    func finishWithCurrentResult() -> Bool {
        guard let visible = measuredMinimum else {
            message = "请先完成一轮并选择最短清晰组，再结束并选用结果。"
            return false
        }
        finished = true
        let safe = visible + max(0.25, visible * 0.1)
        suggestedMinimum = ceil((safe - 0.000_000_001) * 20) / 20
        pathsPrepared = false
        message = "已结束：已确认可见上界 \(Self.format(visible)) 点，采用 \(Self.format(suggestedMinimum!)) 点。当前区间尚有 \(Self.format(upperBound - lowerBound)) 点，后续可以重新测量。"
        return true
    }

    /// 只应在绘制引擎完整完成本轮后调用，停止或未完成的笔画不能进入反馈阶段。
    @discardableResult
    func markDrawn() -> Bool {
        guard !finished, pathsPrepared, area != nil, !hasDrawn else {
            message = finished ? "本次校准已经完成。" : "本轮尚未准备好或已经确认画完，请完整绘制本轮后再反馈。"
            return false
        }
        hasDrawn = true
        message = "请选择最短且三条都清晰的一组；若所有组都没有墨迹，选择“全部不清晰”。"
        return true
    }

    /// index 是从零开始的行索引。用户确认该行及其后的较长线清晰，之前的短线不清晰。
    @discardableResult
    func selectShortestVisible(index: Int) -> Bool {
        guard feedbackIsAllowed() else { return false }
        guard candidates.indices.contains(index) else {
            message = "反馈的组号无效，请选择这一轮显示的组号。"
            return false
        }
        let nextUpper = candidates[index]
        let nextLower = index == 0 ? lowerBound : candidates[index - 1]
        lowerBound = nextLower
        upperBound = nextUpper
        measuredMinimum = nextUpper
        if nextUpper - nextLower <= tolerance + 0.000_001 {
            finished = true
            // 最短已知可见上界加一小段余量，避免恰好卡在目标画板的启动阈值上。
            let safe = nextUpper + max(0.25, nextUpper * 0.1)
            suggestedMinimum = ceil((safe - 0.000_000_001) * 20) / 20
            pathsPrepared = false
            message = "校准完成：最短可见长度位于 \(Self.format(nextLower))～\(Self.format(nextUpper)) 点。推荐 \(Self.format(suggestedMinimum!)) 点，已留稳定绘制余量。"
        } else {
            advanceRound(lower: nextLower, upper: nextUpper)
        }
        return true
    }

    /// 本轮全部不清晰时扩大范围；已用尽测试区宽度则停在当前轮，要求换更宽的空白区。
    @discardableResult
    func noneVisible() -> Bool {
        guard feedbackIsAllowed(), let last = candidates.last else { return false }
        let nextUpper = min(last * 2, maximumTestLength)
        guard nextUpper > last + 0.000_001 else {
            message = "已测试到 \(Self.format(last)) 点仍不清晰，当前区域无法容纳更长的三列短线。请重新框选更宽的空白区，并保持笔宽和绘制速度不变。"
            return false
        }
        measuredMinimum = nil
        suggestedMinimum = nil
        advanceRound(lower: last, upper: nextUpper)
        message = "本轮全部不清晰，下一轮改测更长线。" + cleanupInstruction + "笔宽和绘制速度保持不变。"
        return true
    }

    /// 只撤回本轮“已画完”状态，保留候选与上下界，方便清空后重画。
    @discardableResult
    func repeatRound() -> Bool {
        guard !finished else {
            message = "本次校准已完成；需要新的结果时请点击“重新测量”。"
            return false
        }
        hasDrawn = false
        pathsPrepared = false
        message = "当前测试区间保持不变，可以重画本轮。" + cleanupInstruction
        return true
    }

    /// 重置整个测量过程，保留用户框选区域，不更改任何目标画板内容。
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
        maximumTestLength = 0
        message = area == nil ? "先框选一块空白测试区。" : "已重置校准，可以绘制第一轮。" + cleanupInstruction
    }

    private func feedbackIsAllowed() -> Bool {
        guard !finished, hasDrawn else {
            message = finished ? "本次校准已经完成，请应用结果或重新测量。" : "请先完整绘制当前轮，再提交一次可见性反馈。"
            return false
        }
        return true
    }

    private func advanceRound(lower: Double, upper: Double) {
        lowerBound = lower
        upperBound = upper
        let span = upper - lower
        candidates = (1...4).map { lower + span * Double($0) / 4 }
        round += 1
        hasDrawn = false
        pathsPrepared = false
        message = "下一轮缩小到 \(Self.format(lower))～\(Self.format(upper)) 点。" + cleanupInstruction
    }

    static func format(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
        return text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

/// 可放进独立非模态窗口；所有绘图、窗口隐藏和阈值应用由 AppModel 回调负责。
struct MovementCalibrationView: View {
    @ObservedObject var calibration: MovementCalibration
    private var selectedRow: Int? {
        get { calibration.selectedRow }
        nonmutating set { calibration.selectedRow = newValue }
    }
    let onSelectArea: () -> Void
    let onDraw: () -> Void
    let onApply: (Double) -> Void
    let onClose: () -> Void
    let isRunning: Bool
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("校准最小拖动距离").font(.system(size: 23, weight: .semibold))
                    Text("逐轮观察短线，找出目标画板能稳定落墨的长度。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose).disabled(isRunning)
            }
            HStack {
                Button(calibration.area == nil ? "框选空白测试区" : "重新框选空白区", action: onSelectArea)
                    .disabled(isRunning)
                if let area = calibration.area {
                    Text("\(Int(area.width)) × \(Int(area.height)) 点").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("第 \(calibration.round) 轮").font(.system(size: 13, weight: .medium))
            }
            Text("每行三条，从上到下对应下表。请保持目标画板的黑笔、笔宽和速度不变；选出三条都清晰的最短一组。" + calibration.cleanupInstruction)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(calibration.candidates.enumerated()), id: \.offset) { index, length in
                    HStack(spacing: 14) {
                        Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).frame(width: 20)
                        Text("\(MovementCalibration.format(length)) 点")
                            .font(.system(size: 13)).monospacedDigit().frame(width: 84, alignment: .leading)
                        HStack(spacing: 14) {
                            ForEach(0..<3, id: \.self) { _ in
                                Capsule().fill(.primary).frame(width: max(2, min(46, length * 3)), height: 2.5)
                                    .frame(width: 48)
                            }
                        }
                        Spacer(minLength: 0)
                        Button(selectedRow == index ? "✓ 已选这组" : "选择这组") { selectedRow = index }
                            .disabled(isRunning || !calibration.hasDrawn || calibration.finished)
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                    if index < calibration.candidates.count - 1 { Divider() }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Text("上表短线仅为示意；目标画板中的短线使用真实屏幕点长度。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("测试区间：\(MovementCalibration.format(calibration.lowerBound))～\(MovementCalibration.format(calibration.upperBound)) 点")
                    .font(.system(size: 13)).monospacedDigit()
                Spacer()
                if let suggested = calibration.suggestedMinimum {
                    Text("推荐 \(MovementCalibration.format(suggested)) 点").font(.system(size: 13, weight: .semibold))
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
                    Button("应用推荐阈值") {
                        if let minimum = calibration.suggestedMinimum { onApply(minimum) }
                    }.buttonStyle(.borderedProminent).disabled(calibration.suggestedMinimum == nil)
                } else {
                    Button("重画本轮") { calibration.repeatRound() }.disabled(!calibration.hasDrawn)
                    Button("全部不清晰") { selectedRow = nil; calibration.noneVisible() }.disabled(!calibration.hasDrawn)
                    Button("继续缩小区间") {
                        if let selectedRow { calibration.selectShortestVisible(index: selectedRow); self.selectedRow = nil }
                    }.disabled(selectedRow == nil || !calibration.hasDrawn)
                    Button("结束并选用") {
                        if let selectedRow, calibration.hasDrawn { calibration.selectShortestVisible(index: selectedRow); self.selectedRow = nil }
                        if calibration.finishWithCurrentResult(), let minimum = calibration.suggestedMinimum { onApply(minimum) }
                    }.disabled(calibration.measuredMinimum == nil && selectedRow == nil)
                    Spacer()
                    Button("绘制本轮", action: onDraw).buttonStyle(.borderedProminent)
                        .disabled(calibration.area == nil || calibration.hasDrawn)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 660, minHeight: 600)
        .onChange(of: calibration.hasDrawn) { _, drawn in if !drawn { selectedRow = nil } }
    }
}
