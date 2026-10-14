import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ProcessorChecks {
    private enum CheckError: Error { case failed(String) }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError.failed(message) }
    }

    static func makeImage(width: Int = 180, height: Int = 120, white: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        if !white {
            for y in 0..<height {
                for x in 0..<width {
                    var value = UInt8((Double(x) / Double(width - 1) * 255).rounded())
                    let dx = x - width / 3
                    let dy = y - height / 3
                    if dx * dx + dy * dy < (height / 5) * (height / 5) { value = 0 }
                    if x > width * 2 / 3 && y > height / 2 { value = 255 }
                    pixels[y * width + x] = value
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw CheckError.failed("不能构建测试图片") }
        return image
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw CheckError.failed("不能读取预览")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height))
    }

    static func main() throws {
        let input = try makeImage()
        let white = try makeImage(white: true)
        for mode in DrawingMode.allCases {
            for aspect in [0.65, 1.0, 1.8] {
                let settings = ProcessingSettings(maxDimension: 160, darkness: 1, lineWidth: 1.5, canvasAspect: aspect)
                let plan = try ImageProcessor.makePlan(image: input, mode: mode, settings: settings)
                try require(!plan.strokes.isEmpty, "\(mode.rawValue) 应生成笔画")
                try require(plan.pointCount > 1, "\(mode.rawValue) 应有可绘制的路径")
                try require(plan.preview.width == Int(plan.size.width) && plan.preview.height == Int(plan.size.height), "预览尺寸应与路径空间一致")
                try require(abs(Double(plan.size.width / plan.size.height) - aspect) < 0.02, "画布比例应被保留")
                for stroke in plan.strokes {
                    try require(stroke.points.count >= 2, "单个笔画至少有两个坐标")
                    for point in stroke.points {
                        let radius = plan.lineWidth / 2
                        try require(point.x.isFinite && point.y.isFinite, "路径坐标必须有限")
                        try require(point.x >= radius && point.y >= radius &&
                                    point.x <= plan.size.width - radius && point.y <= plan.size.height - radius,
                                    "整个笔画必须留在画布内")
                    }
                }
                let again = try ImageProcessor.makePlan(image: input, mode: mode, settings: settings)
                try require(plan.strokes.map(\.points) == again.strokes.map(\.points), "\(mode.rawValue) 处理应可重复")
                let rendered = try pixels(plan.preview)
                try require(rendered.contains { $0 < 64 }, "预览必须包含实际黑色笔画")
                let whitePlan = try ImageProcessor.makePlan(image: white, mode: mode, settings: settings)
                try require(whitePlan.strokes.isEmpty, "纯白图片不应生成笔画")
                let whitePixels = try pixels(whitePlan.preview)
                try require(whitePixels.allSatisfy { $0 == 255 }, "纯白预览应保持全白")
                print("PASS \(mode.rawValue) aspect=\(aspect) strokes=\(plan.strokes.count) points=\(plan.pointCount)")
            }
        }

        // 笔画预览来自真实路径：把描画路径上下翻转，应对应预览中的上下黑色分布。
        let upperDark = try makeUpperDarkImage()
        let plan = try ImageProcessor.makePlan(image: upperDark, mode: .halftone,
                                               settings: ProcessingSettings(maxDimension: 120))
        let preview = try pixels(plan.preview)
        let middle = preview.count / 2
        let upperInk = preview[..<middle].reduce(0) { $0 + (255 - Int($1)) }
        let lowerInk = preview[middle...].reduce(0) { $0 + (255 - Int($1)) }
        try require(upperInk > lowerInk * 3, "预览必须保持图片上下方向")

        // 细笔必须填满黑色采样单元，不能让纯黑原图因为子像素笔宽变成浅灰。
        let black = try makeSolidImage(gray: 0)
        for lineWidth in [0.15, 0.35, 0.5, 0.9, 1.1, 2.5] {
            let thinPlan = try ImageProcessor.makePlan(image: black, mode: .halftone,
                                                       settings: ProcessingSettings(maxDimension: 96, lineWidth: lineWidth))
            let values = try pixels(thinPlan.preview)
            var ink = 0.0
            for y in 8..<88 {
                for x in 8..<88 { ink += 1 - Double(values[y * 96 + x]) / 255 }
            }
            try require(ink / 6400 > 0.96, "细笔 \(lineWidth) 应保留纯黑区域的覆盖率")
            try require(thinPlan.strokes.count < 100, "子行应连续合并，避免按子行倍增落笔次数")
            for point in thinPlan.strokes.flatMap(\.points) {
                let radius = thinPlan.lineWidth / 2
                try require(point.x >= radius && point.y >= radius &&
                            point.x <= thinPlan.size.width - radius && point.y <= thinPlan.size.height - radius,
                            "细笔填充的子行和连接也必须留在画布内")
            }
            print("PASS thin brush \(lineWidth) black coverage=\(String(format: "%.3f", ink / 6400))")
        }

        // 高细节的均匀灰图会生成大量网点；降采样仍保留整幅图并保持屏幕笔宽。
        let gray = try makeSolidImage(gray: 0.5)
        let requested = ProcessingSettings(maxDimension: 480, darkness: 1, lineWidth: 0.5, canvasAspect: 1)
        let budgetPlan = try ImageProcessor.makePlan(image: gray, mode: .halftone, settings: requested)
        try require(budgetPlan.size.width < 480, "复杂网点应触发预算控制")
        try require(budgetPlan.strokes.count <= 36_000 && budgetPlan.pointCount <= 240_000, "完整计划应处于路径预算内")
        try require(abs(budgetPlan.lineWidth / Double(budgetPlan.size.width) - requested.lineWidth / 480) < 0.0000001,
                    "降采样应同比缩小工作笔宽，以保持映射到屏幕后的笔宽")
        let budgetValues = try pixels(budgetPlan.preview)
        let width = Int(budgetPlan.size.width)
        let height = Int(budgetPlan.size.height)
        let edge = max(4, width / 10)
        var grayInk = 0.0
        for y in edge..<(height - edge) {
            for x in edge..<(width - edge) { grayInk += 1 - Double(budgetValues[y * width + x]) / 255 }
        }
        grayInk /= Double((width - edge * 2) * (height - edge * 2))
        try require(grayInk > 0.42 && grayInk < 0.58, "降采样后整幅灰图仍应保留约一半黑色覆盖")
        print("PASS adaptive budget size=\(width) width=\(budgetPlan.lineWidth) ink=\(String(format: "%.3f", grayInk))")

        // 模拟画板丢弃短拖动：启用阈值后的照片笔画应全部保留，并保留黑、灰、白。
        for lineWidth in [0.35, 1.1] {
            let minimum = 2.4
            let shortLineSettings = ProcessingSettings(maxDimension: 128, darkness: 1, lineWidth: lineWidth,
                                                       canvasAspect: 1, minimumMovement: minimum)
            for (source, expected) in [(black, "black"), (gray, "gray"), (white, "white")] {
                let shortPlan = try ImageProcessor.makePlan(image: source, mode: .halftone, settings: shortLineSettings)
                for stroke in shortPlan.strokes {
                    try require(stroke.points.count == 2, "照片短线不能依靠微小竖向连接")
                    let length = hypot(Double(stroke.points[1].x - stroke.points[0].x),
                                       Double(stroke.points[1].y - stroke.points[0].y))
                    try require(length >= shortPlan.minimumMovement, "阈值过滤不应丢掉照片笔画")
                    for point in stroke.points {
                        let radius = shortPlan.lineWidth / 2
                        try require(point.x >= radius && point.y >= radius &&
                                    point.x <= shortPlan.size.width - radius && point.y <= shortPlan.size.height - radius,
                                    "可靠短线必须保留笔宽安全边距")
                    }
                }
                let coverage = try centralInk(shortPlan.preview)
                if expected == "white" {
                    try require(shortPlan.strokes.isEmpty && coverage == 0, "短线模式的白图应保持空白")
                } else if expected == "black" {
                    try require(coverage > 0.96, "短线模式应保留黑色覆盖")
                } else {
                    try require(coverage > 0.38 && coverage < 0.62, "短线半色调应保留中灰明暗")
                }
                print("PASS reliable short lines pen=\(lineWidth) \(expected) ink=\(String(format: "%.3f", coverage))")
            }
        }

        let mappedSettings = ProcessingSettings(maxDimension: 192, darkness: 1, lineWidth: 0.7,
                                                canvasAspect: 1.5, minimumMovement: 2.4)
        let mappedPlan = try ImageProcessor.makePlan(image: input, mode: .halftone, settings: mappedSettings)
        let target = CGRect(x: -400, y: 260, width: 960, height: 640)
        let threshold = mappedPlan.minimumMovement * Double(target.width / mappedPlan.size.width)
        let mappedPaths = mappedPlan.strokes.map { stroke in
            stroke.points.map { CGPoint(x: target.minX + $0.x * target.width / mappedPlan.size.width,
                                        y: target.minY + $0.y * target.height / mappedPlan.size.height) }
        }
        let retained = mappedPaths.filter { path in
            zip(path, path.dropFirst()).allSatisfy { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) >= threshold }
        }
        try require(!mappedPaths.isEmpty && retained.count == mappedPaths.count,
                    "映射到屏幕并按真实阈值过滤后，不应丢失照片笔画")
        try require(abs(threshold - 12) < 0.000001, "工作阈值应对应实际屏幕点")

        let shortBudgetSettings = ProcessingSettings(maxDimension: 480, darkness: 1, lineWidth: 0.5,
                                                     canvasAspect: 1, minimumMovement: 0.6)
        let shortBudget = try ImageProcessor.makePlan(image: gray, mode: .halftone, settings: shortBudgetSettings)
        try require(shortBudget.size.width < 480, "可靠短线的复杂图也应触发完整图预算控制")
        try require(shortBudget.strokes.count <= 36_000 && shortBudget.pointCount <= 240_000,
                    "可靠短线的完整路径应满足预算")
        try require(abs(shortBudget.minimumMovement / Double(shortBudget.size.width) - 0.6 / 480) < 0.0000001,
                    "降采样应同比缩放最小移动距离")
        try require(abs(shortBudget.lineWidth / Double(shortBudget.size.width) - 0.5 / 480) < 0.0000001,
                    "降采样应同时保留笔宽和最小移动的映射比例")
        for stroke in shortBudget.strokes {
            try require(hypot(stroke.points[1].x - stroke.points[0].x,
                              stroke.points[1].y - stroke.points[0].y) >= shortBudget.minimumMovement,
                        "降采样后短线仍应达到阈值")
        }
        print("PASS short-line screen mapping / budget size=\(Int(shortBudget.size.width)) minimum=\(shortBudget.minimumMovement)")

        let separated = try ImageProcessor.makePlan(image: makeSeparatedBlackImage(), mode: .halftone,
                                                    settings: ProcessingSettings(maxDimension: 128, lineWidth: 0.6,
                                                                                 minimumMovement: 3))
        for stroke in separated.strokes {
            let minimumX = stroke.points.map(\.x).min()!
            let maximumX = stroke.points.map(\.x).max()!
            try require(!(minimumX < separated.size.width * 0.4 && maximumX > separated.size.width * 0.6),
                        "黑色区域之间的白色间隔不能被盲目连接")
        }
        for mode in [DrawingMode.outline, .sketch] {
            let original = try ImageProcessor.makePlan(image: input, mode: mode, settings: ProcessingSettings(maxDimension: 128))
            let withMinimum = try ImageProcessor.makePlan(image: input, mode: mode,
                                                          settings: ProcessingSettings(maxDimension: 128, minimumMovement: 3))
            try require(original.strokes.map(\.points) == withMinimum.strokes.map(\.points),
                        "最小拖动阈值不能扩大线稿或素描轮廓")
        }
        let defaultPhoto = try ImageProcessor.makePlan(image: input, mode: .halftone, settings: ProcessingSettings(maxDimension: 128))
        let zeroPhoto = try ImageProcessor.makePlan(image: input, mode: .halftone,
                                                   settings: ProcessingSettings(maxDimension: 128, minimumMovement: 0))
        try require(defaultPhoto.strokes.map(\.points) == zeroPhoto.strokes.map(\.points), "阈值为零应保持现有照片行为")
        print("PASS white-gap isolation / unchanged outline and sketch / zero compatibility")

        // 写入临时 JPEG 验证 EXIF 旋转与调用者指定的解码预算，退出时删除。
        let temporaryRoot = ProcessInfo.processInfo.environment["SCREEN_SKETCH_TEST_TMP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = temporaryRoot.appendingPathComponent("ScreenSketch-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photoURL = directory.appendingPathComponent("orientation.jpg")
        let large = try makeImage(width: 2200, height: 1100, white: true)
        guard let destination = CGImageDestinationCreateWithURL(photoURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CheckError.failed("不能生成测试 JPEG")
        }
        CGImageDestinationAddImage(destination, large, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "JPEG 编码应成功")
        let loaded = try ImageProcessor.loadImage(url: photoURL, maxPixelSize: 1600)
        try require(loaded.height == 1600 && loaded.width == 800, "加载应缩小大图并处理 EXIF 旋转")
        let fullResolution = try ImageProcessor.loadImage(url: photoURL)
        try require(fullResolution.height == 2200 && fullResolution.width == 1100, "默认加载不应强制丢弃 1600 以上的细节")
        let bounded = try ImageProcessor.loadImage(url: photoURL, maxPixelSize: 256)
        try require(bounded.height == 256 && bounded.width == 128, "画布可指定更小的解码预算")
        print("PASS preview orientation / ImageIO EXIF orientation / caller-driven decoding budget")
        print("All processor checks passed.")
    }

    static func makeUpperDarkImage() throws -> CGImage {
        let width = 80
        let height = 80
        var values = [UInt8](repeating: 255, count: width * height)
        for index in 0..<(width * height / 3) { values[index] = 0 }
        let provider = CGDataProvider(data: Data(values) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func makeSolidImage(gray: Double) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8,
                                      bytesPerRow: 80, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw CheckError.failed("不能构建测试图片") }
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        return context.makeImage()!
    }

    static func centralInk(_ image: CGImage) throws -> Double {
        let values = try pixels(image)
        let edgeX = max(4, image.width / 8)
        let edgeY = max(4, image.height / 8)
        var ink = 0.0
        for y in edgeY..<(image.height - edgeY) {
            for x in edgeX..<(image.width - edgeX) { ink += 1 - Double(values[y * image.width + x]) / 255 }
        }
        return ink / Double((image.width - edgeX * 2) * (image.height - edgeY * 2))
    }

    static func makeSeparatedBlackImage() throws -> CGImage {
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8,
                                bytesPerRow: 80, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 80))
        context.fill(CGRect(x: 56, y: 0, width: 24, height: 80))
        return context.makeImage()!
    }
}
