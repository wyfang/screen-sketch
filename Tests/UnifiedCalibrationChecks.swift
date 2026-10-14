import AppKit
import Foundation

@main
struct UnifiedCalibrationChecks {
    @MainActor
    static func main() throws {
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { print("FAIL: \(message)"); exit(1) }
        }
        func approximately(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        func screen(_ point: CGPoint, in area: CGRect) -> CGPoint {
            CGPoint(x: area.minX + point.x * area.width, y: area.minY + point.y * area.height)
        }
        func length(_ path: [CGPoint], in area: CGRect) -> Double {
            let first = screen(path[0], in: area), last = screen(path[path.count - 1], in: area)
            return hypot(last.x - first.x, last.y - first.y)
        }
        func pointDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let fraction = squared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared))
            return hypot(p.x - a.x - fraction * dx, p.y - a.y - fraction * dy)
        }
        func segmentDistance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Double {
            let denominator = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x)
            if denominator != 0 {
                let t = ((c.x - a.x) * (d.y - c.y) - (c.y - a.y) * (d.x - c.x)) / denominator
                let u = ((c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)) / denominator
                if (0...1).contains(t) && (0...1).contains(u) { return 0 }
            }
            return min(pointDistance(a, c, d), pointDistance(b, c, d), pointDistance(c, a, b), pointDistance(d, a, b))
        }
        func checkAnnotationIsolation(_ plan: UnifiedCalibrationRound) {
            let required = 18.0
            for test in plan.actualTestPaths {
                for dynamic in zip(test, test.dropFirst()) {
                    let a = screen(dynamic.0, in: plan.area), b = screen(dynamic.1, in: plan.area)
                    for annotation in plan.annotationPaths {
                        for fixed in zip(annotation, annotation.dropFirst()) {
                            let c = screen(fixed.0, in: plan.area), d = screen(fixed.1, in: plan.area)
                            check(segmentDistance(a, b, c, d) + 0.000_001 >= required,
                                  "test centerlines retain fixed whitespace around the titles")
                        }
                    }
                }
            }
        }
        let large = CGRect(x: -1100, y: -80, width: 900, height: 480)
        let model = UnifiedCalibration()
        check(model.candidates(for: .movement) == [0.5, 2, 8], "three distance candidates")
        check(model.candidates(for: .speed) == [150, 450, 1350], "three ascending speed candidates")
        check(!model.select(metric: .movement, index: 0), "feedback before complete drawing rejected")
        check(!model.markDrawn(), "completion without a prepared plan rejected")
        check(model.setArea(large), "negative screen origin accepted")
        let plan = try model.makeRound(brushWidth: 2.5, knownMovement: 3)
        check(plan.batches.count == 17, "fixed annotations, dynamic guides, and three batches for five metrics")
        check(plan.paths == plan.batches.flatMap { $0.paths }, "all paths include every batch in drawing order")
        check(plan.paths == plan.annotationPaths + plan.testPaths, "static and dynamic paths are explicitly partitioned")
        check(plan.annotationPaths.count == 8, "only M/#/V/E glyphs without any numerals")
        check(plan.batches[0].isAnnotation && plan.batches.dropFirst().allSatisfy { !$0.isAnnotation },
              "only the fixed glyph batch is an annotation")
        check(plan.batches[0].paths == plan.annotationPaths && plan.batches[1].paths.count == 12,
              "speed endpoint guides live in a separate dynamic batch")
        check(plan.requiredSize.width < 320 && plan.requiredSize.height < 480, "portrait minimum fits a narrow canvas")
        checkAnnotationIsolation(plan)
        let safe = large.insetBy(dx: 16, dy: 16)
        for path in plan.paths {
            check(path.count >= 2, "all calibration strokes have a real drag")
            for point in path { check(safe.contains(screen(point, in: large)), "test paths retain fixed canvas border whitespace") }
        }
        let movementBatches = plan.batches.filter { $0.metric == .movement }
        for (index, batch) in movementBatches.enumerated() {
            check(batch.paths.count == 3, "three repeat movement samples per group")
            check(batch.minimumMovement == model.candidates(for: .movement)[index], "one atomic candidate movement")
            for path in batch.paths {
                check(approximately(length(path, in: large), model.candidates(for: .movement)[index]), "exact candidate movement length")
                check(approximately(path[0].y, path[1].y), "movement samples horizontal")
            }
        }
        for metric in [CalibrationMetric.spacingX, .spacingY] {
            for (index, batch) in plan.batches.filter({ $0.metric == metric }).enumerated() {
                check(batch.paths.count == 2, "one pair per spacing group")
                for pair in 0..<1 {
                    let first = batch.paths[pair * 2], second = batch.paths[pair * 2 + 1]
                    let p = screen(first[0], in: large), q = screen(second[0], in: large)
                    let actual = metric == .spacingX ? abs(q.x - p.x) : abs(q.y - p.y)
                    check(approximately(actual, model.candidates(for: metric)[index]), "exact center-to-center gap in both axes")
                    check(length(first, in: large) >= 3.3, "spacing sample starts with enough true movement")
                    if metric == .spacingX {
                        check(first[0].x == first[1].x, "X spacing uses vertical lines")
                    } else { check(first[0].y == first[1].y, "Y spacing uses horizontal lines") }
                }
            }
        }
        let referenceGuides = plan.batches[1]
        let initialEndings = plan.batches.filter { $0.metric == .ending }
        check(initialEndings.map { $0.releaseDelay! } == [0.12, 0.35, 0.8], "ending hold candidates vary only release delay")
        check(Set(initialEndings.map { $0.speed }).count == 1 && initialEndings.allSatisfy { $0.endExtension == 0 },
              "ending hold samples have one fixed low speed and no extension")
        check(initialEndings.allSatisfy { $0.paths[0] == initialEndings[0].paths[0] || $0.paths[0][0].x == initialEndings[0].paths[0][0].x },
              "ending sample columns align")
        for (index, batch) in plan.batches.filter({ $0.metric == .speed }).enumerated() {
            check(batch.speed == model.candidates(for: .speed)[index], "speed candidate preserved without clamping")
            check(batch.paths.count == 1 && length(batch.paths[0], in: large) >= 120, "speed test uses a long horizontal sample")
            let path = batch.paths[0]
            for end in path {
                let guides = referenceGuides.paths.filter { guide in
                    guard guide.count == 2 else { return false }
                    return approximately(guide[0].x, end.x) && approximately(guide[1].x, end.x)
                        && guide[0].y < end.y && guide[1].y > end.y
                }
                check(!guides.isEmpty, "slow vertical endpoint guide aligns with each speed sample end")
            }
            check(referenceGuides.speed < batch.speed, "reference markers slower than initial candidate test")
        }
        check(model.markDrawn(), "complete combined plan unlocks simultaneous feedback")
        check(!model.markDrawn(), "duplicate completion rejected")
        check(!model.submitFeedback(), "partial feedback never updates any bracket")
        check(model.bounds(for: .movement) == 0...8, "rejected submission is atomic")
        check(model.select(metric: .movement, index: 1), "independent movement group accepted")
        check(model.select(metric: .spacingX, index: 2), "independent X group accepted")
        check(model.select(metric: .spacingY, index: 0), "independent Y group accepted")
        check(model.select(metric: .speed, index: 1), "fastest complete speed group accepted")
        check(model.select(metric: .ending, index: 1), "shortest complete ending hold group accepted")
        check(model.submitFeedback(), "all four submitted together")
        check(model.bounds(for: .movement) == 0.5...2 && model.bounds(for: .spacingX) == 2...8,
              "distance brackets choose shorter neighbor and visible upper")
        check(model.bounds(for: .spacingY) == 0...0.5, "smallest clear distance keeps zero lower bound")
        check(model.bounds(for: .speed) == 450...1350, "speed bracket starts at fastest confirmed complete")
        let result = model.results!
        check(result.movement == 2.25 && result.spacingX == 8.8 && result.spacingY == 0.75,
              "distance results add conservative margin")
        check(result.speed == 405, "adopted speed leaves ten percent margin")
        check(result.releaseDelay == 0.35 && result.endExtension == 0, "successful hold uses exact confirmed delay and no extension")
        check(!model.submitFeedback(), "same complete plan cannot submit twice")
        check(model.refine(), "user can refine after early adoption is available")
        check(model.round == 2 && !model.hasDrawn && model.selections.isEmpty, "next combined round clears all row selections")
        check(model.candidates(for: .movement) == [1, 1.5, 2], "distance refinements use thirds")
        check(model.candidates(for: .speed) == [750, 1050, 1350], "speed refinements use thirds")
        check(model.results?.speed == 405, "last confirmed speed preserved before new samples run")
        let refinedPlan = try model.makeRound(brushWidth: 2.5, knownMovement: 3)
        check(refinedPlan.annotationPaths == plan.annotationPaths && refinedPlan.annotationSignature == plan.annotationSignature,
              "normal refinement keeps fixed glyphs and anchors exactly stable")
        check(refinedPlan.batches.filter { $0.metric == .movement || $0.metric == .spacingX || $0.metric == .spacingY || $0.metric == .speed }.allSatisfy { $0.releaseDelay == 0.35 },
              "other tests reuse the confirmed hold policy")
        check(!model.refine(), "cannot silently advance an undrawn round")

        let portrait = UnifiedCalibration()
        _ = portrait.setArea(CGRect(x: -500, y: 180, width: 300, height: 550))
        let portraitPlan = try portrait.makeRound(brushWidth: 2.5, knownMovement: 3)
        checkAnnotationIsolation(portraitPlan)
        let metricFirst = CalibrationMetric.allCases.map { metric -> CGPoint in
            let points = portraitPlan.batches.first { $0.metric == metric }!.paths.flatMap { $0 }
            return CGPoint(x: points.reduce(0) { $0 + $1.x } / Double(points.count),
                           y: points.reduce(0) { $0 + $1.y } / Double(points.count))
        }
        check(approximately(metricFirst[0].y, metricFirst[1].y) && approximately(metricFirst[1].y, metricFirst[2].y) && approximately(metricFirst[3].y, metricFirst[4].y),
              "M/# upper rows and V/E lower rows are aligned")
        check(metricFirst[3].y > metricFirst[0].y && metricFirst[4].y > metricFirst[1].y,
              "V and E occupy the lower band")
        check(metricFirst[0].x < metricFirst[1].x && metricFirst[3].x < metricFirst[4].x,
              "M/V on the left and #/E on the right")
        _ = portrait.markDrawn()
        for metric in CalibrationMetric.allCases { _ = portrait.select(metric: metric, index: nil) }
        check(portrait.refine(), "portrait canvas can expand after no clear samples")
        let portraitExpanded = try portrait.makeRound(brushWidth: 2.5, knownMovement: 3)
        check(portraitExpanded.annotationSignature == portraitPlan.annotationSignature,
              "distance expansion does not move portrait annotations")
        checkAnnotationIsolation(portraitExpanded)
        _ = portrait.markDrawn()
        for metric in CalibrationMetric.allCases { _ = portrait.select(metric: metric, index: nil) }
        _ = portrait.refine()
        do { _ = try portrait.makeRound(brushWidth: 2.5, knownMovement: 3); check(false, "oversized candidate should require wider canvas") }
        catch { check(error.localizedDescription.contains("至少"), "oversized candidates report required canvas rather than moving anchors") }

        let adoptedMovement = UnifiedCalibration()
        _ = adoptedMovement.setArea(CGRect(x: 20, y: 20, width: 900, height: 650))
        let beforeAdoption = try adoptedMovement.makeRound(brushWidth: 2.5, knownMovement: 12)
        _ = adoptedMovement.markDrawn()
        for metric in CalibrationMetric.allCases { _ = adoptedMovement.select(metric: metric, index: 1) }
        _ = adoptedMovement.refine()
        adoptedMovement.acknowledgeAppliedMovement(2.25)
        let afterAdoption = try adoptedMovement.makeRound(brushWidth: 2.5, knownMovement: 2.25)
        check(beforeAdoption.annotationSignature == afterAdoption.annotationSignature,
              "adopting a smaller movement keeps the original larger fixed glyphs")
        checkAnnotationIsolation(afterAdoption)

        let repeatedFeedback = UnifiedCalibration()
        _ = repeatedFeedback.setArea(large)
        _ = try repeatedFeedback.makeRound(brushWidth: 2.5, knownMovement: 3)
        _ = repeatedFeedback.markDrawn()
        for metric in CalibrationMetric.allCases { _ = repeatedFeedback.select(metric: metric, index: 2) }
        _ = repeatedFeedback.submitFeedback()
        _ = repeatedFeedback.repeatRound()
        _ = try repeatedFeedback.makeRound(brushWidth: 2.5, knownMovement: 3)
        _ = repeatedFeedback.markDrawn()
        for metric in CalibrationMetric.allCases { _ = repeatedFeedback.select(metric: metric, index: 0) }
        check(repeatedFeedback.submitFeedback() && repeatedFeedback.bounds(for: .movement) == 0...0.5,
              "repeating a submitted round keeps that round's original lower boundary")

        let none = UnifiedCalibration()
        _ = none.setArea(large)
        _ = try none.makeRound(brushWidth: 2.5, knownMovement: 3)
        _ = none.markDrawn()
        for metric in CalibrationMetric.allCases { check(none.select(metric: metric, index: nil), "explicit none feedback accepted") }
        check(none.refine(), "all-none feedback adjusts all ranges together")
        check(none.bounds(for: .movement) == 8...16, "no clear distance expands range")
        check(none.bounds(for: .speed) == 0...150 && none.candidates(for: .speed) == [50, 100, 150],
              "no complete speed lowers tested interval")
        check(none.results == nil, "no unobserved adopted results invented")
        check(none.endingMode == .extension && none.candidates(for: .ending) == [0.5, 2, 8], "all hold failures automatically switch to extension candidates")

        let faster = UnifiedCalibration()
        _ = faster.setArea(large)
        _ = try faster.makeRound(brushWidth: 2.5, knownMovement: 3)
        _ = faster.markDrawn()
        for metric in CalibrationMetric.allCases { _ = faster.select(metric: metric, index: 2) }
        check(faster.refine(), "all speeds complete permits higher-speed next round")
        check(faster.bounds(for: .speed) == 1350...4050 && faster.confirmedValue(for: .speed) == 1350,
              "higher speed bracket retains actual verified speed")
        _ = try faster.makeRound(brushWidth: 2.5, knownMovement: 3)
        _ = faster.markDrawn()
        for metric in [CalibrationMetric.movement, .spacingX, .spacingY, .ending] { _ = faster.select(metric: metric, index: 2) }
        _ = faster.select(metric: .speed, index: nil)
        check(faster.refine() && faster.confirmedValue(for: .speed) == 1350,
              "new faster candidates can all fail without losing lower verified complete speed")
        check(faster.expandRanges(), "manual expansion allowed")
        check(faster.confirmedValue(for: .speed) == 1350 && faster.results != nil, "manual expansion keeps verified results")

        let endless = UnifiedCalibration()
        _ = endless.setArea(large)
        for iteration in 0..<24 {
            _ = try endless.makeRound(brushWidth: 2.5, knownMovement: 3)
            check(endless.markDrawn(), "long refinement round fully completes")
            for metric in CalibrationMetric.allCases {
                _ = endless.select(metric: metric, index: 0)
            }
            check(endless.refine(), "no fixed round or quarter-point finish")
            check(endless.round == iteration + 2, "every requested refinement enters one round")
        }
        check(endless.candidates(for: .movement).last! < 0.000_000_001, "sub-nanopoint candidate supported without imposed tolerance")
        check(endless.results != nil, "confirmed adoption remains available after many rounds")
        let saved = endless.candidates(for: .movement)
        _ = endless.repeatRound()
        check(endless.candidates(for: .movement) == saved, "repeat does not move any search boundary")
        _ = endless.setArea(CGRect(x: 0, y: 0, width: 1000, height: 500))
        check(endless.candidates(for: .movement) == saved && endless.results != nil, "area reselection preserves confirmed calibration")
        endless.retest()
        check(endless.round == 1 && endless.results == nil && endless.area != nil, "full retest resets results and keeps area")

        func prepare(_ calibration: UnifiedCalibration, delay: Double = 0.12) throws -> UnifiedCalibrationRound {
            let result = try calibration.makeRound(brushWidth: 2.5, knownMovement: 3, releaseDelay: delay)
            check(calibration.markDrawn(), "ending test plan fully completes")
            return result
        }
        func selectOthers(_ calibration: UnifiedCalibration) {
            for metric in [CalibrationMetric.movement, .spacingX, .spacingY, .speed] {
                check(calibration.select(metric: metric, index: 1), "select independent non-ending feedback")
            }
        }
        let endingFallback = UnifiedCalibration()
        _ = endingFallback.setArea(large)
        let beforeFallback = try prepare(endingFallback, delay: 0.2)
        selectOthers(endingFallback)
        _ = endingFallback.select(metric: .ending, index: nil)
        check(endingFallback.refine(), "all hold failures enter an extension round")
        let fallbackPlan = try endingFallback.makeRound(brushWidth: 2.5, knownMovement: 3, releaseDelay: 0.2)
        check(fallbackPlan.annotationSignature == beforeFallback.annotationSignature, "mode transition leaves fixed panel titles in place")
        let extensionBatches = fallbackPlan.batches.filter { $0.metric == .ending }
        check(extensionBatches.map { $0.endExtension } == [0.5, 2, 8], "three extension distances are exact")
        check(extensionBatches.allSatisfy { $0.releaseDelay == 0.2 && $0.speed == 60 },
              "unsuccessful .8-second hold is never forced into extension testing")
        check(fallbackPlan.actualTestPaths == fallbackPlan.batches.filter { !$0.isAnnotation }.flatMap { $0.compensatedPaths(in: large) },
              "actual cleanup paths include all transmitted extension tails")
        for batch in extensionBatches {
            let original = batch.paths[0], actual = batch.compensatedPaths(in: large)[0]
            check(approximately(length(actual, in: large) - length(original, in: large), batch.endExtension),
                  "extension is measured in real screen points even at negative origin")
        }
        checkAnnotationIsolation(fallbackPlan)
        check(endingFallback.markDrawn(), "extension round completes")
        selectOthers(endingFallback)
        _ = endingFallback.select(metric: .ending, index: 1)
        check(endingFallback.submitFeedback(), "complete not-overrun extension selection accepted")
        check(endingFallback.results?.endExtension == 2 && endingFallback.results?.releaseDelay == 0.2,
              "extension result has no positive distance margin")
        _ = endingFallback.refine()
        let compensatedPlan = try endingFallback.makeRound(brushWidth: 2.5, knownMovement: 3, releaseDelay: 0.2)
        check(compensatedPlan.batches.filter { $0.metric == .movement }.allSatisfy { $0.endExtension == 0 },
              "M keeps exact test displacement even when ending compensation was confirmed")
        check(compensatedPlan.batches.filter { $0.metric == .spacingX || $0.metric == .spacingY || $0.metric == .speed }.allSatisfy { $0.endExtension == 2 },
              "spacing and body speed reuse the confirmed ending policy")
        checkAnnotationIsolation(compensatedPlan)
        check(endingFallback.markDrawn(), "refined compensated round completes")
        selectOthers(endingFallback)
        check(endingFallback.selectEndingAllOverrun(), "extension all-overrun feedback supported")
        let previousSmallest = endingFallback.candidates(for: .ending)[0]
        check(endingFallback.refine() && endingFallback.candidates(for: .ending).last! == previousSmallest,
              "all overrun narrows toward zero rather than increasing extension")
        _ = try prepare(endingFallback, delay: 0.2)
        selectOthers(endingFallback)
        check(endingFallback.selectNoEndingCompensation(), "explicit zero ending feedback accepted")
        check(endingFallback.submitFeedback() && endingFallback.results?.endExtension == 0 && endingFallback.results?.releaseDelay == 0.2,
              "zero compensation keeps base release delay and exact zero extension")
        check(endingFallback.endingUsesZero, "explicit zero is distinguishable from untested ending")

        let acknowledged = UnifiedCalibration()
        _ = acknowledged.setArea(large)
        _ = try prepare(acknowledged)
        selectOthers(acknowledged)
        _ = acknowledged.select(metric: .ending, index: 1)
        _ = acknowledged.refine()
        acknowledged.acknowledgeAppliedEnding(releaseDelay: 0.35, endExtension: 0)
        let acknowledgedRound = acknowledged.round
        _ = try acknowledged.makeRound(brushWidth: 2.5, knownMovement: 3, releaseDelay: 0.35)
        check(acknowledged.round == acknowledgedRound && acknowledged.results?.releaseDelay == 0.35,
              "own adopted release delay does not reset confirmed calibration")
        _ = acknowledged.repeatRound()
        _ = try acknowledged.makeRound(brushWidth: 2.5, knownMovement: 3, releaseDelay: 0.4)
        check(acknowledged.round == 1 && acknowledged.results == nil, "external release-delay change resets incompatible observations")
        check(!acknowledged.selectEndingAllOverrun(), "overrun feedback before drawing rejected")
        _ = acknowledged.setEndingMode(.extension)
        check(acknowledged.endingMode == .extension && acknowledged.candidates(for: .ending) == [0.5, 2, 8],
              "manual ending mode switch initializes only its own search")
        let compatibleResult = UnifiedCalibrationResult(movement: 2, spacingX: 3, spacingY: 4, speed: 500)
        check(compatibleResult.releaseDelay == 0.12 && compatibleResult.endExtension == 0, "old result initializers retain defaults")

        let verified = UnifiedCalibration()
        _ = verified.setArea(CGRect(x: 50, y: 20, width: 300, height: 550))
        _ = try prepare(verified, delay: 0.2)
        selectOthers(verified)
        _ = verified.select(metric: .ending, index: 1)
        _ = verified.submitFeedback()
        check(!verified.endingMatchesAdoptedSpeed, "slow ending diagnosis is not proof for the selected faster speed")
        let speedCandidates = verified.candidates(for: .speed)
        let intendedSpeed = verified.results!.speed
        check(verified.setEndingTestSpeed(intendedSpeed), "ending verification can use exactly the adopted V speed")
        check(verified.candidates(for: .speed) == speedCandidates && verified.results == nil,
              "verification resets only ending observations and preserves V candidates")
        let verifiedPlan = try verified.makeRound(brushWidth: 2.5, knownMovement: 3, releaseDelay: 0.2)
        check(verifiedPlan.batches.filter { $0.metric == .ending }.allSatisfy { $0.speed == intendedSpeed },
              "every ending candidate is physically drawn at the adopted speed")
        _ = verified.markDrawn(); selectOthers(verified)
        _ = verified.select(metric: .ending, index: 1); _ = verified.submitFeedback()
        check(verified.endingMatchesAdoptedSpeed, "same V result and a new E confirmation allow adoption")
        _ = verified.repeatRound()
        _ = try prepare(verified, delay: 0.2)
        selectOthers(verified)
        _ = verified.select(metric: .speed, index: 2)
        _ = verified.select(metric: .ending, index: 1); _ = verified.submitFeedback()
        check(!verified.endingMatchesAdoptedSpeed, "changing chosen V speed requires new E verification")
        check(!verified.setEndingTestSpeed(.nan) && !verified.setEndingTestSpeed(0), "invalid ending verification speeds rejected")

        let direct = UnifiedCalibration()
        _ = direct.setArea(large)
        _ = try direct.makeRound(brushWidth: 2.5, knownMovement: 3)
        check(direct.resultForApplication() == nil && !direct.hasDrawn && !direct.feedbackSubmitted,
              "prepared but unfinished first round cannot be adopted or marked complete")
        check(direct.message.contains("完整绘制"), "unfinished confirmation explains the missing complete round")
        check(direct.markDrawn(), "failed early confirmation preserves the prepared drawing state")
        _ = direct.select(metric: .movement, index: 1)
        check(direct.resultForApplication() == nil && !direct.feedbackSubmitted,
              "partial current feedback cannot be adopted or submitted")
        check(direct.message.contains("请选择") && direct.results == nil && direct.bounds(for: .movement) == 0...8,
              "partial confirmation explains missing selections and updates no bracket")
        selectOthers(direct)
        _ = direct.select(metric: .ending, index: 1)
        let directCandidates = CalibrationMetric.allCases.map { direct.candidates(for: $0) }
        let directSelections = direct.selections
        let directRound = direct.round
        let directESpeed = direct.endingTestSpeed
        let adopted = direct.resultForApplication()
        check(adopted?.movement == 2.25 && adopted?.spacingX == 2.25 && adopted?.spacingY == 2.25
              && adopted?.speed == 405 && adopted?.releaseDelay == 0.35 && adopted?.endExtension == 0,
              "first completed round confirmation returns its exact selected results with normal margins")
        check(direct.feedbackSubmitted && direct.hasDrawn && direct.round == directRound,
              "confirmation submits feedback while preserving completed drawing and round number")
        check(direct.endingTestSpeed == directESpeed && !direct.endingMatchesAdoptedSpeed,
              "confirmation accepts selected E without automatically changing its test speed")
        check(direct.confirmedValue(for: .ending) == 0.35 && direct.selections == directSelections
              && CalibrationMetric.allCases.map({ direct.candidates(for: $0) }) == directCandidates,
              "confirmation preserves E observation, selections, and all drawn candidates")
        do { _ = try direct.makeRound(brushWidth: 2.5, knownMovement: 3); check(false, "confirmation must not prepare another round") }
        catch { check(error is UnifiedCalibrationError, "completed round still rejects a new drawing after confirmation") }
        let adoptedBounds = CalibrationMetric.allCases.map { direct.bounds(for: $0) }
        let confirmationMessage = direct.message
        let repeatedResult = direct.resultForApplication()
        check(repeatedResult?.speed == adopted?.speed && repeatedResult?.releaseDelay == adopted?.releaseDelay,
              "repeated confirmation returns the existing result")
        check(direct.message == confirmationMessage && direct.round == directRound && direct.feedbackSubmitted
              && CalibrationMetric.allCases.map({ direct.bounds(for: $0) }) == adoptedBounds,
              "repeated confirmation does not submit twice, refine bounds, or advance the round")
        check(direct.refine(), "refinement remains available as a separate explicit action")
        let historyRound = direct.round
        _ = try direct.makeRound(brushWidth: 2.5, knownMovement: 3)
        let historicalResult = direct.resultForApplication()
        check(historicalResult?.speed == 405 && historicalResult?.releaseDelay == 0.35
              && direct.round == historyRound && !direct.hasDrawn && !direct.feedbackSubmitted,
              "a previously confirmed complete result can end an unfinished later round")
        check(direct.markDrawn(), "historical adoption does not invalidate later prepared paths")
        _ = direct.select(metric: .movement, index: 0)
        check(direct.resultForApplication() == nil && !direct.feedbackSubmitted,
              "a fully drawn later round with partial feedback must finish its feedback before adoption")

        for missingMetric in [CalibrationMetric.movement, .speed, .ending] {
            let incomplete = UnifiedCalibration()
            _ = incomplete.setArea(large)
            _ = try prepare(incomplete)
            for metric in CalibrationMetric.allCases {
                _ = incomplete.select(metric: metric, index: metric == missingMetric ? nil : 1)
            }
            let missingRound = incomplete.round
            check(incomplete.resultForApplication() == nil && incomplete.feedbackSubmitted && incomplete.results == nil,
                  "explicit all-failed feedback cannot manufacture missing \(missingMetric.symbol) results")
            check(incomplete.message.contains("暂时不能结束") && incomplete.round == missingRound
                  && incomplete.hasDrawn && incomplete.endingTestSpeed == 60,
                  "missing qualified result is explained without triggering refinement or ending retest")
        }

        let invalid = UnifiedCalibration()
        check(!invalid.setArea(CGRect(x: Double.nan, y: 0, width: 700, height: 300)), "invalid area rejected")
        _ = invalid.setArea(CGRect(x: 0, y: 0, width: 100, height: 100))
        do { _ = try invalid.makeRound(brushWidth: 2.5, knownMovement: 3); check(false, "undersized area should throw") }
        catch { check(error.localizedDescription.contains("至少"), "undersized area reports concrete required dimensions") }
        check(!invalid.markDrawn(), "invalid geometry cannot unlock feedback")
        _ = invalid.setArea(large)
        do { _ = try invalid.makeRound(brushWidth: .nan, knownMovement: 3); check(false, "invalid brush should throw") }
        catch { check(true, "invalid brush rejected") }
        _ = try invalid.makeRound(brushWidth: 2.5, knownMovement: 3)
        _ = invalid.markDrawn()
        for metric in CalibrationMetric.allCases { _ = invalid.select(metric: metric, index: 1) }
        _ = invalid.refine()
        _ = try invalid.makeRound(brushWidth: 4, knownMovement: 3)
        check(invalid.round == 1 && invalid.results == nil, "changed actual brush resets incompatible observations")
        check(UnifiedCalibration.format(0.000_000_01) != "0", "tiny real candidate never labels as zero")
        print("UnifiedCalibrationChecks: \(checks) checks passed; no mouse events posted.")
    }
}
