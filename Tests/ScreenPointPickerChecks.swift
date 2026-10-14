import AppKit

@main struct ScreenPointPickerChecks {
    static func main() {
        func require(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        let top: CGFloat = 900
        require(ScreenPointPicker.quartzPoint(fromAppKit: CGPoint(x: 0, y: 900), primaryTop: top) == .zero,
                "主屏左上角必须映射到 Quartz 原点")
        require(ScreenPointPicker.quartzPoint(fromAppKit: CGPoint(x: 50.25, y: 850.5), primaryTop: top)
                == CGPoint(x: 50.25, y: 49.5), "保留屏幕点精度，不乘 Retina 缩放")
        require(ScreenPointPicker.quartzPoint(fromAppKit: CGPoint(x: -1440, y: 1080), primaryTop: top)
                == CGPoint(x: -1440, y: -180), "左方和上方显示器应保留负坐标")
        require(ScreenPointPicker.quartzPoint(fromAppKit: CGPoint(x: 1920, y: -400), primaryTop: top)
                == CGPoint(x: 1920, y: 1300), "下方显示器应使用同一全局原点")
        print("PASS tool-button AppKit/Quartz coordinates / negative display origins / fractional screen points")
    }
}
