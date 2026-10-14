import AppKit
import CoreGraphics
import Foundation
import ImageIO

@main
struct ProcessorPhysicalChecks {
    enum Failure: Error { case check(String) }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }
    static func image(width: Int = 320, height: Int = 200, gray: Double? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: gray ?? 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if gray == nil {
            context.setFillColor(gray: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: Double(width) * 0.12, y: Double(height) * 0.17,
                                           width: Double(width) * 0.3, height: Double(height) * 0.6))
            context.setFillColor(gray: 0.35, alpha: 1)
            context.fill(CGRect(x: Double(width) * 0.62, y: Double(height) * 0.12,
                                width: Double(width) * 0.28, height: Double(height) * 0.75))
        }
        return context.makeImage()!
    }
    static func values(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height))
    }
    static func centralInk(_ image: CGImage) -> Double {
        let pixels = values(image)
        let minX = image.width / 5, maxX = image.width * 4 / 5
        let minY = image.height / 5, maxY = image.height * 4 / 5
        var sum = 0.0
        for y in minY..<maxY {
            for x in minX..<maxX { sum += 1 - Double(pixels[y * image.width + x]) / 255 }
        }
        return sum / Double((maxX - minX) * (maxY - minY))
    }
    static func validatePath(_ plan: DrawingPlan) throws {
        let margin = max(1, plan.lineWidth / 2 + 1)
        for stroke in plan.strokes {
            try require(stroke.points.count >= 2, "实际路径至少有两点")
            for p in stroke.points {
                try require(p.x >= margin && p.y >= margin && p.x <= plan.size.width - margin && p.y <= plan.size.height - margin,
                            "路径必须位于引擎实际安全区内，预览不能比绘制多出边缘")
            }
            let length = zip(stroke.points, stroke.points.dropFirst()).reduce(0.0) {
                $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
            }
            try require(length + 0.000001 >= plan.minimumMovement,
                        "独立落笔须达到实测可见长度；连续笔迹保留较短拐角")
        }
    }
    static func validateSingleRows(_ plan: DrawingPlan, settings: ProcessingSettings) throws {
        for stroke in plan.strokes {
            try require(stroke.points.count == 2, "每个网点只执行一条短线，不能用折返填块")
            let a = stroke.points[0], b = stroke.points[1]
            try require(abs(a.y - b.y) < 1e-8 || abs(a.x - b.x) < 1e-8,
                        "单笔网点只能为一条水平或纵向直线，不能用折返填块")
            try require(hypot(a.x - b.x, a.y - b.y) + 1e-8 >= settings.minimumMovement,
                        "每一笔仍须达到最小可执行移动长度")
        }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let source = image()
        var physical = ProcessingSettings(maxDimension: 32, darkness: 1, lineWidth: 1.2,
                                           canvasAspect: 9, minimumMovement: 3,
                                           canvasSize: CGSize(width: 320, height: 200), backingScale: 2,
                                           minimumSpacingX: 4.8, minimumSpacingY: 6)
        for mode in DrawingMode.allCases {
            let plan = try ImageProcessor.makePlan(image: source, mode: mode, settings: physical)
            try require(plan.size == physical.canvasSize!, "计划须保留实际屏幕点画布，不受细节/比例参数控制")
            try require(plan.preview.width == 640 && plan.preview.height == 400, "Retina 预览须使用实际 backing pixels")
            try require(plan.lineWidth == physical.lineWidth && plan.minimumMovement == physical.minimumMovement,
                        "屏幕点笔宽和移动长度不能跟采样一起缩小")
            if mode == .halftone {
                try require(plan.effectiveSpacingX < physical.minimumMovement && plan.effectiveSpacingY <= physical.lineWidth * 1.01,
                            "采样是观察原图的位置，不得将最小移动距离误作像素精度")
                try validateSingleRows(plan, settings: physical)
            } else {
                try require(plan.sampleSize.width >= 180 && plan.sampleSize.height >= 120,
                            "连续轮廓使用独立提线采样，不按网点中心距粗化原图")
            }
            try require(!plan.strokes.isEmpty, "样图应在各模式生成可执行笔画")
            try validatePath(plan)
            var detail = physical
            detail.maxDimension = 640
            detail.canvasAspect = 0.2
            let again = try ImageProcessor.makePlan(image: source, mode: mode, settings: detail)
            try require(plan.strokes.map(\.points) == again.strokes.map(\.points), "任意细节拉杆不能影响物理计划")
            print("PASS physical \(mode.rawValue) \(plan.sampleSize) strokes=\(plan.strokes.count)")
        }
        let original = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: physical)
        physical.minimumSpacingX = 14
        physical.minimumSpacingY = 20
        let coarse = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: physical)
        try require(coarse.sampleSize == original.sampleSize && coarse.strokes.map(\.points) == original.strokes.map(\.points),
                    "区分独立线条的中心距不限制可连接的深色区域，不能粗化照片源采样")
        physical.minimumSpacingX = 4.8
        physical.minimumSpacingY = 6
        var oneX = physical
        oneX.backingScale = 1
        let standard = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: oneX)
        try require(standard.strokes.map(\.points) == original.strokes.map(\.points), "Retina 不能改变相同校准值的鼠标坐标")
        try require(standard.preview.width == 320 && standard.preview.height == 200, "普通屏幕应输出一倍预览")

        for brush in [0.25, 1.2, 3.5] {
            var settings = physical
            settings.lineWidth = brush
            let black = try ImageProcessor.makePlan(image: image(gray: 0), mode: .halftone, settings: settings)
            let blackInk = centralInk(black.preview)
            try require(blackInk > 0.94,
                        "连续纯黑区允许实际笔宽的相邻单笔连接，预览须保留深黑覆盖")
            for (gray, label) in [(0.0, "black"), (0.5, "gray"), (1.0, "white")] {
                let plan = try ImageProcessor.makePlan(image: image(gray: gray), mode: .halftone, settings: settings)
                try validatePath(plan)
                try validateSingleRows(plan, settings: settings)
                let ink = centralInk(plan.preview)
                if gray == 0 { try require(ink > 0.94, "纯黑区域不能因独立线条间距而被稀释成浅灰") }
                // 独立读取实际预览的墨量，不用笔画数或采样格数冒充灰度。
                if gray == 0.5 {
                    try require(ink > 0.43 && ink < 0.57,
                                "高密度中灰须保留约一半实际墨量，每个连续墨迹仍只画一笔")
                }
                if gray == 1 { try require(plan.strokes.isEmpty && ink == 0, "纯白不落笔") }
                print(String(format: "PASS physical single-line pen=%.2f %@ ink=%.4f", brush, label, ink))
            }
        }
        let gapContext = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8,
                                   bytesPerRow: 320, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gapContext.setFillColor(gray: 1, alpha: 1)
        gapContext.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        gapContext.setFillColor(gray: 0, alpha: 1)
        gapContext.fill(CGRect(x: 0, y: 0, width: 90, height: 200))
        gapContext.fill(CGRect(x: 230, y: 0, width: 90, height: 200))
        let separated = try ImageProcessor.makePlan(image: gapContext.makeImage()!, mode: .halftone, settings: physical)
        for stroke in separated.strokes {
            try require(!(stroke.points.map(\.x).min()! < 120 && stroke.points.map(\.x).max()! > 200),
                        "不能通过补足最小移动跨过白色区域")
        }

        // 先在屏幕点适配，异向网格只能改变精度，不能改变原图比例。
        let square = image(width: 100, height: 100, gray: 0)
        var anisotropic = physical
        anisotropic.minimumSpacingX = 20
        anisotropic.minimumSpacingY = 4
        let fitted = try ImageProcessor.makePlan(image: square, mode: .halftone, settings: anisotropic)
        let minX = fitted.strokes.flatMap(\.points).map(\.x).min()! - fitted.lineWidth / 2
        let maxX = fitted.strokes.flatMap(\.points).map(\.x).max()! + fitted.lineWidth / 2
        let fittedMargin = max(1, anisotropic.lineWidth / 2 + 1)
        try require(abs((maxX - minX) - (200 - fittedMargin * 2)) < fitted.effectiveSpacingX * 3,
                    "方图适配应保持屏幕点中的方形，不可被网格宽高比拉伸")

        // 一张很小的源图也可直接放大到物理画布；分辨率不以源文件尺寸限死。
        let small = try ImageProcessor.makePlan(image: image(width: 8, height: 5, gray: 0), mode: .halftone, settings: physical)
        try require(small.sampleSize.width > 8 && !small.strokes.isEmpty, "小图片放大仍需遵守物理画布和单笔网点")
        try validateSingleRows(small, settings: physical)
        var budget = physical
        budget.canvasSize = CGSize(width: 2200, height: 1400)
        budget.lineWidth = 0.6
        budget.minimumMovement = 1
        budget.minimumSpacingX = 1.7
        budget.minimumSpacingY = 1.4
        let bounded = try ImageProcessor.makePlan(image: image(width: 1100, height: 700, gray: 0.5), mode: .halftone, settings: budget)
        try require(bounded.resolutionNote != nil, "降级必须向用户说明")
        try require(bounded.size == budget.canvasSize! && bounded.lineWidth == budget.lineWidth,
                    "路径降级不能偷偷缩小屏幕点空间或笔宽")
        try require(bounded.strokes.count <= 36_000 && bounded.pointCount <= 240_000, "返回完整预算内的路径")
        let middleY = bounded.strokes.flatMap(\.points).map(\.y)
        try require(middleY.min()! < 100 && middleY.max()! > 1300, "预算控制必须仍保留整幅图")
        let budgetInk = centralInk(bounded.preview)
        try require(budgetInk > 0.40 && budgetInk < 0.60, "整图采样降级后仍应保留实际灰度覆盖")
        let budgetMargin = max(1, budget.lineWidth / 2 + 1)
        let requestedRows = floor((budget.canvasSize!.height - budgetMargin * 2) / budget.lineWidth)
        try require(bounded.sampleSize.height == requestedRows,
                    "预算优先降低横向单元数量，仍可承载的校准行距不能被横向位移粗化")
        try validatePath(bounded)
        try validateSingleRows(bounded, settings: budget)
        print("PASS physical adaptive budget \(bounded.sampleSize) strokes=\(bounded.strokes.count)")

        var hugePreview = physical
        hugePreview.canvasSize = CGSize(width: 7000, height: 7000)
        hugePreview.minimumSpacingX = 30
        hugePreview.minimumSpacingY = 30
        let lowMemory = try ImageProcessor.makePlan(image: image(gray: 1), mode: .halftone, settings: hugePreview)
        try require(lowMemory.resolutionNote?.contains("预览位图") == true && lowMemory.preview.width <= 4096,
                    "极大位图应明确减少预览像素数，但不改变路径单位")
        for invalid in [Double.nan, Double.infinity, -1.0] {
            var settings = physical
            settings.minimumSpacingX = invalid
            do { _ = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: settings); throw Failure.check("无效间距应拒绝") }
            catch let error as Failure { throw error }
            catch { }
        }
        var ending = physical
        ending.endExtension = 8
        for mode in DrawingMode.allCases {
            let plan = try ImageProcessor.makePlan(image: source, mode: mode, settings: ending)
            let margin = max(1, ending.lineWidth / 2 + 1) + ending.endExtension
            let inner = CGRect(origin: .zero, size: plan.size).insetBy(dx: margin, dy: margin)
            try require(plan.strokes.flatMap(\.points).allSatisfy {
                $0.x >= inner.minX - 0.000_001 && $0.x <= inner.maxX + 0.000_001
                    && $0.y >= inner.minY - 0.000_001 && $0.y <= inner.maxY + 0.000_001
            }, "收笔额外行程在所有模式都有完整边距")
            try require(plan.resolutionNote?.contains("目标笔迹") == true, "补偿预览明确区分目标笔迹与额外鼠标行程")
        }
        for invalid in [Double.nan, Double.infinity, -1.0] {
            ending.endExtension = invalid
            do { _ = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: ending); throw Failure.check("无效末端补偿应拒绝") }
            catch let error as Failure { throw error }
            catch { }
        }
        var pathological = physical
        pathological.lineWidth = 1e-200
        let microscopic = try ImageProcessor.makePlan(image: image(gray: 0), mode: .halftone, settings: pathological)
        try require(microscopic.strokes.count <= 36_000 && microscopic.pointCount <= 240_000,
                    "极小笔宽没有填充子行，不能导致笔画或内存预算爆炸")
        try validatePath(microscopic)
        try validateSingleRows(microscopic, settings: pathological)
        print("PASS point/pixel separation / anisotropic spacing / fit / white isolation / memory budget / invalid settings")
        print("All physical processor checks passed.")
    }
}
