import AppKit
import Foundation

@main
struct SpacingCalibrationChecks {
    @MainActor
    static func main() {
        var count = 0
        func check(_ result: Bool, _ message: String) {
            count += 1
            if !result { print("FAIL: \(message)"); exit(1) }
        }
        func approximately(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        func prepareAndMark(_ model: SpacingCalibration, brush: Double = 2.5, movement: Double = 3) {
            check(!model.numberedPaths(brushWidth: brush, minimumMovement: movement).isEmpty, "valid numbered spacing paths")
            check(model.markDrawn(), "only full completed plan enables feedback")
        }
        let area = CGRect(x: -900, y: -300, width: 420, height: 300)
        for axis in SpacingAxis.allCases {
            let model = SpacingCalibration()
            model.axis = axis
            check(model.candidates == [0.5, 1, 2, 4, 8, 16], "first round contains six candidates")
            check(!model.selectShortestVisible(index: 0), "feedback cannot precede drawing")
            check(!model.noneVisible(), "all-invisible cannot precede drawing")
            check(!model.markDrawn(), "completion requires prepared valid layout")
            check(!model.finishWithCurrentResult(), "adoption requires previously completed visible feedback")
            check(model.setArea(area), "negative-origin Quartz test region accepted")
            let paths = model.numberedPaths(brushWidth: 2.5, minimumMovement: 3)
            check(paths.count == 42, "six groups contain one numeral and three pairs each")
            let safe = area.insetBy(dx: 2.5 / 2 + 4, dy: 2.5 / 2 + 4)
            for row in 0..<6 {
                let label = paths[row * 7]
                check(label.count >= 2, "number is drawn with real pen path")
                var maximumLabelX = -Double.infinity
                for point in label {
                    let absolute = CGPoint(x: area.minX + point.x * area.width, y: area.minY + point.y * area.height)
                    check(safe.contains(absolute), "numeral and footprint stay inside region")
                    maximumLabelX = max(maximumLabelX, absolute.x)
                }
                for repeatIndex in 0..<3 {
                    let first = paths[row * 7 + 1 + repeatIndex * 2]
                    let second = paths[row * 7 + 2 + repeatIndex * 2]
                    check(first.count == 2 && second.count == 2, "pair consists of complete individual straight lines")
                    for path in [first, second] {
                        let start = CGPoint(x: area.minX + path[0].x * area.width, y: area.minY + path[0].y * area.height)
                        let end = CGPoint(x: area.minX + path[1].x * area.width, y: area.minY + path[1].y * area.height)
                        check(hypot(end.x - start.x, end.y - start.y) > 3, "test lines exceed movement threshold")
                        check(safe.contains(start) && safe.contains(end), "test line footprint remains inside region")
                        check(min(start.x, end.x) > maximumLabelX + 2.5, "numeral cannot join test pair")
                        check(axis == .x ? approximately(start.x, end.x) : approximately(start.y, end.y), "correct line orientation for tested axis")
                    }
                    let actualDistance = axis == .x
                        ? (second[0].x - first[0].x) * area.width
                        : (second[0].y - first[0].y) * area.height
                    check(approximately(actualDistance, model.candidates[row]), "center distance equals candidate without Retina or region scaling")
                }
            }
            check(!model.selectShortestVisible(index: 2), "prepared paths alone never enable feedback")
            check(model.markDrawn(), "complete drawing enables feedback")
            check(!model.markDrawn(), "completion cannot be duplicated")
            check(model.numberedPaths(brushWidth: 2.5, minimumMovement: 3).isEmpty, "completed round requires explicit repeat before redrawing")
            check(!model.selectShortestVisible(index: 6), "nonexistent group cannot be selected")
            model.selectedRow = 2
            check(model.selectShortestVisible(index: 2), "2-point separation feedback accepted")
            check(model.lowerBound == 1 && model.upperBound == 2 && model.measuredMinimum == 2, "adjacent candidates bracket clear separation")
            check(model.candidates == [1.25, 1.5, 1.75, 2] && model.round == 2, "refinement offers four groups")
            check(!model.hasDrawn && model.selectedRow == nil && !model.finished, "new round resets stale completion and selection")
            check(!model.selectShortestVisible(index: 1), "stale feedback cannot advance next round")
            let refined = model.numberedPaths(brushWidth: 2.5, minimumMovement: 3)
            check(refined.count == 28, "refined round has four numerals and twelve pairs")
            check(model.markDrawn() && model.selectShortestVisible(index: 1), "refined completed feedback accepted")
            check(model.finished && model.measuredMinimum == 1.5 && model.suggestedMinimum == 1.75, "quarter-point result includes stable margin")
            check(!model.noneVisible() && !model.selectShortestVisible(index: 0), "finished result rejects new feedback")
            check(model.numberedPaths(brushWidth: 2.5, minimumMovement: 3).isEmpty, "finished result cannot silently draw")
        }

        let changing = SpacingCalibration()
        _ = changing.setArea(area)
        prepareAndMark(changing)
        _ = changing.selectShortestVisible(index: 3)
        check(changing.measuredMinimum == 4 && changing.round == 2, "confirmed earlier result retained during refinement")
        check(changing.setArea(CGRect(x: 100, y: 150, width: 440, height: 320)), "can select separate empty region for next round")
        check(changing.candidates == [2.5, 3, 3.5, 4] && changing.round == 2 && !changing.hasDrawn, "region change keeps bracket but invalidates unfinished plan")
        check(changing.message.contains("此前完整轮已确认 4 点"), "retained prior result clearly identified")
        check(changing.finishWithCurrentResult(), "user may end with previously confirmed complete round")
        check(changing.finished && changing.suggestedMinimum == 4.4, "early adoption adds ten-percent margin")
        check(changing.upperBound - changing.lowerBound > 0.25, "early adoption preserves unresolved bracket")
        changing.selectedRow = 0
        changing.axis = .y
        check(changing.axis == .y && changing.area != nil && changing.round == 1, "axis change restarts measurement while keeping selected region")
        check(changing.measuredMinimum == nil && changing.suggestedMinimum == nil && !changing.finished && changing.selectedRow == nil, "axis change cannot adopt X feedback as Y result")
        check(!changing.finishWithCurrentResult(), "unmeasured alternate axis cannot be adopted")
        prepareAndMark(changing)
        _ = changing.selectShortestVisible(index: 2)
        check(changing.numberedPaths(brushWidth: 3, minimumMovement: 3).isEmpty, "changed brush requires review of fresh first-round layout before drawing")
        check(changing.round == 1 && changing.candidates.count == 6 && changing.measuredMinimum == nil, "changed brush clears stale visible threshold and bracket")
        check(!changing.finishWithCurrentResult(), "changed brush cannot use prior result")
        check(!changing.numberedPaths(brushWidth: 3, minimumMovement: 3).isEmpty, "new first-round can be drawn after parameter-reset warning")
        _ = changing.markDrawn()
        _ = changing.selectShortestVisible(index: 3)
        check(changing.numberedPaths(brushWidth: 3, minimumMovement: 4).isEmpty, "changed minimum movement requires review of restarted round")
        check(changing.round == 1 && changing.measuredMinimum == nil, "changed movement clears previous visual feedback")

        for axis in SpacingAxis.allCases {
            let invalid = SpacingCalibration()
            invalid.axis = axis
            check(!invalid.setArea(CGRect(x: Double.nan, y: 0, width: 200, height: 200)), "nonfinite region rejected")
            check(!invalid.setArea(CGRect(x: 1e308, y: 0, width: 1e308, height: 200)), "overflowing region endpoint rejected")
            check(!invalid.setArea(CGRect(x: 0, y: 0, width: 0, height: 200)), "zero-width region rejected")
            _ = invalid.setArea(CGRect(x: 0, y: 0, width: 80, height: 300))
            check(invalid.numberedPaths(brushWidth: 2.5, minimumMovement: 3).isEmpty && invalid.message.contains("测试区太小"), "narrow region rejected rather than scaling candidates")
            check(!invalid.markDrawn(), "failed plan cannot enable feedback")
            _ = invalid.setArea(CGRect(x: 0, y: 0, width: 420, height: 80))
            check(invalid.numberedPaths(brushWidth: 2.5, minimumMovement: 3).isEmpty, "short region rejected")
            _ = invalid.setArea(area)
            for brush in [Double.nan, Double.infinity, 0, -2] {
                check(invalid.numberedPaths(brushWidth: brush, minimumMovement: 3).isEmpty, "invalid brush rejected")
            }
            for movement in [Double.nan, Double.infinity, -2] {
                check(invalid.numberedPaths(brushWidth: 2.5, minimumMovement: movement).isEmpty, "invalid movement rejected")
            }
            check(!invalid.numberedPaths(brushWidth: 2.5, minimumMovement: 0).isEmpty, "targets without movement threshold accept zero")
            check(invalid.numberedPaths(brushWidth: 1e308, minimumMovement: 1e308).isEmpty, "overflowing finite settings rejected without integer conversion crash")

            let wideMovement = SpacingCalibration()
            wideMovement.axis = axis
            _ = wideMovement.setArea(CGRect(x: -1500, y: 50, width: 1400, height: 1400))
            let longPaths = wideMovement.numberedPaths(brushWidth: 4, minimumMovement: 40)
            check(longPaths.count == 42, "large movement threshold supported with larger real region")
            for path in longPaths {
                for index in 1..<path.count {
                    let dx = (path[index].x - path[index - 1].x) * 1400
                    let dy = (path[index].y - path[index - 1].y) * 1400
                    check(hypot(dx, dy) > 40, "every numeral segment and test line exceeds calibrated movement threshold")
                }
            }

            let expanding = SpacingCalibration()
            expanding.axis = axis
            _ = expanding.setArea(area)
            prepareAndMark(expanding)
            check(expanding.noneVisible(), "all overlapping pairs expand candidate distance")
            check(expanding.candidates == [20, 24, 28, 32] && expanding.lowerBound == 16 && expanding.upperBound == 32, "expanded spacing candidates maintain adjacent bracket")
            check(!expanding.noneVisible(), "duplicate feedback cannot expand untested next round")
            prepareAndMark(expanding)
            check(expanding.repeatRound() && !expanding.hasDrawn, "repeat clears completed status")
            check(expanding.candidates == [20, 24, 28, 32] && expanding.round == 2, "repeat preserves measurement bracket")
            expanding.retest()
            check(expanding.round == 1 && expanding.candidates.count == 6 && expanding.area != nil && expanding.axis == axis, "retest preserves region and direction")

            let bounded = SpacingCalibration()
            bounded.axis = axis
            _ = bounded.setArea(axis == .x
                ? CGRect(x: 0, y: 0, width: 132, height: 300)
                : CGRect(x: 0, y: 0, width: 420, height: 260))
            prepareAndMark(bounded)
            check(bounded.noneVisible(), "limited area allows bounded expansion")
            var lastRound = bounded.round
            var capacityStopped = false
            for _ in 0..<6 {
                prepareAndMark(bounded)
                lastRound = bounded.round
                if !bounded.noneVisible() { capacityStopped = true; break }
            }
            check(capacityStopped, "expansion stops at actual four-group geometric capacity")
            check(bounded.round == lastRound && bounded.measuredMinimum == nil && !bounded.finished, "capacity limit never invents visible threshold")
            check(!bounded.finishWithCurrentResult(), "all-invisible limited region cannot be adopted")
            check(bounded.message.contains("先完整"), "adoption explains missing completed visible feedback")

            for threshold in [0.01, 0.5, 0.7, 2.6, 15.9, 40.3] {
                let converging = SpacingCalibration()
                converging.axis = axis
                _ = converging.setArea(area)
                for _ in 0..<12 {
                    if converging.finished { break }
                    prepareAndMark(converging)
                    if let visible = converging.candidates.firstIndex(where: { $0 >= threshold }) {
                        check(converging.selectShortestVisible(index: visible), "simulated visible-spacing feedback accepted")
                    } else {
                        check(converging.noneVisible(), "simulated high visual threshold expands safely")
                    }
                }
                check(converging.finished, "all simulated visual thresholds converge in bounded rounds")
                check(converging.lowerBound < threshold && converging.upperBound >= threshold, "final bracket contains actual separability threshold")
                check(converging.upperBound - converging.lowerBound <= 0.25 + 0.000_001, "converged visual bracket reaches quarter-point precision")
                check(converging.suggestedMinimum! > converging.measuredMinimum!, "recommended visual spacing includes margin")
            }
        }
        check(SpacingAxis.x.explanation.contains("竖线") && SpacingAxis.y.explanation.contains("横线"), "directions explain perpendicular strokes correctly")
        check(SpacingCalibration.format(0) == "0" && SpacingCalibration.format(0.125) == "0.125", "labels preserve subpoint precision")
        print("SpacingCalibrationChecks: \(count) checks passed; no mouse events posted.")
    }
}
