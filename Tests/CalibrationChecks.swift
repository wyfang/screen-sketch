import AppKit
import Foundation

@main
struct CalibrationChecks {
    @MainActor
    static func main() {
        var count = 0
        func check(_ result: Bool, _ message: String) {
            count += 1
            if !result {
                print("FAIL: \(message)")
                exit(1)
            }
        }
        func approximately(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        func prepareAndMark(_ model: MovementCalibration, brush: Double = 2.5) {
            check(!model.normalizedPaths(brushWidth: brush).isEmpty, "round has valid paths")
            check(model.markDrawn(), "complete drawing enables feedback")
        }

        let area = CGRect(x: -900, y: 120, width: 420, height: 260)
        let model = MovementCalibration()
        check(model.candidates == [0.5, 1, 2, 4, 8, 16], "initial six candidates")
        check(!model.selectShortestVisible(index: 0), "feedback before drawing is rejected")
        check(!model.markDrawn(), "completion without paths is rejected")
        check(model.setArea(area), "negative-origin Quartz area accepted")
        let paths = model.normalizedPaths(brushWidth: 2.5)
        check(paths.count == 18, "six rows have three paths each")
        for (index, path) in paths.enumerated() {
            check(path.count == 2, "every calibration line has exactly two points")
            let first = CGPoint(x: area.minX + path[0].x * area.width, y: area.minY + path[0].y * area.height)
            let last = CGPoint(x: area.minX + path[1].x * area.width, y: area.minY + path[1].y * area.height)
            check(approximately(hypot(last.x - first.x, last.y - first.y), model.candidates[index / 3]), "screen length equals candidate exactly")
            check(approximately(first.y, last.y), "calibration lines are horizontal")
            let safe = area.insetBy(dx: 2.5 / 2 + 4, dy: 2.5 / 2 + 4)
            check(safe.contains(first) && safe.contains(last), "complete brush footprint remains inside area")
            if index >= 3 { check(first.y > area.minY + paths[index - 3][0].y * area.height, "rows increase downward") }
        }
        check(model.markDrawn(), "first round completes")
        check(!model.markDrawn(), "duplicate completion rejected")
        check(!model.selectShortestVisible(index: 6), "invalid feedback row rejected")
        check(model.selectShortestVisible(index: 2), "shortest visible 2pt accepted")
        check(model.lowerBound == 1 && model.upperBound == 2, "bracket adjacent initial lengths")
        check(model.candidates == [1.25, 1.5, 1.75, 2], "range refined into four candidate lengths")
        check(model.round == 2 && !model.hasDrawn && !model.finished, "new round requires fresh drawing")
        let beforeCandidates = model.candidates
        check(!model.selectShortestVisible(index: 1), "duplicate feedback cannot advance new round")
        check(model.candidates == beforeCandidates && model.round == 2, "duplicate feedback leaves interval unchanged")
        prepareAndMark(model)
        check(model.selectShortestVisible(index: 1), "refined row accepted")
        check(model.finished && approximately(model.upperBound - model.lowerBound, 0.25), "quarter-point bracket converges")
        check(model.measuredMinimum == 1.5 && model.suggestedMinimum == 1.75, "known-visible upper bound and stable margin")
        check(!model.selectShortestVisible(index: 0) && !model.noneVisible(), "finished result rejects additional feedback")
        check(model.normalizedPaths(brushWidth: 2.5).isEmpty, "finished result cannot silently redraw")

        let allVisible = MovementCalibration()
        _ = allVisible.setArea(area)
        prepareAndMark(allVisible)
        check(allVisible.selectShortestVisible(index: 0), "first row visible narrows toward zero")
        check(allVisible.lowerBound == 0 && allVisible.upperBound == 0.5, "zero-to-first bracket preserved")
        check(allVisible.candidates == [0.125, 0.25, 0.375, 0.5], "subpoint candidates preserve exact precision")
        prepareAndMark(allVisible)
        _ = allVisible.selectShortestVisible(index: 0)
        check(allVisible.finished && allVisible.measuredMinimum == 0.125, "all-visible refinement converges without zero-length line")
        check(allVisible.suggestedMinimum == 0.4, "safety margin rounds upward by 0.05pt")

        let none = MovementCalibration()
        _ = none.setArea(area)
        prepareAndMark(none)
        check(none.noneVisible(), "all invisible expands range")
        check(none.lowerBound == 16 && none.upperBound == 32 && none.candidates == [20, 24, 28, 32], "expanded range bracket and candidates")
        check(none.measuredMinimum == nil && none.suggestedMinimum == nil && !none.finished, "no unobserved minimum invented")
        check(!none.noneVisible(), "duplicate all-invisible feedback rejected")
        prepareAndMark(none)
        check(none.repeatRound() && !none.hasDrawn, "repeat current round clears completion only")
        check(none.candidates == [20, 24, 28, 32] && none.round == 2, "repeat preserves bracket and round")
        check(none.setArea(CGRect(x: 400, y: -400, width: 480, height: 300)), "next round can use another empty screen region")
        check(none.candidates == [20, 24, 28, 32] && none.round == 2, "changing empty area retains refinement")
        none.retest()
        check(none.round == 1 && none.candidates == [0.5, 1, 2, 4, 8, 16] && none.area != nil, "retest resets measurement but keeps selected area")

        let narrow = MovementCalibration()
        _ = narrow.setArea(CGRect(x: 0, y: 0, width: 80, height: 300))
        check(narrow.normalizedPaths(brushWidth: 2.5).isEmpty && narrow.message.contains("测试区太小"), "narrow area rejected instead of scaling line lengths")
        check(!narrow.markDrawn(), "invalid area layout cannot enable feedback")
        _ = narrow.setArea(CGRect(x: 0, y: 0, width: 420, height: 80))
        check(narrow.normalizedPaths(brushWidth: 2.5).isEmpty, "short area rejected")
        _ = narrow.setArea(area)
        check(narrow.normalizedPaths(brushWidth: .nan).isEmpty, "nonfinite brush rejected")
        check(narrow.normalizedPaths(brushWidth: 0).isEmpty, "zero brush rejected")
        check(!narrow.setArea(CGRect(x: Double.nan, y: 0, width: 200, height: 200)) && narrow.area == nil, "nonfinite area rejected")

        let bounded = MovementCalibration()
        _ = bounded.setArea(CGRect(x: 0, y: 0, width: 132, height: 300))
        prepareAndMark(bounded)
        check(bounded.noneVisible(), "expansion clamps to available width")
        check(bounded.upperBound < 20 && bounded.upperBound > 16, "small remaining width produces bounded candidates")
        prepareAndMark(bounded)
        let boundRound = bounded.round
        check(!bounded.noneVisible(), "no further expansion beyond actual test width")
        check(bounded.round == boundRound && !bounded.finished && bounded.measuredMinimum == nil, "capacity failure does not invent convergence")
        check(bounded.message.contains("更宽"), "capacity failure asks for a wider empty area")

        // 用可见性阈值模拟器覆盖各夹逼分支；不会启动窗口或投递鼠标事件。
        for threshold in [0.01, 0.5, 0.7, 2.6, 15.9, 40.3] {
            let converging = MovementCalibration()
            _ = converging.setArea(area)
            for _ in 0..<12 {
                if converging.finished { break }
                prepareAndMark(converging)
                if let visible = converging.candidates.firstIndex(where: { $0 >= threshold }) {
                    check(converging.selectShortestVisible(index: visible), "simulated shortest-visible feedback accepted")
                } else {
                    check(converging.noneVisible(), "simulated high threshold expands safely")
                }
            }
            check(converging.finished, "threshold simulation converges within bounded rounds")
            check(converging.lowerBound < threshold && converging.upperBound >= threshold,
                  "converged bracket contains actual simulated minimum")
            check(converging.upperBound - converging.lowerBound <= 0.25 + 0.000_001,
                  "all simulated brackets meet quarter-point tolerance")
        }

        check(MovementCalibration.format(0) == "0", "zero label")
        check(MovementCalibration.format(16) == "16", "integer label")
        check(MovementCalibration.format(0.125) == "0.125", "subpoint label")
        let numbered = MovementCalibration()
        _ = numbered.setArea(area)
        let numberedPaths = numbered.numberedPaths(brushWidth: 2.5)
        check(numberedPaths.count == 24, "six rows each contain one drawn numeral and three test lines")
        for row in 0..<6 {
            let label = numberedPaths[row * 4]
            check(label.count >= 2 && label.allSatisfy { $0.x > 0 && $0.x < 1 && $0.y > 0 && $0.y < 1 }, "drawn numeral stays inside selected test area")
            for repeatIndex in 1...3 {
                let line = numberedPaths[row * 4 + repeatIndex]
                check(approximately((line[1].x - line[0].x) * area.width, numbered.candidates[row]), "labels never alter the true calibration distance")
            }
        }
        let early = MovementCalibration()
        check(!early.finishWithCurrentResult(), "cannot finish without a user-confirmed visible line")
        _ = early.setArea(area)
        prepareAndMark(early)
        _ = early.selectShortestVisible(index: 3)
        check(early.finishWithCurrentResult(), "user may finish early after confirming a visible group")
        check(early.finished && early.measuredMinimum == 4 && early.suggestedMinimum == 4.4, "early finish keeps confirmed upper bound and adds margin")
        check(early.upperBound - early.lowerBound > 0.25, "early finish does not pretend the interval has converged")
        print("CalibrationChecks: \(count) checks passed; no mouse events posted.")
    }
}
