import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum DrawingMode: String, CaseIterable, Identifiable {
    case outline
    case halftone
    case sketch
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: return "轮廓线稿"
        case .halftone: return "黑白照片"
        case .sketch: return "素描排线"
        case .solid: return "实心填充"
        }
    }

    var subtitle: String {
        switch self {
        case .outline: return "提取轮廓，笔画较少，绘制较快"
        case .halftone: return "按真实墨量安排单笔网点，保留照片明暗"
        case .sketch: return "用交叉排线表现阴影，保留主要轮廓"
        case .solid: return "沿黑色区域逐层向内绘制，保留粗线和白色孔洞"
        }
    }
}

struct Stroke {
    /// 左上角为原点。物理模式使用 Quartz 屏幕点；兼容模式使用工作画布坐标。
    let points: [CGPoint]
}

struct ProcessingSettings {
    var maxDimension: Int = 280
    var darkness: Double = 1
    var lineWidth: Double = 1
    var canvasAspect: Double = 1
    /// 工作画布中的最小有效拖动长度。0 保留圆点与连续子行的兼容行为。
    var minimumMovement: Double = 0
    /// 非 nil 时，笔宽、移动和间距均使用 Quartz 屏幕点，maxDimension 不再控制细节。
    var canvasSize: CGSize? = nil
    var backingScale: Double = 1
    /// 两条笔画仍可分辨的最小中心距，X/Y 分别对应横向/纵向分辨能力。
    var minimumSpacingX: Double = 0
    var minimumSpacingY: Double = 0
    /// 给收笔额外鼠标行程留边距；预览表达目标笔迹，不假定目标笔刷的平滑算法。
    var endExtension: Double = 0
    /// 在灰度采样上调节中间调，保持纯黑和纸白不变；不是相机曝光 EV。
    var exposure: Double = 0
    var contrast: Double = 1
    var shadowLift: Double = 0
    /// 实心填充的黑区阈值偏移；正值保留更浅的细节，不影响其他模式。
    var inkThresholdOffset: Double = 0
}

struct DrawingPlan {
    let mode: DrawingMode
    let strokes: [Stroke]
    let preview: CGImage
    let size: CGSize
    /// 物理模式使用实际屏幕点笔宽；兼容模式为同比缩放后的工作笔宽。
    let lineWidth: Double
    /// 物理模式使用实际屏幕点位移；兼容模式为同比缩放后的工作位移。
    let minimumMovement: Double
    /// 最终采样网格，含预算降级；不是预览位图的像素尺寸。
    var sampleSize: CGSize = .zero
    var effectiveSpacingX: Double = 0
    var effectiveSpacingY: Double = 0
    var resolutionNote: String? = nil

    var pointCount: Int { strokes.reduce(0) { $0 + $1.points.count } }

    var strokeLength: Double {
        strokes.reduce(0) { total, stroke in
            total + zip(stroke.points, stroke.points.dropFirst()).reduce(0) { length, pair in
                length + hypot(Double(pair.1.x - pair.0.x), Double(pair.1.y - pair.0.y))
            }
        }
    }
}

enum ImageProcessor {
    private struct ComplexityExceeded: Error {}
    private enum ProcessingError: LocalizedError {
        case imageUnreadable
        case allocationFailed
        case invalidSettings
        case tooManyStrokes
        case movementTooLarge

        var errorDescription: String? {
            switch self {
            case .imageUnreadable: return "无法读取这张图片，请选择 PNG、JPEG、HEIC 或其他系统支持的图片。"
            case .allocationFailed: return "无法为图片分配内存，请缩小画布后重试。"
            case .invalidSettings: return "画布尺寸、屏幕比例、笔宽、校准或图像调节参数无效。"
            case .tooManyStrokes: return "当前画布和笔宽需要的笔画超过预算，请增加目标画笔宽度或缩小画布。"
            case .movementTooLarge: return "最小移动距离超过画布可用范围，请降低最小移动距离。"
            }
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let values: [UInt8]
        let margin: Double

        var size: CGSize { CGSize(width: width, height: height) }

        func darkness(at point: CGPoint, multiplier: Double) -> Double {
            let x = max(0, min(width - 1, Int(point.x)))
            let y = max(0, min(height - 1, Int(point.y)))
            return min(1, max(0, (1 - Double(values[y * width + x]) / 255) * multiplier))
        }

        /// 短线单元较宽，按覆盖区域平均取样，避免仅采样中心点丢失细节与灰阶。
        func darkness(in rect: CGRect, multiplier: Double) -> Double {
            let left = max(0, min(width - 1, Int(floor(rect.minX))))
            let right = max(left + 1, min(width, Int(ceil(rect.maxX))))
            let top = max(0, min(height - 1, Int(floor(rect.minY))))
            let bottom = max(top + 1, min(height, Int(ceil(rect.maxY))))
            var sum = 0.0
            var area = 0.0
            for y in top..<bottom {
                let heightWeight = max(0, min(rect.maxY, Double(y + 1)) - max(rect.minY, Double(y)))
                for x in left..<right {
                    let widthWeight = max(0, min(rect.maxX, Double(x + 1)) - max(rect.minX, Double(x)))
                    let weight = widthWeight * heightWeight
                    sum += Double(values[y * width + x]) * weight
                    area += weight
                }
            }
            let average = area > 0 ? sum / area : 255
            return min(1, max(0, (1 - average / 255) * multiplier))
        }
    }

    /// ImageIO 在缩略图阶段处理 EXIF 方向，避免加载原始大图和手动猜测旋转方向。
    static func loadImage(url: URL, maxPixelSize: Int = 4096) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw ProcessingError.imageUnreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(8192, max(1, maxPixelSize)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else {
            throw ProcessingError.imageUnreadable
        }
        return image
    }

    static func makePlan(image: CGImage, mode: DrawingMode, settings: ProcessingSettings) throws -> DrawingPlan {
        guard settings.exposure.isFinite, (-2...2).contains(settings.exposure),
              settings.contrast.isFinite, (0.5...1.8).contains(settings.contrast),
              settings.shadowLift.isFinite, (0...1).contains(settings.shadowLift),
              settings.inkThresholdOffset.isFinite, (-64...64).contains(settings.inkThresholdOffset) else {
            throw ProcessingError.invalidSettings
        }
        if let canvasSize = settings.canvasSize {
            return try makePhysicalPlan(image: image, mode: mode, settings: settings, canvasSize: canvasSize)
        }
        guard settings.canvasAspect.isFinite, settings.canvasAspect > 0,
              settings.lineWidth.isFinite, settings.lineWidth > 0,
              settings.minimumMovement.isFinite, settings.minimumMovement >= 0,
              settings.darkness.isFinite else {
            throw ProcessingError.invalidSettings
        }
        if mode == .solid {
            let size = workingSize(dimension: min(640, max(32, settings.maxDimension)), aspect: settings.canvasAspect)
            var physical = settings
            physical.canvasSize = size
            return try makePhysicalPlan(image: image, mode: mode, settings: physical, canvasSize: size)
        }
        let darkness = min(3, max(0, settings.darkness))
        let originalDimension = min(640, max(32, settings.maxDimension))
        let originalWidth = workingSize(dimension: originalDimension, aspect: settings.canvasAspect).width
        let artwork = mode == .halftone ? false : try isInkArtwork(image: image)
        var dimension = originalDimension

        // 特别复杂的网点图逐次降低采样尺寸，保留整幅图而不截断后半部分笔画。
        // 最多十二次可以从 640 收敛到 32；极小笔宽无法满足预算时给出明确错误。
        for _ in 0..<12 {
            let currentWidth = workingSize(dimension: dimension, aspect: settings.canvasAspect).width
            let lineWidth = settings.lineWidth * currentWidth / originalWidth
            let minimumMovement = settings.minimumMovement * currentWidth / originalWidth
            let raster = try makeRaster(image: image, dimension: dimension,
                                        aspect: settings.canvasAspect, lineWidth: lineWidth, settings: settings)
            var strokes: [Stroke] = []
            do {
                if darkness > 0 {
                    switch mode {
                    case .outline:
                        strokes = outlineStrokes(raster: raster, darkness: darkness, lineWidth: lineWidth,
                                                  inkArtwork: artwork)
                    case .halftone:
                        strokes = try halftoneStrokes(raster: raster, darkness: darkness,
                                                      lineWidth: lineWidth, minimumMovement: minimumMovement)
                    case .sketch:
                        strokes = sketchStrokes(raster: raster, darkness: darkness, lineWidth: lineWidth,
                                                 inkArtwork: artwork)
                    case .solid:
                        break // 已由区域填充分支处理。
                    }
                }
                let points = strokes.reduce(0) { $0 + $1.points.count }
                if strokes.count <= 36_000 && points <= 240_000 {
                    let preview = try render(strokes: strokes, width: raster.width, height: raster.height,
                                             lineWidth: lineWidth)
                    return DrawingPlan(mode: mode, strokes: strokes, preview: preview,
                                       size: raster.size, lineWidth: lineWidth,
                                       minimumMovement: minimumMovement)
                }
            } catch is ComplexityExceeded {
                // 先估算完整网点路径，再重做整幅图；不会生成或返回截断的路径。
            }
            let next = max(32, Int(Double(dimension) * 0.76))
            if next == dimension { break }
            dimension = next
        }
        throw ProcessingError.tooManyStrokes
    }

