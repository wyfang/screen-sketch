import AppKit
import Foundation

@main
struct CalibrationCleanupChecks {
    @MainActor
    static func main() throws {
        var count = 0
        func check(_ result: Bool, _ message: String) {
            count += 1
            if !result { print("FAIL: \(message)"); exit(1) }
        }
        func rejects(_ footprint: CalibrationFootprint, _ expected: CalibrationCleanupError, _ message: String) {
            do {
                _ = try CalibrationCleanup.replay(footprint: footprint)
                check(false, message)
            } catch let error as CalibrationCleanupError {
                check(error == expected, message)
            } catch { check(false, "unexpected error: \(error)") }
        }
        let area = CGRect(x: -1440, y: -420, width: 400, height: 320)
        var original = [
            // 一个多拐角数字、短线、重复顶点和单点，均按原样保留。
            [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.135, y: 0.1),
             CGPoint(x: 0.135, y: 0.1875), CGPoint(x: 0.1, y: 0.1875)],
            [CGPoint(x: 0.45, y: 0.3), CGPoint(x: 0.45125, y: 0.3)],
            [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.5)],
            [CGPoint(x: 0.65, y: 0.6)]
        ]
        let snapshot = original
        let footprint = CalibrationFootprint(paths: original, area: area, brushWidth: 2.5, targetPID: 1)
        original.removeAll()
        check(footprint.paths == snapshot, "footprint remains immutable when the source plan changes")
        let replay = try CalibrationCleanup.replay(footprint: footprint)
        check(replay == snapshot, "replay preserves every original normalized center, corner, label and short stroke")
        check(replay.count == 4 && replay[2].count == 3 && replay[3].count == 1,
              "repeated vertices and single-point strokes are not lost")
        check(abs(footprint.longestSegmentLength - 40) < 0.000_001,
              "longest physical segment uses Quartz area dimensions, not normalized length")
        let actual = DrawingEngine.mapPaths(replay, to: area, brushWidth: footprint.brushWidth)
        let drawn = DrawingEngine.mapPaths(snapshot, to: area, brushWidth: 2.5)
        check(actual == drawn, "negative-origin cleanup maps to the exact original screen points without clamping")
        check(actual[0][0] == CGPoint(x: -1400, y: -388), "negative Quartz origins remain unchanged")
        check(abs(actual[1][1].x - actual[1][0].x - 0.5) < 0.000_001,
              "subpoint stroke keeps its original physical length")
        // Previously a 30-point target eraser was rejected here with a maximum of 6.
        // Its actual size is now entirely target-controlled; replay uses original centers.
        let fourFromBorder = CalibrationFootprint(
            paths: [[CGPoint(x: 0.01, y: 0.5), CGPoint(x: 0.5, y: 0.5)]],
            area: area, brushWidth: 2, targetPID: 1)
        let borderReplay = try CalibrationCleanup.replay(footprint: fourFromBorder)
        check(borderReplay == fourFromBorder.paths, "four-point edge clearance no longer rejects a target-controlled eraser")
        let borderMapped = DrawingEngine.mapPaths(borderReplay, to: area, brushWidth: fourFromBorder.brushWidth)
        check(borderMapped[0][0] == CGPoint(x: area.minX + 4, y: area.midY),
              "near-border replay preserves original physical center, independent of actual eraser width")
        for invalidBrush in [0.0, -1, Double.nan, Double.infinity] {
            let bad = CalibrationFootprint(paths: snapshot, area: area, brushWidth: invalidBrush, targetPID: 1)
            rejects(bad, .invalidBrushWidth, "invalid recorded pencil rejected")
        }
        for invalidArea in [CGRect(x: 0, y: 0, width: 0, height: 20),
                            CGRect(x: Double.nan, y: 0, width: 100, height: 100),
                            CGRect(x: 0, y: 0, width: Double.infinity, height: 100)] {
            let bad = CalibrationFootprint(paths: snapshot, area: invalidArea, brushWidth: 2.5, targetPID: 1)
            rejects(bad, .invalidArea, "invalid recorded area rejected")
        }
        for invalidPaths in [[], [[]], [[CGPoint(x: Double.nan, y: 0.5)]],
                             [[CGPoint(x: 0.5, y: Double.infinity)]], [[CGPoint(x: -0.01, y: 0.5)]],
                             [[CGPoint(x: 1.01, y: 0.5)]]] as [[[CGPoint]]] {
            let bad = CalibrationFootprint(paths: invalidPaths, area: area, brushWidth: 2.5, targetPID: 1)
            rejects(bad, .invalidPaths, "invalid or out-of-normalized-bounds paths rejected")
        }
        let invalidTarget = CalibrationFootprint(paths: snapshot, area: area, brushWidth: 2.5, targetPID: 0)
        rejects(invalidTarget, .invalidTarget, "missing process binding rejected")
        let nearEdge = CalibrationFootprint(paths: [[CGPoint(x: 0.00375, y: 0.5), CGPoint(x: 0.5, y: 0.5)]],
                                            area: area, brushWidth: 2, targetPID: 1)
        // 原画笔映射会夹紧记录的中心线，因此该记录无效。
        rejects(nearEdge, .invalidPaths, "recorded brush mapping clamp hazard rejected")
        let tinyArea = CalibrationFootprint(paths: [[CGPoint(x: 0.5, y: 0.5)]],
                                            area: CGRect(x: 0, y: 0, width: 4, height: 4),
                                            brushWidth: 2, targetPID: 1)
        rejects(tinyArea, .invalidArea, "engine rejects zero-width original brush inset even with a centered point")

        // 使用真实校准生成器，确认数字和三条/三对短线均能原样清理。
        // 不调用 markDrawn：完整计划在绘制中断时也必须可擦除。
        let testArea = CGRect(x: -950, y: 120, width: 620, height: 360)
        let movement = MovementCalibration()
        check(movement.setArea(testArea), "movement blank test area configured")
        let movementPaths = movement.numberedPaths(brushWidth: 2.5)
        check(movementPaths.count == 24, "movement retains all six numeral labels and eighteen short lines")
        let movementFootprint = CalibrationFootprint(paths: movementPaths, area: testArea, brushWidth: 2.5, targetPID: 42)
        check(try CalibrationCleanup.replay(footprint: movementFootprint) == movementPaths,
              "interrupted movement cleanup replays the complete recorded plan")
        check(DrawingEngine.mapPaths(movementPaths, to: testArea, brushWidth: 2.5) ==
              DrawingEngine.mapPaths(movementFootprint.paths, to: testArea, brushWidth: movementFootprint.brushWidth),
              "real movement numerals and candidates remain at identical screen positions")
        for axis in SpacingAxis.allCases {
            let spacing = SpacingCalibration()
            spacing.axis = axis
            check(spacing.setArea(testArea), "spacing blank test area configured")
            let spacingPaths = spacing.numberedPaths(brushWidth: 2.5, minimumMovement: 3)
            check(spacingPaths.count == 42, "spacing retains six labels and thirty-six line paths")
            let spacingFootprint = CalibrationFootprint(paths: spacingPaths, area: testArea, brushWidth: 2.5, targetPID: 42)
            check(try CalibrationCleanup.replay(footprint: spacingFootprint) == spacingPaths,
                  "both spacing directions preserve all planned strokes")
            check(DrawingEngine.mapPaths(spacingPaths, to: testArea, brushWidth: 2.5) ==
                  DrawingEngine.mapPaths(spacingFootprint.paths, to: testArea, brushWidth: spacingFootprint.brushWidth),
                  "spacing eraser mapping does not shift tests or labels")
        }
        print("CalibrationCleanupChecks: \(count) checks passed; no mouse events posted.")
    }
}
