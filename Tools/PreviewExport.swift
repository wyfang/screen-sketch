import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct PreviewExport {
    private enum ExportError: LocalizedError {
        case arguments
        case context
        case encoding(URL)

        var errorDescription: String? {
            switch self {
            case .arguments: return "用法：PreviewExport 图片路径 输出目录 [细节 32–640，默认 280] [工作笔宽 正数，默认 1.1]"
            case .context: return "无法创建对比图画布。"
            case .encoding(let url): return "无法保存 PNG：\(url.path)"
            }
        }
    }

    static func main() {
        do { try run() }
        catch {
            fputs("\(error.localizedDescription)\n", stderr)
            if case ExportError.arguments = error { exit(64) }
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { throw ExportError.arguments }
        let inputURL = URL(fileURLWithPath: arguments[1])
        let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard arguments.count <= 5,
              let detail = arguments.count > 3 ? Int(arguments[3]) : 280,
              let lineWidth = arguments.count > 4 ? Double(arguments[4]) : 1.1,
              (32...640).contains(detail), lineWidth.isFinite, lineWidth > 0 else {
            throw ExportError.arguments
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let image = try ImageProcessor.loadImage(url: inputURL)
        let settings = ProcessingSettings(maxDimension: detail, darkness: 1, lineWidth: lineWidth,
                                          canvasAspect: Double(image.width) / Double(image.height))
        var plans: [DrawingPlan] = []
        for mode in DrawingMode.allCases {
            let plan = try ImageProcessor.makePlan(image: image, mode: mode, settings: settings)
            plans.append(plan)
            let url = outputURL.appendingPathComponent("\(mode.title).png")
            try savePNG(plan.preview, to: url)
            print("\(mode.title): \(Int(plan.size.width)) × \(Int(plan.size.height)), \(plan.strokes.count) 笔, \(plan.pointCount) 坐标 → \(url.path)")
        }
        let comparison = try makeComparison(original: image, plans: plans,
                                            fileName: inputURL.lastPathComponent,
                                            detail: detail, lineWidth: lineWidth)
        let comparisonURL = outputURL.appendingPathComponent("绘图模式对比.png")
        try savePNG(comparison, to: comparisonURL)
        print("对比图 → \(comparisonURL.path)")
    }

    private static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encoding(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encoding(url) }
    }

    private static func makeComparison(original: CGImage, plans: [DrawingPlan],
                                       fileName: String, detail: Int, lineWidth: Double) throws -> CGImage {
        let aspect = Double(original.width) / Double(original.height)
        let panelWidth = 720.0
        let imageHeight = min(630.0, panelWidth / aspect)
        let cardHeight = imageHeight + 86
        let gutter = 24.0
        let outer = 36.0
        let headerHeight = 112.0
        let width = Int(outer * 2 + panelWidth * 2 + gutter)
        let rows = (plans.count + 2) / 2
        let height = Int(headerHeight + outer + cardHeight * Double(rows) + gutter * Double(max(0, rows - 1)) + 50)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.context
        }
        context.setFillColor(CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let titleFont = NSFont(name: "PingFangSC-Semibold", size: 30) ?? .boldSystemFont(ofSize: 30)
        let headingFont = NSFont(name: "PingFangSC-Semibold", size: 23) ?? .boldSystemFont(ofSize: 23)
        let bodyFont = NSFont(name: "PingFangSC-Regular", size: 15) ?? .systemFont(ofSize: 15)
        let dark = NSColor(calibratedWhite: 0.12, alpha: 1)
        let secondary = NSColor(calibratedWhite: 0.40, alpha: 1)

        drawText("同一张照片 · \(plans.count) 种自动绘图模式", at: CGPoint(x: outer, y: Double(height) - 55),
                 font: titleFont, color: dark)
        drawText("细节 \(detail) · 工作笔宽 \(String(format: "%.2f", lineWidth)) · 保持原图比例 · 预览由实际笔画绘制",
                 at: CGPoint(x: outer, y: Double(height) - 83), font: bodyFont, color: secondary)

        var panels: [(CGImage, String, String)] = [(original, "原图", "系统读取并校正方向后的照片")]
        panels += plans.map { ($0.preview, $0.mode.title, "\($0.strokes.count) 笔 · \($0.pointCount) 个坐标 · \(Int($0.size.width)) × \(Int($0.size.height))") }
        for (index, panel) in panels.enumerated() {
            let column = index % 2
            let row = index / 2
            let x = outer + Double(column) * (panelWidth + gutter)
            let y = Double(height) - headerHeight - Double(row + 1) * cardHeight - Double(row) * gutter
            let card = CGRect(x: x, y: y, width: panelWidth, height: cardHeight)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(card)
            drawText(panel.1, at: CGPoint(x: x + 20, y: y + cardHeight - 36), font: headingFont, color: dark)
            drawText(panel.2, at: CGPoint(x: x + 20, y: y + cardHeight - 62), font: bodyFont, color: secondary)
            let available = CGRect(x: x + 12, y: y + 12, width: panelWidth - 24, height: imageHeight - 12)
            let scale = min(available.width / CGFloat(panel.0.width), available.height / CGFloat(panel.0.height))
            let fitted = CGSize(width: CGFloat(panel.0.width) * scale, height: CGFloat(panel.0.height) * scale)
            let rect = CGRect(x: available.midX - fitted.width / 2, y: available.midY - fitted.height / 2,
                              width: fitted.width, height: fitted.height)
            context.interpolationQuality = .high
            context.draw(panel.0, in: rect)
        }
        drawText("\(fileName) · 目标画板的实际笔刷形状和速度会影响最终效果", at: CGPoint(x: outer, y: 28),
                 font: bodyFont, color: secondary)
        guard let image = context.makeImage() else { throw ExportError.context }
        return image
    }

    private static func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