    private static let maximumStrokes = 36_000
    private static let maximumPoints = 240_000
    private static let maximumSampleCells = 1_000_000
    private static let maximumPreviewPixels = 16_777_216.0

    private struct PhysicalGrid {
        let columns: Int
        let rows: Int
        let rect: CGRect

        var pitchX: Double { Double(rect.width) / Double(columns) }
        var pitchY: Double { Double(rect.height) / Double(rows) }
    }

    /// 鼠标在屏幕点中运动；Retina 比例只决定位图预览的像素数，不能改变笔画长度。
    private static func makePhysicalPlan(image: CGImage, mode: DrawingMode,
                                         settings: ProcessingSettings, canvasSize: CGSize) throws -> DrawingPlan {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              canvasSize.width <= 1_000_000, canvasSize.height <= 1_000_000,
              settings.lineWidth.isFinite, settings.lineWidth > 0,
              settings.minimumMovement.isFinite, settings.minimumMovement >= 0,
              settings.minimumSpacingX.isFinite, settings.minimumSpacingX >= 0,
              settings.minimumSpacingY.isFinite, settings.minimumSpacingY >= 0,
              settings.endExtension.isFinite, settings.endExtension >= 0,
              settings.backingScale.isFinite, settings.backingScale > 0, settings.backingScale <= 16,
              settings.darkness.isFinite else { throw ProcessingError.invalidSettings }

        let brush = settings.lineWidth
        let minimum = settings.minimumMovement
        let margin = max(1, brush / 2 + 1) + settings.endExtension
        let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: margin, dy: margin)
        guard rect.width > brush, rect.height > brush else { throw ProcessingError.invalidSettings }
        if mode == .solid {
            return try makePhysicalFillPlan(image: image, settings: settings,
                                            canvasSize: canvasSize, safeRect: rect)
        }
        if mode != .halftone {
            return try makePhysicalVectorPlan(image: image, mode: mode, settings: settings,
                                              canvasSize: canvasSize, safeRect: rect)
        }
        let slack = max(0.000001, minimum * 0.000001, brush * 0.000001)
        // 每个连续墨区只画一笔；横向精细采样，纵向按实际笔宽排布。
        // 清楚分开的校准间距不限制深色区的连接；Retina 只影响预览像素数。
        // Source samples are positional observations, not independent brush marks.
        // A long minimum stroke can still begin/end at a fine source coordinate.
        let baseX = min(0.5, brush * 0.5)
        let baseY = brush
        guard minimum + brush + slack <= max(rect.width, rect.height) else { throw ProcessingError.movementTooLarge }

        let requestedColumns = max(1, floor(Double(rect.width) / baseX))
        let requestedRows = max(1, floor(Double(rect.height) / baseY))
        // 优先降低横向采样，保留笔宽行距；连一列都超预算时再减少行数。
        var rows = Int(min(requestedRows, Double(maximumSampleCells)))
        var columns = Int(min(requestedColumns, floor(Double(maximumSampleCells) / Double(rows))))
        let brightness = min(3, max(0, settings.darkness))

        // 重做整幅图直到完整路径符合预算；没有截断笔画或丢弃图像的后半部。
        for _ in 0..<64 {
            let grid = PhysicalGrid(columns: columns, rows: rows, rect: rect)
            let sampleSize = CGSize(width: columns, height: rows)
            let raster = try physicalRaster(image: image, grid: grid, settings: settings)
            do {
                var strokes: [Stroke] = []
                if brightness > 0 {
                    switch mode {
                    case .halftone:
                        strokes = try physicalHalftone(raster: raster, grid: grid,
                                                       darkness: brightness, brush: brush,
                                                       minimumMovement: minimum, slack: slack)
                    case .outline, .sketch, .solid:
                        break // 已由独立矢量分支处理。
                    }
                }
                let points = strokes.reduce(0) { $0 + $1.points.count }
                guard strokes.count <= maximumStrokes, points <= maximumPoints else {
                    throw ComplexityExceeded()
                }
                let rendered = try physicalPreview(strokes: strokes, canvasSize: canvasSize,
                                                    lineWidth: brush, backingScale: settings.backingScale)
                var notes: [String] = []
                notes.append("按实际墨量生成单笔网点；深色允许相接，窄竖线改用纵向笔迹")
                if settings.endExtension > 0 {
                    notes.append("预览为目标笔迹；收笔额外鼠标行程 \(String(format: "%.3g", settings.endExtension)) 点，画布已留边距")
                }
                if Double(columns) < requestedColumns || Double(rows) < requestedRows {
                    notes.append("路径预算已降低整幅图的网点密度；单个网点仍只画一笔，笔迹会更稀")
                }
                if Double(rows) < requestedRows {
                    notes.append("纵向行距也因预算增大，深色会变浅")
                }
                if rendered.reduced {
                    notes.append("预览位图因内存预算降低像素数；屏幕点坐标及绘制精度保持不变")
                }
                return DrawingPlan(mode: mode, strokes: strokes, preview: rendered.image,
                                   size: canvasSize, lineWidth: brush, minimumMovement: minimum,
                                   sampleSize: sampleSize, effectiveSpacingX: grid.pitchX,
                                   effectiveSpacingY: grid.pitchY,
                                   resolutionNote: notes.isEmpty ? nil : notes.joined(separator: "；"))
            } catch is ComplexityExceeded {
                if columns > 1 { columns = max(1, Int(Double(columns) * 0.76)) }
                else if rows > 1 { rows = max(1, Int(Double(rows) * 0.76)) }
                else { break }
            }
        }
        throw ProcessingError.tooManyStrokes
    }

    /// 提线分辨率由源图决定，不能把最小拖动/笔画间距当成像素格去缩小源图。
    /// 先得到完整连续曲线，最后在屏幕点中简化；Retina 只影响返回的预览。
    private static func makePhysicalFillPlan(image: CGImage, settings: ProcessingSettings,
                                             canvasSize: CGSize, safeRect: CGRect) throws -> DrawingPlan {
        let fit = min(safeRect.width / Double(image.width), safeRect.height / Double(image.height))
        let fitted = CGSize(width: Double(image.width) * fit, height: Double(image.height) * fit)
        let imageRect = CGRect(x: safeRect.midX - fitted.width / 2, y: safeRect.midY - fitted.height / 2,
                               width: fitted.width, height: fitted.height)
        let pitch = min(0.5, settings.lineWidth / 4)
        let requestedX = max(4, ceil(fitted.width / pitch))
        let requestedY = max(4, ceil(fitted.height / pitch))
        let sampleScale = min(1, sqrt(Double(maximumSampleCells) / ((requestedX + 2) * (requestedY + 2))))
        var factor = 1.0
        for _ in 0..<12 {
            let columns = max(4, Int(floor(requestedX * sampleScale / factor)))
            let rows = max(4, min(Int(floor(requestedY * sampleScale / factor)), maximumSampleCells / (columns + 2) - 2))
            let grid = PhysicalGrid(columns: columns, rows: rows, rect: imageRect)
            let raster = paddedRaster(try physicalRaster(image: image, grid: grid, settings: settings))
            let mask = settings.darkness > 0
                ? inkMask(raster: raster, darkness: min(3, settings.darkness), inset: 0,
                          thresholdOffset: settings.inkThresholdOffset)
                : [Bool](repeating: false, count: raster.width * raster.height)
            do {
                let fill = try FillPlanner.make(mask: mask, width: raster.width, height: raster.height,
                    origin: CGPoint(x: imageRect.minX - grid.pitchX, y: imageRect.minY - grid.pitchY),
                    pitch: CGSize(width: grid.pitchX, height: grid.pitchY),
                    brush: settings.lineWidth, minimumMovement: settings.minimumMovement)
                let strokes = fill.paths.map { Stroke(points: $0) }
                let preview = try physicalPreview(strokes: strokes, canvasSize: canvasSize,
                    lineWidth: settings.lineWidth, backingScale: settings.backingScale)
                var notes = ["黑区从边缘向内填充，相邻圈按笔宽重叠；安全连接圈线，白孔与分裂区域抬笔"]
                if fill.skippedSmallPaths > 0 {
                    notes.append("\(fill.skippedSmallPaths) 处独立墨迹小于最短落笔长度，未向白区扩张")
                }
                if sampleScale < 1 || factor > 1 {
                    notes.append("资源预算降低整幅区域采样；更细画笔或更大画布可能无法完整表现")
                }
                if settings.endExtension > 0 { notes.append("预览为目标笔迹；末端补偿依赖画板响应，可能影响填充边缘") }
                if preview.reduced { notes.append("预览位图降低像素数，屏幕点路径保持不变") }
                return DrawingPlan(mode: .solid, strokes: strokes, preview: preview.image,
                    size: canvasSize, lineWidth: settings.lineWidth, minimumMovement: settings.minimumMovement,
                    sampleSize: CGSize(width: columns, height: rows),
                    effectiveSpacingX: grid.pitchX, effectiveSpacingY: grid.pitchY,
                    resolutionNote: notes.joined(separator: "；"))
            } catch is FillPlanner.Failure {
                factor *= 1.4
            }
        }
        throw ProcessingError.tooManyStrokes
    }

