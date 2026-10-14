import AppKit
import SwiftUI
import ImageIO

/// Off-screen QA of this application's views. Does not read the screen or send input.
@main @MainActor struct ViewRenderer {
    private static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "RenderViews", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG：\(path)"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "RenderViews", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法保存 PNG：\(path)"])
        }
    }

    static func main() {
        let arguments = CommandLine.arguments
        let modes = ["main", "tools", "calibration", "spacing", "unified", "unified-extension",
                     "testplan", "spacingplan", "spacingplan-y", "unifiedplan", "unifiedplan-extension"]
        guard (3...4).contains(arguments.count), modes.contains(arguments[1]) else {
            fputs("用法：RenderViews 模式 输出PNG路径 [输入图片路径]\n模式：\(modes.joined(separator: ", "))\n", stderr)
            exit(64)
        }
        if CommandLine.arguments[1].hasPrefix("unifiedplan") {
            let calibration = UnifiedCalibration()
            let area = CGSize(width: 300, height: 550)
            _ = calibration.setArea(CGRect(origin: .zero, size: area))
            if CommandLine.arguments[1].hasSuffix("extension") { _ = calibration.setEndingMode(.extension) }
            do {
                let round = try calibration.makeRound(brushWidth: 2.5, knownMovement: 3)
                let pixelWidth = Int(area.width * 2), pixelHeight = Int(area.height * 2)
                let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                context.translateBy(x: 0, y: CGFloat(pixelHeight)); context.scaleBy(x: 2, y: -2)
                context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(2.5); context.setLineCap(.round); context.setLineJoin(.round)
                for path in round.annotationPaths + round.actualTestPaths {
                    context.beginPath(); context.move(to: CGPoint(x: path[0].x * area.width, y: path[0].y * area.height))
                    for point in path.dropFirst() { context.addLine(to: CGPoint(x: point.x * area.width, y: point.y * area.height)) }
                    context.strokePath()
                }
                try writePNG(context.makeImage()!, to: arguments[2])
                return
            } catch { print(error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments[1] == "testplan" || CommandLine.arguments[1].hasPrefix("spacingplan") {
            let calibration = MovementCalibration()
            let spacing = SpacingCalibration()
            let area = CGSize(width: 540, height: 420)
            _ = calibration.setArea(CGRect(origin: .zero, size: area))
            _ = spacing.setArea(CGRect(origin: .zero, size: area))
            if CommandLine.arguments[1] == "spacingplan-y" { spacing.axis = .y }
            let context = CGContext(data: nil, width: 1080, height: 840, bitsPerComponent: 8, bytesPerRow: 1080, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 840))
            context.translateBy(x: 0, y: 840); context.scaleBy(x: 2, y: -2)
            context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(2.5); context.setLineCap(.round); context.setLineJoin(.round)
            let layoutWidth = 2.5
            let paths = CommandLine.arguments[1] == "testplan" ? calibration.numberedPaths(brushWidth: layoutWidth) : spacing.numberedPaths(brushWidth: layoutWidth, minimumMovement: 3)
            let footprint = CalibrationFootprint(paths: paths, area: CGRect(origin: .zero, size: area), brushWidth: 2.5, targetPID: 1)
            do { _ = try CalibrationCleanup.replay(footprint: footprint) }
            catch { print(error.localizedDescription); exit(1) }
            for path in paths {
                context.beginPath(); context.move(to: CGPoint(x: path[0].x * area.width, y: path[0].y * area.height))
                for point in path.dropFirst() { context.addLine(to: CGPoint(x: point.x * area.width, y: point.y * area.height)) }
                context.strokePath()
            }
            do { try writePNG(context.makeImage()!, to: arguments[2]) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "com.wangyifang.screensketch.renderer." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let model = AppModel(preferences: preferences, showsApplicationUI: false)
        if arguments.count > 3 {
            model.load(URL(fileURLWithPath: arguments[3]))
            if let error = model.error { fputs("\(error)\n", stderr); exit(1) }
        }
        model.region = CGRect(x: 100, y: 100, width: 800, height: 600)
        _ = model.setMinimumSpacing(3.5, axis: .x)
        _ = model.setMinimumSpacing(4, axis: .y)
        model.scheduleProcessing()
        let toolsView = CommandLine.arguments[1] == "tools"
        let calibrationView = CommandLine.arguments[1] == "calibration"
        let spacingView = CommandLine.arguments[1] == "spacing"
        let unifiedView = CommandLine.arguments[1].hasPrefix("unified")
        let size = toolsView ? NSSize(width: 560, height: 680) : (unifiedView ? NSSize(width: 1040, height: 850) : (calibrationView || spacingView ? NSSize(width: 740, height: 860) : NSSize(width: 1080, height: 790)))
        let window = NSWindow(contentRect: CGRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if toolsView { window.contentView = NSHostingView(rootView: ToolSettingsView(model: model)) }
        else if unifiedView {
            model.region = CGRect(x: 100, y: 100, width: 300, height: 550)
            model.targetName = "主画布示例"
            model.syncUnifiedCanvas()
            if CommandLine.arguments[1].hasSuffix("extension") { _ = model.unifiedCalibration.setEndingMode(.extension) }
            _ = try? model.unifiedCalibration.makeRound(brushWidth: model.brushWidth, knownMovement: model.minimumMovement)
            _ = model.unifiedCalibration.markDrawn()
            for metric in CalibrationMetric.allCases { _ = model.unifiedCalibration.select(metric: metric, index: 1) }
            window.contentView = NSHostingView(rootView: UnifiedCalibrationHostView(model: model))
        } else if calibrationView {
            _ = model.calibration.setArea(CGRect(x: 100, y: 100, width: 420, height: 260))
            _ = model.calibration.numberedPaths(brushWidth: model.brushWidth)
            _ = model.calibration.markDrawn()
            model.calibration.selectedRow = 2
            window.contentView = NSHostingView(rootView: CalibrationHostView(model: model))
        } else if spacingView {
            _ = model.spacingCalibration.setArea(CGRect(x: 100, y: 100, width: 540, height: 420))
            _ = model.spacingCalibration.numberedPaths(brushWidth: model.brushWidth, minimumMovement: model.minimumMovement)
            _ = model.spacingCalibration.markDrawn()
            model.spacingCalibration.selectedRow = 3
            window.contentView = NSHostingView(rootView: SpacingCalibrationHostView(model: model))
        } else { window.contentView = NSHostingView(rootView: ContentView(model: model)) }
        model.mainWindow = window
        window.orderFront(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        let captureTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if model.busy {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        fputs("预览生成超时，未导出未完成的视图。\n", stderr)
                        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                        exit(1)
                    }
                    return
                }
                timer.invalidate()
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    guard let data = rep.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "RenderViews", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法编码视图 PNG。"])
                    }
                    try data.write(to: URL(fileURLWithPath: arguments[2]))
                } catch { print(error); exit(1) }
                window.orderOut(nil)
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                app.terminate(nil)
            }
        }
        withExtendedLifetime(captureTimer) { app.run() }
    }
}
