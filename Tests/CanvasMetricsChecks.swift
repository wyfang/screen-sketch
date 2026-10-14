import AppKit

@main struct CanvasMetricsChecks {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    @MainActor static func main() {
        let primary = CanvasDisplay(quartzFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    backingScale: 2, name: "内置 Retina")
        let left = CanvasDisplay(quartzFrame: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                                 backingScale: 1, name: "左侧显示器")
        let displays = [primary, left]
        let retinaRect = CGRect(x: 40.25, y: 20.5, width: 320.25, height: 100.75)
        let retina = CanvasMetrics.resolve(rect: retinaRect, displays: displays)!
        require(retina.rect == retinaRect, "不能把鼠标屏幕点乘以 backing 比例")
        require(retina.backingScale == 2 && retina.pixelQuantum == 0.5, "Retina 像素量子应为半点")
        require(retina.pixelSize == CGSize(width: 641, height: 202), "预览像素尺寸应由实际画布点尺寸向上取整")
        require(retina.displayName == primary.name, "应显示真正包含选区的屏幕")
        let negative = CanvasMetrics.resolve(rect: CGRect(x: -1800, y: -200, width: 600, height: 400), displays: displays)!
        require(negative.rect.minX == -1800 && negative.rect.minY == -200, "外接屏负坐标不得截断")
        require(negative.pixelSize == CGSize(width: 600, height: 400) && negative.pixelQuantum == 1, "非 Retina 屏不能沿用主屏比例")
        require(CanvasMetrics.resolve(rect: left.quartzFrame, displays: displays) != nil, "覆盖屏幕边界的完整选区应接受")
        require(CanvasMetrics.resolve(rect: CGRect(x: -20, y: 0, width: 40, height: 40), displays: displays) == nil, "跨屏矩形不能假定单一比例")
        require(CanvasMetrics.resolve(rect: CGRect(x: 5000, y: 5000, width: 40, height: 40), displays: displays) == nil, "离屏区域应拒绝")
        let invalid: [CGRect] = [.zero, CGRect(x: 0, y: 0, width: -1, height: 1),
                                 CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                                 CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)]
        for rect in invalid {
            require(CanvasMetrics.resolve(rect: rect, displays: displays) == nil, "无效矩形不得用于生成图像")
        }
        for scale in [Double.nan, Double.infinity, 0, -1, Double.leastNonzeroMagnitude] {
            let display = CanvasDisplay(quartzFrame: primary.quartzFrame, backingScale: scale, name: "无效")
            require(CanvasMetrics.resolve(rect: retinaRect, displays: [display]) == nil, "无效 backing 比例应拒绝")
        }
        let mirrored = CanvasDisplay(quartzFrame: primary.quartzFrame, backingScale: 1, name: "镜像")
        require(CanvasMetrics.resolve(rect: retinaRect, displays: [mirrored, primary])?.backingScale == 2, "镜像描述取较高比例")
        // Native API reads only display metadata. It does not capture pixels or inject input.
        if let screen = NSScreen.screens.first {
            let rect = CGRect(x: screen.frame.minX, y: 0, width: 100, height: 100)
            let actual = CanvasMetrics.current(for: rect)
            require(actual?.backingScale == Double(screen.backingScaleFactor), "实际主屏比例必须使用 AppKit backingScaleFactor")
            print("PASS native display \(actual!.displayName) \(actual!.backingScale)×")
        }
        print("PASS logical screen points / Retina backing pixels / negative origins / same-screen containment / finite values / mirror resolution")
    }
}