    private static func makePhysicalVectorPlan(image: CGImage, mode: DrawingMode,
                                                settings: ProcessingSettings, canvasSize: CGSize,
                                                safeRect: CGRect) throws -> DrawingPlan {
        let fit = min(Double(safeRect.width) / Double(image.width),
                      Double(safeRect.height) / Double(image.height))
        let fitted = CGSize(width: Double(image.width) * fit, height: Double(image.height) * fit)
        let imageRect = CGRect(x: safeRect.midX - fitted.width / 2,
                               y: safeRect.midY - fitted.height / 2,
                               width: fitted.width, height: fitted.height)
        guard settings.minimumMovement <= hypot(safeRect.width, safeRect.height) else {
            throw ProcessingError.movementTooLarge
        }
        let artwork = try isInkArtwork(image: image)
        let brightness = min(3, max(0, settings.darkness))
        let sourceScale = min(1, 2048 / Double(max(image.width, image.height)),
                              sqrt(Double(maximumSampleCells) / Double(image.width) / Double(image.height)))
        var factor = 1.0
        var previousSize = CGSize.zero
        for _ in 0..<18 {
            let columns = max(4, Int(ceil(Double(image.width) * sourceScale / factor)))
            let rows = max(4, Int(ceil(Double(image.height) * sourceScale / factor)))
            let size = CGSize(width: columns, height: rows)
            if size == previousSize { break }
            previousSize = size
            let grid = PhysicalGrid(columns: columns, rows: rows, rect: imageRect)
            let raster = paddedRaster(try physicalRaster(image: image, grid: grid, settings: settings))
            let pixelPitch = min(grid.pitchX, grid.pitchY)
            let rasterBrush = settings.lineWidth / pixelPitch
            var sampled: [Stroke] = []
            if brightness > 0 {
                sampled = outlineStrokes(raster: raster, darkness: brightness,
                                         lineWidth: rasterBrush, inkArtwork: artwork,
                                         minimumLength: 0, tolerance: 0.18)
                if mode == .sketch && !artwork {
                    // 排线保留按实际笔宽/间距决定的密度，轮廓仍使用上面的独立提线。
                    let spacing = max(settings.minimumSpacingX, settings.minimumSpacingY) / pixelPitch
                    sampled += hatchStrokes(raster: raster, darkness: brightness, lineWidth: rasterBrush,
                                             pitch: max(3, rasterBrush * 3, spacing), slope: 1,
                                             levels: [0.10, 0.27, 0.44, 0.61])
                    sampled += hatchStrokes(raster: raster, darkness: brightness, lineWidth: rasterBrush,
                                             pitch: max(3.6, rasterBrush * 3.6, spacing), slope: -1,
                                             levels: [0.56, 0.68, 0.80, 0.92])
                    sampled += hatchStrokes(raster: raster, darkness: brightness, lineWidth: rasterBrush,
                                             pitch: max(1.5, rasterBrush * 1.5, spacing), slope: 0,
                                             levels: [0.90])
                }
            }
            let mapped = sampled.map { stroke in
                Stroke(points: stroke.points.map { point in
                    CGPoint(x: imageRect.minX + (point.x - 1) * grid.pitchX,
                            y: imageRect.minY + (point.y - 1) * grid.pitchY)
                })
            }
            let tolerance = max(0.25, min(settings.lineWidth * 0.3, 1.5))
            let strokes = executableStrokes(mapped, minimumMovement: settings.minimumMovement,
                                            safeRect: safeRect, tolerance: tolerance)
            if strokes.count <= maximumStrokes,
               strokes.reduce(0, { $0 + $1.points.count }) <= maximumPoints {
                let preview = try physicalPreview(strokes: strokes, canvasSize: canvasSize,
                                                   lineWidth: settings.lineWidth,
                                                   backingScale: settings.backingScale)
                var notes = [artwork ? "白底线稿：自适应墨线分割 · 开源中心线追踪与贝塞尔拟合" : "照片：细化单像素边缘后追踪"]
                if settings.minimumMovement > 0 {
                    notes.append("最短位移用于独立落笔；曲线拐角与终点保留，小于该距离的独立细节可能无法绘制")
                }
                if factor > 1 { notes.append("路径预算降低了整幅图的提线密度，未截断笔画") }
                if settings.endExtension > 0 {
                    notes.append("预览为目标笔迹；收笔额外鼠标行程已留边距")
                }
                if preview.reduced { notes.append("预览位图因内存预算降低像素数，屏幕点路径保持不变") }
                return DrawingPlan(mode: mode, strokes: strokes, preview: preview.image,
                                   size: canvasSize, lineWidth: settings.lineWidth,
                                   minimumMovement: settings.minimumMovement,
                                   sampleSize: size, effectiveSpacingX: grid.pitchX,
                                   effectiveSpacingY: grid.pitchY,
                                   resolutionNote: notes.joined(separator: "；"))
            }
            factor *= 1.4
        }
        throw ProcessingError.tooManyStrokes
    }

    /// 白纸上的灰/黑墨线采用骨架；彩色和有大面积中间调的照片采用边缘。
    /// 判别源图而不是带留白的画布，避免宽画布的空白把照片误判成线稿。
    private static func isInkArtwork(image: CGImage) throws -> Bool {
        let scale = min(1, 192 / Double(max(image.width, image.height)))
        let width = max(1, Int(ceil(Double(image.width) * scale)))
        let height = max(1, Int(ceil(Double(image.height) * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw ProcessingError.allocationFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let values = data.assumingMemoryBound(to: UInt8.self)
        var paper = 0
        var colored = 0
        var gray = [Int](repeating: 255, count: width * height)
        var ink = 0
        for i in 0..<(width * height) {
            let r = Int(values[i * 4]), g = Int(values[i * 4 + 1]), b = Int(values[i * 4 + 2])
            gray[i] = (r * 54 + g * 183 + b * 19) / 256
            if gray[i] < 228 { ink += 1 }
            if min(r, g, b) >= 235 { paper += 1 }
            if max(r, g, b) - min(r, g, b) > 18 { colored += 1 }
        }
        let count = Double(width * height)
        guard Double(paper) / count >= 0.65, Double(colored) / count <= 0.02 else { return false }
        var solid = 0
        if width > 4 && height > 4 {
            for y in 2..<(height - 2) {
                for x in 2..<(width - 2) {
                    let i = y * width + x
                    if gray[i] < 228, gray[i - 2] < 228, gray[i + 2] < 228,
                       gray[i - width * 2] < 228, gray[i + width * 2] < 228 { solid += 1 }
                }
            }
        }
        // 白底实心形状、灰度商品照片仍须提取边界；不能仅凭纸白比例骨架化。
        return ink == 0 || Double(solid) / Double(ink) < 0.2
    }

    private static func physicalRaster(image: CGImage, grid: PhysicalGrid,
                                       settings: ProcessingSettings) throws -> Raster {
        guard let context = CGContext(data: nil, width: grid.columns, height: grid.rows,
                                      bitsPerComponent: 8, bytesPerRow: grid.columns,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ProcessingError.allocationFailed
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: grid.columns, height: grid.rows))
        // 先在真实屏幕点里等比适配，再分别换算到 X/Y 网格，避免异向校准拉伸照片。
        let fitScale = min(Double(grid.rect.width) / Double(image.width),
                           Double(grid.rect.height) / Double(image.height))
        let width = Double(image.width) * fitScale
        let height = Double(image.height) * fitScale
        let imageRect = CGRect(x: (Double(grid.rect.width) - width) / (2 * grid.pitchX),
                               y: (Double(grid.rect.height) - height) / (2 * grid.pitchY),
                               width: width / grid.pitchX, height: height / grid.pitchY)
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
        guard let data = context.data else { throw ProcessingError.allocationFailed }
        let values = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: grid.columns * grid.rows))
        return Raster(width: grid.columns, height: grid.rows,
                      values: adjustedGray(values, settings: settings), margin: 0)
    }

    /// A 256-entry LUT keeps tone processing independent of raster resolution.
    /// Endpoints remain fixed so exposure cannot turn padding/transparent paper
    /// into ink, and reducing contrast cannot remove a solid black line.
    static func grayscaleToneLUT(exposure: Double, contrast: Double, shadowLift: Double) -> [UInt8] {
        if exposure == 0, contrast == 1, shadowLift == 0 { return (0...255).map(UInt8.init) }
        let exponent = pow(2, -exposure / 2)
        return (0...255).map { value in
            if value == 0 || value == 255 { return UInt8(value) }
            var x = pow(Double(value) / 255, exponent)
            x = x < 0.5 ? 0.5 * pow(2 * x, contrast)
                : 1 - 0.5 * pow(2 * (1 - x), contrast)
            x += shadowLift * 2 * x * (1 - x) * (1 - x)
            return UInt8(min(255, max(0, (x * 255).rounded())))
        }
    }

