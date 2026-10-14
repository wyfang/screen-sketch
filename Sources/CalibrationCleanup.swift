import Foundation
import CoreGraphics
import Darwin

/// 在开始校准绘制前记录完整计划。即使绘制中断，也保留整轮序号和测试笔画，
/// 后续沿原路径擦除；不会把矩形测试区转换为整块清空操作。
/// 坐标与 DrawingEngine 一致：paths 是相对于 area 的归一化坐标，area 是 Quartz 屏幕点。
struct CalibrationFootprint {
    let paths: [[CGPoint]]
    let area: CGRect
    let brushWidth: Double
    let targetPID: pid_t

    /// 擦除时作为 minimumMovement 使用，等待每段的完整距离后一次送到原端点。
    /// 仅在 replay 验证成功后使用；不合并拐角、数字笔画或相邻测试线。
    var longestSegmentLength: Double {
        paths.reduce(0) { longest, path in
            zip(path, path.dropFirst()).reduce(longest) { current, pair in
                let start = screenPoint(pair.0)
                let end = screenPoint(pair.1)
                return max(current, hypot(end.x - start.x, end.y - start.y))
            }
        }
    }

    fileprivate func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: area.minX + point.x * area.width,
                y: area.minY + point.y * area.height)
    }
}

enum CalibrationCleanupError: Error, LocalizedError, Equatable {
    case invalidArea
    case invalidTarget
    case invalidPaths
    case invalidBrushWidth

    var errorDescription: String? {
        switch self {
        case .invalidArea:
            return "记录的校准区无效，不能自动擦除。"
        case .invalidTarget:
            return "记录的目标程序无效，不能自动擦除。"
        case .invalidPaths:
            return "记录的校准笔画无效，不能自动擦除。"
        case .invalidBrushWidth:
            return "记录的铅笔宽度无效，不能自动擦除。"

        }
    }
}

/// 纯几何检查；不读取屏幕、不切换工具、不发送鼠标事件。
enum CalibrationCleanup {
    /// 沿记录的原中心线重放；实际橡皮宽度由目标画板设置。
    /// 原笔宽只用于验证 DrawingEngine 的坐标映射不会夹紧记录的端点。
    /// 这里检查记录的中心线和原映射边界，不推测未知橡皮的覆盖范围。
    static func replay(footprint: CalibrationFootprint) throws -> [[CGPoint]] {
        let area = footprint.area
        guard area.minX.isFinite, area.minY.isFinite, area.maxX.isFinite, area.maxY.isFinite,
              area.width.isFinite, area.height.isFinite, area.width > 0, area.height > 0 else {
            throw CalibrationCleanupError.invalidArea
        }
        guard footprint.targetPID > 0 else { throw CalibrationCleanupError.invalidTarget }
        guard footprint.brushWidth.isFinite, footprint.brushWidth > 0 else {
            throw CalibrationCleanupError.invalidBrushWidth
        }
        guard !footprint.paths.isEmpty,
              footprint.paths.allSatisfy({ !$0.isEmpty && $0.allSatisfy {
                  $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1
              } }) else { throw CalibrationCleanupError.invalidPaths }

        let margin = max(1, footprint.brushWidth / 2 + 1)
        guard area.width > margin * 2, area.height > margin * 2 else {
            throw CalibrationCleanupError.invalidArea
        }
        let safe = area.insetBy(dx: margin, dy: margin)
        for path in footprint.paths {
            for point in path {
                let center = footprint.screenPoint(point)
                guard center.x.isFinite, center.y.isFinite,
                      center.x >= safe.minX, center.x <= safe.maxX,
                      center.y >= safe.minY, center.y <= safe.maxY else {
                    throw CalibrationCleanupError.invalidPaths
                }
            }
        }
        return footprint.paths
    }
}
