import AppKit
import Foundation

@main struct GeometryChecks {
    static func main() {
        func require(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        let rect = CGRect(x: -1440, y: -420, width: 800, height: 600)
        let input = [[CGPoint(x: -0.2, y: -0.1), CGPoint(x: 0.25, y: 0.6), CGPoint(x: 1.2, y: 1.1)]]
        let mapped = DrawingEngine.mapPaths(input, to: rect, brushWidth: 8)
        let safe = rect.insetBy(dx: 5, dy: 5)
        require(mapped.count == 1 && mapped[0].count == 3, "应保留完整路径")
        require(mapped[0].allSatisfy { $0.x >= safe.minX && $0.x <= safe.maxX && $0.y >= safe.minY && $0.y <= safe.maxY }, "含笔刷半径的笔画不能越界")
        require(mapped[0][1] == CGPoint(x: -1240, y: -60), "正常坐标必须按完整画布映射，不能重复缩小安全区")
        require(DrawingEngine.mapPaths([[CGPoint(x: CGFloat.nan, y: 0)]], to: rect, brushWidth: 1).isEmpty, "NaN路径不得产生输入")
        require(DrawingEngine.mapPaths(input, to: CGRect(x: 0, y: 0, width: 5, height: 5), brushWidth: 8).isEmpty, "过小画布必须拒绝")
        let slow = DrawingEngine.estimateSeconds(paths: input, rect: rect, brushWidth: 8, speed: 100)
        let fast = DrawingEngine.estimateSeconds(paths: input, rect: rect, brushWidth: 8, speed: 900)
        require(slow > fast && fast > 3, "速度应影响耗时估计，且保留笔画开销")
        print("PASS negative screen origins / finite coordinate filtering / brush-safe bounds / exact interior mapping / speed estimate")
    }
}