    private static func adjustedGray(_ values: [UInt8], settings: ProcessingSettings) -> [UInt8] {
        guard settings.exposure != 0 || settings.contrast != 1 || settings.shadowLift != 0 else { return values }
        let lut = grayscaleToneLUT(exposure: settings.exposure, contrast: settings.contrast,
                                  shadowLift: settings.shadowLift)
        return values.map { lut[Int($0)] }
    }

    private static func paddedRaster(_ raster: Raster) -> Raster {
        let width = raster.width + 2
        let height = raster.height + 2
        var values = [UInt8](repeating: 255, count: width * height)
        for y in 0..<raster.height {
            for x in 0..<raster.width { values[(y + 1) * width + x + 1] = raster.values[y * raster.width + x] }
        }
        return Raster(width: width, height: height, values: values, margin: 1)
    }

    private static func executableStrokes(_ strokes: [Stroke], minimumMovement: Double,
                                           safeRect: CGRect, tolerance: Double = 0.5) -> [Stroke] {
        var result: [Stroke] = []
        for stroke in strokes {
            var points: [CGPoint] = []
            for point in stroke.points {
                let p = CGPoint(x: min(safeRect.maxX, max(safeRect.minX, point.x)),
                                y: min(safeRect.maxY, max(safeRect.minY, point.y)))
                if points.last != p { points.append(p) }
            }
            guard points.count >= 2 else { continue }
            // M measures an entire isolated visible stroke. It cannot be used
            // as a positional quantization or a chord error allowance.
            let length = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
                total + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            }
            guard length + 0.000001 >= minimumMovement else { continue }
            let simplified = simplify(points, tolerance: tolerance)
            let finalLength = zip(simplified, simplified.dropFirst()).reduce(0.0) {
                $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }
            if simplified.count >= 2, finalLength + 0.000001 >= minimumMovement {
                result.append(Stroke(points: simplified))
            }
        }
        return result
    }

    private static func physicalHalftone(raster: Raster, grid: PhysicalGrid, darkness: Double,
                                          brush: Double, minimumMovement: Double, slack: Double,
                                          recoverVertical: Bool = true) throws -> [Stroke] {
        let columns = grid.columns
        let rows = grid.rows
        let densities = raster.values.map { min(1, max(0, (1 - Double($0) / 255) * darkness)) }
        // The pulse width is physical; X sampling stays fine. The minimum is a
        // whole-stroke constraint, never a quantization of start/end positions.
        let minimumSpan = minimumMovement + brush + slack
        let minimumSamples = max(1, Int(ceil(minimumSpan / grid.pitchX)))
        let runWidth = Double(minimumSamples)
        let capDeficit = (1 - Double.pi / 4) * brush / grid.pitchX
        var strokes: [Stroke] = []
        // Only rows rejected because their whole source island is narrower than
        // a viable horizontal mark can participate in a vertical recovery pass.
        // Pixels already considered by horizontal tone rendering stay white.
        var narrowInk = recoverVertical ? [Double](repeating: 0, count: densities.count) : []
        for y in 0..<rows {
            let forward = y.isMultiple(of: 2)
            let centerY = grid.rect.minY + (Double(y) + 0.5) * grid.pitchY
            let row = Array(densities[(y * columns)..<((y + 1) * columns)])
            let scan = forward ? row : Array(row.reversed())
            var x = 0
            var regionIndex = 0
            while x < columns {
                // Exact paper gaps stay white. Do not bridge them just to make a
                // short stroke executable. Very narrow islands are undrawable
                // by a horizontal minimum-length pulse enter vertical recovery.
                while x < columns && scan[x] < 0.008 { x += 1 }
                let begin = x
                while x < columns && scan[x] >= 0.008 { x += 1 }
                let end = x
                guard end - begin >= minimumSamples else {
                    if recoverVertical {
                        for cursor in begin..<end {
                            let sourceX = forward ? cursor : columns - 1 - cursor
                            narrowInk[y * columns + sourceX] = scan[cursor]
                        }
                    }
                    continue
                }
                // A low-discrepancy phase changes where successive rows start
                // accumulating ink, rather than lining up every dot on a grid.
                let phase = (Double(y) * 0.6180339887498949 + Double(regionIndex) * 0.4142135623730951)
                    .truncatingRemainder(dividingBy: 1)
                var balance = (phase - 0.5) * runWidth
                var cursor = begin
                var start: Int?
                var blackCount = 0
                var runs: [(Int, Int)] = []
                // A lone black pixel on gray paper must not force a whole black
                // minimum-length pulse. Only a viable continuous solid span can
                // bypass area accumulation to preserve its exact leading edge.
                var solidRemaining = [Int](repeating: 0, count: end - begin + 1)
                for index in stride(from: end - 1, through: begin, by: -1) {
                    if scan[index] >= 0.98 {
                        solidRemaining[index - begin] = solidRemaining[index - begin + 1] + 1
                    }
                }
                while cursor < end {
                    if let active = start {
                        balance += scan[cursor] - 1
                        blackCount += 1
                        cursor += 1
                        if blackCount >= minimumSamples && balance <= 0 {
                            runs.append((active, cursor))
                            balance += capDeficit
                            start = nil; blackCount = 0
                        }
                    } else {
                        // Full-black source is continuous ink, not stippled.
                        let solid = solidRemaining[cursor - begin] >= minimumSamples
                        balance += scan[cursor]
                        if (solid || balance >= runWidth / 2) && end - cursor >= minimumSamples {
                            start = cursor
                            blackCount = 1
                            balance -= 1
                        }
                        cursor += 1
                    }
                }
                if let active = start {
                    // The start guard guarantees the residual run is long enough.
                    runs.append((active, end))
                } else if balance >= runWidth / 2,
                          end - (runs.last?.1 ?? begin) >= minimumSamples {
                    // Quantize the residual area at the right boundary instead
                    // of always losing the last fraction of a pulse.
                    runs.append((end - minimumSamples, end))
                }
                var connected: [(Int, Int)] = []
                for run in runs {
                    if let last = connected.last, last.1 == run.0 {
                        connected[connected.count - 1] = (last.0, run.1)
                    } else { connected.append(run) }
                }
                for run in connected {
                    let leftIndex = forward ? run.0 : columns - run.1
                    let rightIndex = forward ? run.1 : columns - run.0
                    let left = grid.rect.minX + Double(leftIndex) * grid.pitchX + brush / 2
                    let right = grid.rect.minX + Double(rightIndex) * grid.pitchX - brush / 2
                    guard right - left + 0.000001 >= minimumMovement else { continue }
                    guard strokes.count < maximumStrokes, (strokes.count + 1) * 2 <= maximumPoints else { throw ComplexityExceeded() }
                    let points = [CGPoint(x: left, y: centerY), CGPoint(x: right, y: centerY)]
                    strokes.append(Stroke(points: forward ? points : points.reversed()))
                }
                regionIndex += 1
            }
        }
        if recoverVertical && narrowInk.contains(where: { $0 > 0 }) {
            // A pen-width line can straddle two fixed columns after image
            // resampling. Collect its actual area and place one vertical scan
            // at the ink centroid, instead of dithering two partial columns.
            var columnInk = [Double](repeating: 0, count: columns)
            for y in 0..<rows {
                for x in 0..<columns { columnInk[x] += narrowInk[y * columns + x] }
            }
            var column = 0
            while column < columns {
                while column < columns && columnInk[column] == 0 { column += 1 }
                let first = column
                while column < columns && columnInk[column] > 0 { column += 1 }
                let last = column
                guard last > first && Double(last - first) * grid.pitchX <= brush * 4 else { continue }
                var rowInk = [Double](repeating: 0, count: rows)
                var occupied = 0
                for y in 0..<rows {
                    for x in first..<last { rowInk[y] += narrowInk[y * columns + x] * grid.pitchX }
                    if rowInk[y] > 0 { occupied += 1 }
                }
                let total = rowInk.reduce(0, +)
                guard occupied > 0 && total / Double(occupied) <= brush * 1.15 else { continue }
                let columnWeight = columnInk[first..<last].reduce(0, +)
                var centroid = 0.0
                for x in first..<last { centroid += (Double(x) + 0.5) * columnInk[x] }
                let center = grid.rect.minX + centroid / columnWeight * grid.pitchX
                let gray = rowInk.map { UInt8(max(0, min(255, ((1 - min(1, $0 / brush)) * 255).rounded()))) }
                let raster = Raster(width: rows, height: 1, values: gray, margin: 0)
                let oneLine = PhysicalGrid(columns: rows, rows: 1,
                    rect: CGRect(x: grid.rect.minY, y: center - brush / 2,
                                 width: grid.rect.height, height: brush))
                let recovered = try physicalHalftone(raster: raster, grid: oneLine, darkness: 1,
                    brush: brush, minimumMovement: minimumMovement, slack: slack, recoverVertical: false)
                guard strokes.count + recovered.count <= maximumStrokes,
                      (strokes.count + recovered.count) * 2 <= maximumPoints else { throw ComplexityExceeded() }
                strokes += recovered.map { Stroke(points: $0.points.map { CGPoint(x: $0.y, y: $0.x) }) }
                for y in 0..<rows {
                    for x in first..<last { narrowInk[y * columns + x] = 0 }
                }
            }
            guard narrowInk.contains(where: { $0 > 0 }) else { return strokes }
            // Collapse fine X samples into one-pen-width vertical scan rows.
            // Area-weighted averaging preserves thin antialias edges; no second
            // pass traverses the broad gray/photo regions already drawn above.
            // Recovery never allocates a larger sample grid than the horizontal
            // pass. Extremely fine brushes may already have coarsened X samples.
            let verticalRows = max(1, Int(min(Double(columns), floor(grid.rect.width / brush))))
            let sourceColumnsPerRow = Double(columns) / Double(verticalRows)
            var verticalGray = [UInt8](repeating: 255, count: rows * verticalRows)
            for x in 0..<verticalRows {
                let left = Double(x) * sourceColumnsPerRow
                let right = Double(x + 1) * sourceColumnsPerRow
                for y in 0..<rows {
                    var sum = 0.0
                    for sourceX in Int(floor(left))..<min(columns, Int(ceil(right))) {
                        let weight = max(0, min(right, Double(sourceX + 1)) - max(left, Double(sourceX)))
                        sum += narrowInk[y * columns + sourceX] * weight
                    }
                    verticalGray[x * rows + y] = UInt8(max(0, min(255,
                        ((1 - sum / sourceColumnsPerRow) * 255).rounded())))
                }
            }
            let verticalRaster = Raster(width: rows, height: verticalRows, values: verticalGray, margin: 0)
            let verticalGrid = PhysicalGrid(columns: rows, rows: verticalRows,
                rect: CGRect(x: grid.rect.minY, y: grid.rect.minX, width: grid.rect.height, height: grid.rect.width))
            let verticalStrokes = try physicalHalftone(raster: verticalRaster, grid: verticalGrid,
                darkness: 1, brush: brush, minimumMovement: minimumMovement, slack: slack, recoverVertical: false)
            guard strokes.count + verticalStrokes.count <= maximumStrokes,
                  (strokes.count + verticalStrokes.count) * 2 <= maximumPoints else { throw ComplexityExceeded() }
            strokes += verticalStrokes.map { stroke in
                Stroke(points: stroke.points.map { CGPoint(x: $0.y, y: $0.x) })
            }
        }
        return strokes
    }

    private static func physicalPreview(strokes: [Stroke], canvasSize: CGSize,
                                          lineWidth: Double, backingScale: Double) throws -> (image: CGImage, reduced: Bool) {
        let nativeWidth = Double(canvasSize.width) * backingScale
        let nativeHeight = Double(canvasSize.height) * backingScale
        let reduction = min(1, 8192 / max(nativeWidth, nativeHeight),
                            sqrt(maximumPreviewPixels / nativeWidth / nativeHeight))
        let width = max(1, Int(ceil(nativeWidth * reduction)))
        let height = max(1, Int(ceil(nativeHeight * reduction)))
        // 薄于预览像素的多条重叠线需先高分辨率合并，再缩回原生像素数；直接
        // 栅格化会把实心黑色误采样成灰色。最终像素尺寸仍由显示器 backing 决定。
        let outputScale = min(Double(width) / Double(canvasSize.width), Double(height) / Double(canvasSize.height))
        let superFactor = min(8192 / Double(max(width, height)),
                              sqrt(maximumPreviewPixels / Double(width) / Double(height)),
                              max(1, ceil(2 / (lineWidth * outputScale))))
        let renderedWidth = max(width, Int(floor(Double(width) * superFactor)))
        let renderedHeight = max(height, Int(floor(Double(height) * superFactor)))
        guard let context = CGContext(data: nil, width: renderedWidth, height: renderedHeight,
                                      bitsPerComponent: 8, bytesPerRow: renderedWidth,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ProcessingError.allocationFailed }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: renderedWidth, height: renderedHeight))
        context.translateBy(x: 0, y: CGFloat(renderedHeight))
        context.scaleBy(x: Double(renderedWidth) / Double(canvasSize.width),
                        y: -Double(renderedHeight) / Double(canvasSize.height))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        context.beginPath()
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            context.move(to: first)
            for point in stroke.points.dropFirst() { context.addLine(to: point) }
        }
        context.strokePath()
        guard let rendered = context.makeImage() else { throw ProcessingError.allocationFailed }
        if renderedWidth == width && renderedHeight == height { return (rendered, reduction < 0.999999) }
        guard let reduced = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ProcessingError.allocationFailed
        }
        reduced.interpolationQuality = .high
        reduced.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let preview = reduced.makeImage() else { throw ProcessingError.allocationFailed }
        return (preview, reduction < 0.999999)
    }

    private static func workingSize(dimension: Int, aspect: Double) -> CGSize {
        let width = aspect >= 1 ? dimension : max(1, Int((Double(dimension) * aspect).rounded()))
        let height = aspect >= 1 ? max(1, Int((Double(dimension) / aspect).rounded())) : dimension
        return CGSize(width: width, height: height)
    }

    private static func makeRaster(image: CGImage, dimension: Int, aspect: Double,
                                   lineWidth: Double, settings: ProcessingSettings) throws -> Raster {
        let size = workingSize(dimension: dimension, aspect: aspect)
        let width = Int(size.width)
        let height = Int(size.height)
        let margin = ceil(lineWidth / 2 + 1)
        guard Double(min(width, height)) > margin * 2 + 2,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ProcessingError.invalidSettings
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let availableWidth = Double(width) - margin * 2
        let availableHeight = Double(height) - margin * 2
        let scale = min(availableWidth / Double(image.width), availableHeight / Double(image.height))
        let fittedWidth = Double(image.width) * scale
        let fittedHeight = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - fittedWidth) / 2,
                                      y: (Double(height) - fittedHeight) / 2,
                                      width: fittedWidth, height: fittedHeight))
        guard let data = context.data else { throw ProcessingError.allocationFailed }
        let values = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: width * height))
        return Raster(width: width, height: height,
                      values: adjustedGray(values, settings: settings), margin: margin)
    }

    private static func render(strokes: [Stroke], width: Int, height: Int,
                               lineWidth: Double) throws -> CGImage {
        // 子像素排线若直接画到低分辨率位图，CoreGraphics 的采样会漏掉部分子行。
        // 先把实际笔画绘到较高分辨率，再缩小；不改变路径、笔宽或鼠标绘制计划。
        let maximumScale = max(1, 4096 / max(width, height))
        let scale = min(Double(maximumScale), max(2, ceil(1 / lineWidth)))
        let renderedWidth = Int(Double(width) * scale)
        let renderedHeight = Int(Double(height) * scale)
        guard let context = CGContext(data: nil, width: renderedWidth, height: renderedHeight, bitsPerComponent: 8,
                                      bytesPerRow: renderedWidth, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ProcessingError.allocationFailed
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: renderedWidth, height: renderedHeight))
        // 图片和鼠标坐标均向下增长；CGContext 默认向上增长，需要一次翻转。
        context.translateBy(x: 0, y: CGFloat(renderedHeight))
        context.scaleBy(x: scale, y: -scale)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        context.beginPath()
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            context.move(to: first)
            for point in stroke.points.dropFirst() { context.addLine(to: point) }
        }
        // 一次栅格化所有笔画，防止邻接子像素边缘分别混合而产生虚假的白色横带。
        context.strokePath()
        guard let rendered = context.makeImage() else { throw ProcessingError.allocationFailed }
        if scale == 1 { return rendered }
        guard let reduced = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ProcessingError.allocationFailed
        }
        reduced.interpolationQuality = .high
        reduced.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let preview = reduced.makeImage() else { throw ProcessingError.allocationFailed }
        return preview
    }

    private static func halftoneStrokes(raster: Raster, darkness: Double,
                                       lineWidth: Double, minimumMovement: Double) throws -> [Stroke] {
        let useShortLines = minimumMovement > 0
        let pitchY = max(1, lineWidth)
        // 加入极小的正余量，防止浮点换算使理论上等长的笔画刚好落在阈值之下。
        let lengthSlack = max(0.000001, minimumMovement * 0.000001)
        let pitchX = useShortLines ? max(1, minimumMovement + lineWidth + lengthSlack) : pitchY
        let availableWidth = Double(raster.width) - raster.margin * 2
        if useShortLines && pitchX > availableWidth { throw ProcessingError.movementTooLarge }
        let columns = max(1, Int(availableWidth / pitchX))
        let rows = max(1, Int((Double(raster.height) - raster.margin * 2) / pitchY))
        let startX = (Double(raster.width) - Double(columns) * pitchX) / 2 + pitchX / 2
        let startY = (Double(raster.height) - Double(rows) * pitchY) / 2 + pitchY / 2
        var levels = [Double](repeating: 1, count: columns * rows)
        var black = [Bool](repeating: false, count: columns * rows)
        for y in 0..<rows {
            for x in 0..<columns {
                let point = CGPoint(x: startX + Double(x) * pitchX, y: startY + Double(y) * pitchY)
                if useShortLines {
                    let cell = CGRect(x: point.x - pitchX / 2, y: point.y - pitchY / 2,
                                      width: pitchX, height: pitchY)
                    levels[y * columns + x] = 1 - raster.darkness(in: cell, multiplier: darkness)
                } else {
                    levels[y * columns + x] = 1 - raster.darkness(at: point, multiplier: darkness)
                }
            }
        }
        // 蛇形 Floyd–Steinberg 扩散，固定扫描顺序使重复处理结果一致。
        for y in 0..<rows {
            let direction = y.isMultiple(of: 2) ? 1 : -1
            for step in 0..<columns {
                let x = direction == 1 ? step : columns - 1 - step
                let index = y * columns + x
                let original = levels[index]
                let output: Double = original < 0.5 ? 0 : 1
                black[index] = output == 0
                let error = original - output
                diffuse(error * 7 / 16, toX: x + direction, y: y, columns: columns, rows: rows, levels: &levels)
                diffuse(error * 3 / 16, toX: x - direction, y: y + 1, columns: columns, rows: rows, levels: &levels)
                diffuse(error * 5 / 16, toX: x, y: y + 1, columns: columns, rows: rows, levels: &levels)
                diffuse(error / 16, toX: x + direction, y: y + 1, columns: columns, rows: rows, levels: &levels)
            }
        }
        var runs: [(y: Int, first: Int, last: Int)] = []
        for y in 0..<rows {
            var x = 0
            while x < columns {
                if !black[y * columns + x] { x += 1; continue }
                let first = x
                while x + 1 < columns && black[y * columns + x + 1] { x += 1 }
                let last = x
                runs.append((y, first, last))
                x += 1
            }
        }
        if runs.isEmpty { return [] }
        let rawPasses = lineWidth < 1 ? ceil(pitchY / lineWidth) : 1
        let pathMultiplier = useShortLines ? rawPasses : 1
        guard rawPasses.isFinite, Double(runs.count) * pathMultiplier <= 36_000,
              Double(runs.count) * rawPasses * 2 <= 240_000 else { throw ComplexityExceeded() }
        let passes = Int(rawPasses)
        var strokes: [Stroke] = []
        strokes.reserveCapacity(runs.count)
        for run in runs {
            let centerY = startY + Double(run.y) * pitchY
            var left = startX + Double(run.first) * pitchX
            var right = startX + Double(run.last) * pitchX
            if useShortLines {
                // 连续黑色单元合并成足够长的水平线。不同子行分别落笔，避免用
                // 目标程序忽略的微小竖线连接，也不会从白色单元上穿过去。
                left += -pitchX / 2 + lineWidth / 2
                right += pitchX / 2 - lineWidth / 2
                let subPitch = pitchY / Double(passes)
                for pass in 0..<passes {
                    let y = centerY - pitchY / 2 + (Double(pass) + 0.5) * subPitch
                    let points = [CGPoint(x: left, y: y), CGPoint(x: right, y: y)]
                    strokes.append(Stroke(points: (pass + run.y).isMultiple(of: 2) ? points : points.reversed()))
                }
            } else if lineWidth < 1 {
                // 每个黑色栅格覆盖一个完整采样单元。细笔以多行往返填满这个单元，
                // 子行首尾连续连接，连接始终在黑色单元内，不多画穿过白色的线。
                left += -pitchX / 2 + lineWidth / 2
                right += pitchX / 2 - lineWidth / 2
                let subPitch = pitchY / Double(passes)
                var points: [CGPoint] = []
                points.reserveCapacity(passes * 2)
                for pass in 0..<passes {
                    let y = centerY - pitchY / 2 + (Double(pass) + 0.5) * subPitch
                    let ends = [CGPoint(x: left, y: y), CGPoint(x: right, y: y)]
                    points += (pass + run.y).isMultiple(of: 2) ? ends : ends.reversed()
                }
                strokes.append(Stroke(points: points))
            } else {
                if run.first == run.last {
                    // 极短的真实拖动形成圆点，也兼容只在拖动事件时落墨的画板。
                    let halfLength = min(0.12 * pitchX, 0.2 * lineWidth)
                    left -= halfLength
                    right += halfLength
                }
                let points = [CGPoint(x: left, y: centerY), CGPoint(x: right, y: centerY)]
                strokes.append(Stroke(points: run.y.isMultiple(of: 2) ? points : points.reversed()))
            }
        }
        return strokes
    }

    private static func diffuse(_ error: Double, toX x: Int, y: Int, columns: Int,
                                rows: Int, levels: inout [Double]) {
        if x >= 0 && x < columns && y >= 0 && y < rows { levels[y * columns + x] += error }
    }

    private static func sketchStrokes(raster: Raster, darkness: Double,
                                     lineWidth: Double, inkArtwork: Bool = false) -> [Stroke] {
        var strokes = outlineStrokes(raster: raster, darkness: darkness * 0.9,
                                     lineWidth: lineWidth, inkArtwork: inkArtwork)
        if inkArtwork { return strokes }
        let pitch = max(3, lineWidth * 3)
        strokes += hatchStrokes(raster: raster, darkness: darkness, lineWidth: lineWidth,
                                pitch: pitch, slope: 1, levels: [0.10, 0.27, 0.44, 0.61])
        strokes += hatchStrokes(raster: raster, darkness: darkness, lineWidth: lineWidth,
                                pitch: pitch * 1.2, slope: -1, levels: [0.56, 0.68, 0.80, 0.92])
        // 深黑区域增加水平线，避免只用稀疏交叉线使黑色变成浅灰。
        strokes += hatchStrokes(raster: raster, darkness: darkness, lineWidth: lineWidth,
                                pitch: max(1.5, lineWidth * 1.5), slope: 0, levels: [0.90])
        return strokes
    }

    private static func hatchStrokes(raster: Raster, darkness: Double, lineWidth: Double,
                                    pitch: Double, slope: Int, levels: [Double]) -> [Stroke] {
        let left = raster.margin + 0.5
        let right = Double(raster.width) - raster.margin - 0.5
        let top = raster.margin + 0.5
        let bottom = Double(raster.height) - raster.margin - 0.5
        let begin: Double
        let end: Double
        if slope == 1 {
            begin = top - right
            end = bottom - left
        } else if slope == -1 {
            begin = top + left
            end = bottom + right
        } else {
            begin = top
            end = bottom
        }
        let firstLine = Int(ceil(begin / pitch))
        let lastLine = Int(floor(end / pitch))
        guard firstLine <= lastLine else { return [] }
        var strokes: [Stroke] = []
        for line in firstLine...lastLine {
            let offset = Double(line) * pitch
            let levelIndex = ((line % levels.count) + levels.count) % levels.count
            let threshold = levels[levelIndex]
            let minimumX = slope == 1 ? max(left, top - offset)
                : slope == -1 ? max(left, offset - bottom) : left
            let maximumX = slope == 1 ? min(right, bottom - offset)
                : slope == -1 ? min(right, offset - top) : right
            guard maximumX >= minimumX else { continue }
            let count = Int(ceil(maximumX - minimumX))
            var first: CGPoint?
            var previous: CGPoint?
            for index in 0...count {
                let x = min(maximumX, minimumX + Double(index))
                let y = slope == 1 ? x + offset : slope == -1 ? offset - x : offset
                let point = CGPoint(x: x, y: y)
                if raster.darkness(at: point, multiplier: darkness) >= threshold {
                    if first == nil { first = point }
                    previous = point
                } else {
                    appendHatch(from: first, to: previous, line: line, lineWidth: lineWidth, strokes: &strokes)
                    first = nil
                    previous = nil
                }
            }
            appendHatch(from: first, to: previous, line: line, lineWidth: lineWidth, strokes: &strokes)
        }
        return strokes
    }

    private static func appendHatch(from first: CGPoint?, to last: CGPoint?, line: Int,
                                    lineWidth: Double, strokes: inout [Stroke]) {
        guard let first, let last,
              hypot(Double(last.x - first.x), Double(last.y - first.y)) >= max(2.5, lineWidth) else { return }
        let points = [first, last]
        strokes.append(Stroke(points: line.isMultiple(of: 2) ? points : points.reversed()))
    }

    private static func outlineStrokes(raster: Raster, darkness: Double,
                                      lineWidth: Double, inkArtwork: Bool = false,
                                      minimumLength: Double? = nil,
                                      tolerance: Double? = nil) -> [Stroke] {
        let width = raster.width
        let height = raster.height
        let inset = max(1, Int(ceil(raster.margin)))
        guard width > inset * 2 + 2, height > inset * 2 + 2 else { return [] }
        var mask = inkArtwork ? inkMask(raster: raster, darkness: darkness, inset: inset)
            : edgeMask(raster: raster, darkness: darkness, inset: inset)
        thin(mask: &mask, width: width, height: height, inset: inset)
        if inkArtwork {
            let fitter = BezierFitter()
            let raw = SkeletonTracing.polylines(mask: mask, width: width, height: height).map { Stroke(points: $0) }
            let joined = joinInkChains(raw, adjacency: skeletonAdjacency(mask: mask, width: width, height: height),
                                       width: width, maximumGap: 8)
            return joined.compactMap { stroke in
                let points = stroke.points
                let length = zip(points, points.dropFirst()).reduce(0.0) {
                    $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
                }
                guard length >= (minimumLength ?? max(1.5, lineWidth)) else { return nil }
                let smooth = fitter.smooth(points)
                return Stroke(points: simplify(smooth, tolerance: min(0.18, tolerance ?? 0.18)))
            }
        }
        return trace(mask: mask, width: width, height: height,
                     minimumLength: minimumLength ?? max(1.5, lineWidth),
                     tolerance: tolerance ?? max(0.4, lineWidth * 0.2))
    }

    private static func inkMask(raster: Raster, darkness: Double, inset: Int,
                                thresholdOffset: Double = 0) -> [Bool] {
        let width = raster.width, height = raster.height
        // Light smoothing suppresses antialias/compression fringes before
        // adaptive paper/ink separation. A weak 3-gray-level hysteresis made
        // those fringes into wide ragged bands and hence false skeleton spurs.
        var values = raster.values.map(Double.init)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                values[i] = (Double(raster.values[i]) * 4
                    + Double(Int(raster.values[i - 1]) + Int(raster.values[i + 1])
                             + Int(raster.values[i - width]) + Int(raster.values[i + width])) * 2
                    + Double(Int(raster.values[i - width - 1]) + Int(raster.values[i - width + 1])
                             + Int(raster.values[i + width - 1]) + Int(raster.values[i + width + 1]))) / 16
            }
        }
        var histogram = [Int](repeating: 0, count: 256)
        for y in inset..<(height - inset) {
            for x in inset..<(width - inset) { histogram[Int(values[y * width + x].rounded())] += 1 }
        }
        let paper = (220...255).max { histogram[$0] < histogram[$1] } ?? 255
        let total = Double(histogram.reduce(0, +))
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var weight = 0.0, inkSum = 0.0, bestVariance = 0.0
        var cutoff = 0
        for value in 0..<255 {
            weight += Double(histogram[value]); inkSum += Double(value * histogram[value])
            guard weight > 0, weight < total else { continue }
            let difference = inkSum / weight - (sum - inkSum) / (total - weight)
            let variance = weight * (total - weight) * difference * difference
            if variance > bestVariance { bestVariance = variance; cutoff = value }
        }
        guard bestVariance > 0 else { return [Bool](repeating: false, count: raster.values.count) }
        // Otsu adapts to pale ink as well as black ink; do not hard-code a
        // black-only threshold that would silently discard gray line drawings.
        let adaptiveThreshold = Double(paper) - (Double(paper) - Double(cutoff)) / max(0.05, darkness)
        // A negative detail setting may discard gray ink, but must not make
        // even pure black ineligible. Preserve the original default exactly.
        let adjustedThreshold = thresholdOffset == 0 ? adaptiveThreshold
            : max(0, adaptiveThreshold + thresholdOffset)
        let threshold = min(Double(paper) - 2, adjustedThreshold)
        var mask = [Bool](repeating: false, count: raster.values.count)
        for y in inset..<(height - inset) {
            for x in inset..<(width - inset) {
                let i = y * width + x
                mask[i] = values[i] <= threshold
            }
        }
        return mask
    }

    private static func edgeMask(raster: Raster, darkness: Double, inset: Int) -> [Bool] {
        let width = raster.width, height = raster.height, count = width * height
        let edgeInset = inset + 2
        guard width > edgeInset * 2, height > edgeInset * 2 else {
            return [Bool](repeating: false, count: count)
        }
        var smooth = [Double](repeating: 1, count: count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let value = Double(raster.values[index]) * 4
                    + Double(raster.values[index - 1]) * 2
                    + Double(raster.values[index + 1]) * 2
                    + Double(raster.values[index - width]) * 2
                    + Double(raster.values[index + width]) * 2
                    + Double(raster.values[index - width - 1])
                    + Double(raster.values[index - width + 1])
                    + Double(raster.values[index + width - 1])
                    + Double(raster.values[index + width + 1])
                smooth[index] = value / (16 * 255)
            }
        }
        var magnitudes = [Double](repeating: 0, count: count)
        var orientations = [UInt8](repeating: 0, count: count)
        for y in edgeInset..<(height - edgeInset) {
            for x in edgeInset..<(width - edgeInset) {
                let i = y * width + x
                let gx = -smooth[i - width - 1] - 2 * smooth[i - 1] - smooth[i + width - 1]
                    + smooth[i - width + 1] + 2 * smooth[i + 1] + smooth[i + width + 1]
                let gy = -smooth[i - width - 1] - 2 * smooth[i - width] - smooth[i - width + 1]
                    + smooth[i + width - 1] + 2 * smooth[i + width] + smooth[i + width + 1]
                let magnitude = hypot(gx, gy)
                magnitudes[i] = magnitude
                let angle = (atan2(gy, gx) * 180 / .pi + 180).truncatingRemainder(dividingBy: 180)
                orientations[i] = angle < 22.5 || angle >= 157.5 ? 0
                    : angle < 67.5 ? 1 : angle < 112.5 ? 2 : 3
            }
        }
        // Canny 的非极大值抑制先去掉宽边缘带，不能用宽 Sobel 区域骨架猜测轮廓。
        var suppressed = [Double](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 1024)
        var positive = 0
        for y in edgeInset..<(height - edgeInset) {
            for x in edgeInset..<(width - edgeInset) {
                let i = y * width + x
                let offset: Int
                switch orientations[i] {
                case 0: offset = 1
                case 1: offset = width + 1
                case 2: offset = width
                default: offset = width - 1
                }
                let value = magnitudes[i]
                if value >= magnitudes[i - offset] && value >= magnitudes[i + offset] {
                    suppressed[i] = value
                    if value >= 0.01 {
                        histogram[min(1023, Int(value * 256))] += 1
                        positive += 1
                    }
                }
            }
        }
        var accumulated = 0
        var percentile = 0.1
        for bin in histogram.indices {
            accumulated += histogram[bin]
            if accumulated >= max(1, Int(Double(positive) * 0.85)) {
                percentile = Double(bin) / 256
                break
            }
        }
        let high = max(0.10, min(0.7, percentile * 0.5)) / max(0.05, darkness)
        let low = high * 0.4
        var weak = [Bool](repeating: false, count: count)
        var mask = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for index in suppressed.indices {
            weak[index] = suppressed[index] >= low
            if suppressed[index] >= high { mask[index] = true; stack.append(index) }
        }
        connectWeakEdges(mask: &mask, weak: weak, stack: &stack,
                         width: width, height: height, inset: inset)
        return mask
    }

    private static func connectWeakEdges(mask: inout [Bool], weak: [Bool], stack: inout [Int],
                                          width: Int, height: Int, inset: Int) {
        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx
                    let ny = y + dy
                    if nx < inset || nx >= width - inset || ny < inset || ny >= height - inset { continue }
                    let neighbor = ny * width + nx
                    if weak[neighbor] && !mask[neighbor] {
                        mask[neighbor] = true
                        stack.append(neighbor)
                    }
                }
            }
        }
    }

    /// Zhang–Suen 骨架化，把宽边缘收敛成可连续拖动的一条线。
    private static func thin(mask: inout [Bool], width: Int, height: Int, inset: Int) {
        for _ in 0..<48 {
            var changed = false
            for phase in 0..<2 {
                var removed: [Int] = []
                for y in inset..<(height - inset) {
                    for x in inset..<(width - inset) {
                        let i = y * width + x
                        if !mask[i] { continue }
                        let neighbors = [mask[i - width], mask[i - width + 1], mask[i + 1],
                                         mask[i + width + 1], mask[i + width], mask[i + width - 1],
                                         mask[i - 1], mask[i - width - 1]]
                        let count = neighbors.reduce(0) { $0 + ($1 ? 1 : 0) }
                        if count < 2 || count > 6 { continue }
                        var transitions = 0
                        for index in 0..<8 where !neighbors[index] && neighbors[(index + 1) % 8] {
                            transitions += 1
                        }
                        if transitions != 1 { continue }
                        let first: Bool
                        let second: Bool
                        if phase == 0 {
                            first = neighbors[0] && neighbors[2] && neighbors[4]
                            second = neighbors[2] && neighbors[4] && neighbors[6]
                        } else {
                            first = neighbors[0] && neighbors[2] && neighbors[6]
                            second = neighbors[0] && neighbors[4] && neighbors[6]
                        }
                        if !first && !second { removed.append(i) }
                    }
                }
                if !removed.isEmpty { changed = true }
                for index in removed { mask[index] = false }
            }
            if !changed { return }
        }
    }

    private static let directions: [(Int, Int)] = [
        (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)
    ]

    private static func skeletonAdjacency(mask: [Bool], width: Int, height: Int) -> [UInt8] {
        var adjacency = [UInt8](repeating: 0, count: mask.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                if !mask[index] { continue }
                for (direction, delta) in directions.enumerated() {
                    let neighbor = (y + delta.1) * width + x + delta.0
                    if !mask[neighbor] { continue }
                    // 有正交连接时不额外连对角，避免台阶线被拆成大量三角形。
                    if delta.0 != 0 && delta.1 != 0,
                       mask[y * width + x + delta.0] || mask[(y + delta.1) * width + x] { continue }
                    adjacency[index] |= UInt8(1 << direction)
                }
            }
        }
        return adjacency
    }

    private static func trace(mask: [Bool], width: Int, height: Int,
                              minimumLength: Double, tolerance: Double) -> [Stroke] {
        let adjacency = skeletonAdjacency(mask: mask, width: width, height: height)
        var visited = [UInt8](repeating: 0, count: mask.count)
        var strokes: [Stroke] = []
        func follow(from start: Int, direction initialDirection: Int) {
            var index = start
            var direction = initialDirection
            var points = [CGPoint(x: start % width, y: start / width)]
            for _ in 0..<(mask.count * 4) {
                let bit = UInt8(1 << direction)
                if visited[index] & bit != 0 { break }
                visited[index] |= bit
                let delta = directions[direction]
                let next = index + delta.1 * width + delta.0
                visited[next] |= UInt8(1 << ((direction + 4) % 8))
                points.append(CGPoint(x: next % width, y: next / width))
                index = next
                let unused = adjacency[index] & ~visited[index]
                if unused == 0 { break }
                // 穿过交汇点时沿最平顺的未访问方向继续，剩余分支另起一笔。
                // 旧实现把每个交汇点当终点，细密墨线会被切成大量极短碎片。
                let previousPoint = points[max(0, points.count - 7)]
                let incomingX = Double(points.last!.x - previousPoint.x)
                let incomingY = Double(points.last!.y - previousPoint.y)
                var bestDirection = unused.trailingZeroBitCount
                var bestAlignment = -Double.infinity
                for candidate in 0..<8 where unused & UInt8(1 << candidate) != 0 {
                    // 用数个像素的走向判断延续，避免骨架交汇处的一像素台阶
                    // 把大曲线误导进细小的回环或支线。
                    var probe = index
                    var probeDirection = candidate
                    for _ in 0..<6 {
                        let delta = directions[probeDirection]
                        probe += delta.1 * width + delta.0
                        let choices = adjacency[probe] & ~UInt8(1 << ((probeDirection + 4) % 8))
                        if choices == 0 { break }
                        if choices.nonzeroBitCount == 1 { probeDirection = choices.trailingZeroBitCount }
                        else { break }
                    }
                    let outgoingX = Double(probe % width - index % width)
                    let outgoingY = Double(probe / width - index / width)
                    let denominator = hypot(incomingX, incomingY) * hypot(outgoingX, outgoingY)
                    let alignment = denominator > 0
                        ? (incomingX * outgoingX + incomingY * outgoingY) / denominator : -1
                    if alignment > bestAlignment { bestAlignment = alignment; bestDirection = candidate }
                }
                direction = bestDirection
            }
            let length = zip(points, points.dropFirst()).reduce(0.0) { result, pair in
                result + hypot(Double(pair.1.x - pair.0.x), Double(pair.1.y - pair.0.y))
            }
            if length > 0 {
                let centered = points.map { CGPoint(x: $0.x + 0.5, y: $0.y + 0.5) }
                strokes.append(Stroke(points: simplify(centered, tolerance: tolerance)))
            }
        }
        // 优先端点，令长线穿过交叉口；然后补交汇点余支与封闭轮廓。
        for index in mask.indices where mask[index] && adjacency[index].nonzeroBitCount == 1 {
            for direction in 0..<8 where adjacency[index] & UInt8(1 << direction) != 0 {
                if visited[index] & UInt8(1 << direction) == 0 { follow(from: index, direction: direction) }
            }
        }
        for index in mask.indices where mask[index] {
            let unused = adjacency[index] & ~visited[index]
            if unused != 0 { follow(from: index, direction: unused.trailingZeroBitCount) }
        }
        // 一些已访问的交汇边会把剩余墨线切成很短的边；在同一墨线图中把
        // 端点重新接成平顺的链，不能先用最小拖动长度把这些边逐条过滤掉。
        return joinInkChains(strokes, adjacency: adjacency, width: width).compactMap { stroke in
            let length = zip(stroke.points, stroke.points.dropFirst()).reduce(0.0) {
                $0 + hypot(Double($1.1.x - $1.0.x), Double($1.1.y - $1.0.y))
            }
            return length >= minimumLength
                ? Stroke(points: simplify(stroke.points, tolerance: tolerance)) : nil
        }
    }

    private static func joinInkChains(_ strokes: [Stroke], adjacency: [UInt8], width: Int,
                                      maximumGap: Int = 2) -> [Stroke] {
        struct End { let stroke: Int; let reversed: Bool }
        func pixel(_ p: CGPoint) -> Int { Int(p.y - 0.5) * width + Int(p.x - 0.5) }
        var ends: [Int: [End]] = [:]
        for (i, stroke) in strokes.enumerated() where stroke.points.count >= 2 {
            ends[pixel(stroke.points.first!), default: []].append(End(stroke: i, reversed: false))
            ends[pixel(stroke.points.last!), default: []].append(End(stroke: i, reversed: true))
        }
        func bridge(_ first: Int, _ last: Int) -> [CGPoint]? {
            if first == last { return [] }
            var queue = [first]
            var parents = [first: -1]
            var depths = [first: 0]
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                if depths[index]! >= max(3, maximumGap * 2) { continue }
                for direction in 0..<8 where adjacency[index] & UInt8(1 << direction) != 0 {
                    let delta = directions[direction]
                    let next = index + delta.1 * width + delta.0
                    if parents[next] != nil { continue }
                    parents[next] = index
                    depths[next] = depths[index]! + 1
                    if next == last {
                        var chain: [CGPoint] = []
                        var current = next
                        while current != first {
                            chain.append(CGPoint(x: Double(current % width) + 0.5,
                                                 y: Double(current / width) + 0.5))
                            current = parents[current]!
                        }
                        return chain.reversed()
                    }
                    queue.append(next)
                }
            }
            return nil
        }
        let order = strokes.indices.sorted {
            strokes[$0].points.count > strokes[$1].points.count
        }
        var used = [Bool](repeating: false, count: strokes.count)
        var output: [Stroke] = []
        for initial in order where !used[initial] {
            used[initial] = true
            var points = strokes[initial].points
            for _ in 0..<2 {
                while points.count >= 2 {
                    let last = points.last!
                    let incoming = CGPoint(x: last.x - points[max(0, points.count - 5)].x,
                                            y: last.y - points[max(0, points.count - 5)].y)
                    let endpoint = pixel(last), x = endpoint % width, y = endpoint / width
                    var best: End?
                    var bestBridge: [CGPoint] = []
                    var score = 0.45
                    for dy in -maximumGap...maximumGap {
                        for dx in -maximumGap...maximumGap {
                            guard x + dx >= 0, x + dx < width,
                                  y + dy >= 0, y + dy < adjacency.count / width else { continue }
                            let candidatePixel = (y + dy) * width + x + dx
                            guard candidatePixel >= 0, candidatePixel < adjacency.count,
                                  let candidates = ends[candidatePixel] else { continue }
                            for end in candidates where !used[end.stroke] {
                                let source = strokes[end.stroke].points
                                let a = end.reversed ? source.last! : source.first!
                                let b = end.reversed ? source[max(0, source.count - 5)]
                                    : source[min(source.count - 1, 4)]
                                let outgoing = CGPoint(x: b.x - a.x, y: b.y - a.y)
                                let denominator = hypot(incoming.x, incoming.y) * hypot(outgoing.x, outgoing.y)
                                guard denominator > 0 else { continue }
                                let alignment = (incoming.x * outgoing.x + incoming.y * outgoing.y) / denominator
                                    - hypot(Double(dx), Double(dy)) * 0.03
                                guard alignment > score, let connection = bridge(endpoint, candidatePixel) else { continue }
                                score = alignment
                                best = end
                                bestBridge = connection
                            }
                        }
                    }
                    guard let next = best else { break }
                    used[next.stroke] = true
                    points.append(contentsOf: bestBridge)
                    let more = next.reversed ? Array(strokes[next.stroke].points.reversed())
                        : strokes[next.stroke].points
                    points.append(contentsOf: more.dropFirst())
                }
                points.reverse()
            }
            output.append(Stroke(points: points))
        }
        return output
    }

    /// 迭代版 Douglas–Peucker，保留转折和闭合轮廓，避免长路径递归耗尽栈。
    private static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var pending = [(0, points.count - 1)]
        let toleranceSquared = tolerance * tolerance
        while let (first, last) = pending.popLast() {
            if last <= first + 1 { continue }
            let a = points[first]
            let b = points[last]
            let dx = Double(b.x - a.x)
            let dy = Double(b.y - a.y)
            let segmentLength = dx * dx + dy * dy
            var farthest = first
            var maximumDistance = toleranceSquared
            for index in (first + 1)..<last {
                let px = Double(points[index].x - a.x)
                let py = Double(points[index].y - a.y)
                let fraction = segmentLength > 0 ? min(1, max(0, (px * dx + py * dy) / segmentLength)) : 0
                let ex = px - fraction * dx
                let ey = py - fraction * dy
                let distance = ex * ex + ey * ey
                if distance > maximumDistance {
                    maximumDistance = distance
                    farthest = index
                }
            }
            if farthest != first {
                keep[farthest] = true
                pending.append((first, farthest))
                pending.append((farthest, last))
            }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }
}
