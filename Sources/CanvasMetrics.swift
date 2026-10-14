import AppKit

/// 显示器的绘图坐标以 Quartz 全局屏幕点表示，而非面板标称像素。
struct CanvasDisplay {
    let quartzFrame: CGRect
    let backingScale: Double
    let name: String
}

/// 鼠标仍使用屏幕点；backing 像素仅用于渲染预览和表达当前显示精度。
struct CanvasMetrics {
    let rect: CGRect
    let backingScale: Double
    let pixelSize: CGSize
    let displayName: String

    /// 一个 backing 像素对应的屏幕点数，并非 CGEvent 的最低可传输步长。
    var pixelQuantum: Double { 1 / backingScale }

    @MainActor
    static func current(for rect: CGRect) -> CanvasMetrics? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let primaryTop = primary.frame.maxY
        let displays = screens.map { screen in
            CanvasDisplay(quartzFrame: CGRect(x: screen.frame.minX,
                                              y: primaryTop - screen.frame.maxY,
                                              width: screen.frame.width,
                                              height: screen.frame.height),
                          backingScale: Double(screen.backingScaleFactor),
                          name: screen.localizedName)
        }
        return resolve(rect: rect, displays: displays)
    }

    /// 仅接受完整位于一块显示器内的区域。跨屏没有单一 backing 比例，须重新框选。
    /// 镜像屏或重叠描述取最高有效比例，避免丢失预览可表达的像素。
    static func resolve(rect: CGRect, displays: [CanvasDisplay]) -> CanvasMetrics? {
        guard isValid(rect) else { return nil }
        let containing = displays.filter {
            isValid($0.quartzFrame) && $0.backingScale.isFinite && $0.backingScale > 0
                && (1 / $0.backingScale).isFinite
                && $0.quartzFrame.contains(rect)
        }
        guard let display = containing.max(by: { $0.backingScale < $1.backingScale }) else { return nil }
        let width = rect.width * display.backingScale
        let height = rect.height * display.backingScale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CanvasMetrics(rect: rect, backingScale: display.backingScale,
                             pixelSize: CGSize(width: ceil(width), height: ceil(height)),
                             displayName: display.name)
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }
}
