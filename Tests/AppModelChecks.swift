import Foundation
import Combine

/// Uses the real calibration action and UI setter, with isolated preferences and no windows/input.
@main @MainActor struct AppModelChecks {
    static func main() async throws {
        let suite = "com.wangyifang.screensketch.regression." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func require(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }

        // 升级前保存的橡皮尺寸不再参与应用或校准。
        preferences.set(1000.0, forKey: "eraserWidth")
        let model = AppModel(preferences: preferences, showsApplicationUI: false)
        require(model.selectedMode == .halftone, "adding solid fill preserves the default photo mode")
        require(model.autoMinimizeOnRun, "automatic minimization is enabled for new users")
        model.autoMinimizeOnRun = false
        require(preferences.object(forKey: "autoMinimizeOnRun") as? Bool == false,
                "unchecked window preference persists")
        let safeArea = CGRect(x: 100, y: 100, width: 540, height: 420)
        _ = model.calibration.setArea(safeArea)
        let initialPaths = model.calibration.numberedPaths(brushWidth: model.brushWidth)
        let initialFootprint = CalibrationFootprint(paths: initialPaths, area: safeArea, brushWidth: model.brushWidth, targetPID: 1)
        require(!initialPaths.isEmpty, "calibration paths use actual pen width")
        require(try CalibrationCleanup.replay(footprint: initialFootprint) == initialPaths,
                "legacy eraser size does not prevent replay of recorded paths")
        model.calibration.retest()
        model.autoClearCalibration = false
        require(preferences.object(forKey: "autoClearCalibration") as? Bool == false, "cleanup preference persisted")
        model.autoClearCalibration = true
        var publications = [Double]()
        let subscription = model.$minimumMovement.dropFirst().sink { publications.append($0) }
        require(model.setMinimumMovement(4.4), "valid value accepted")
        require(model.minimumMovement == 4.4 && model.engine.minimumMovement == 4.4, "UI value and engine stay in sync")
        require(publications == [4.4], "one change emits exactly one publication, without setter recursion")
        require(preferences.double(forKey: "minimumMovement") == 4.4, "setting persisted")
        _ = model.setMinimumMovement(4.4)
        require(publications == [4.4], "reapplying same value cannot recurse or emit again")

        // Reproduce the reported button path: finish calibration -> AppModel.applyCalibration.
        let calibration = model.calibration
        _ = calibration.setArea(CGRect(x: 100, y: 100, width: 420, height: 260))
        require(!calibration.numberedPaths(brushWidth: 2.5).isEmpty, "numbered test plan prepared")
        require(calibration.markDrawn(), "completed round accepts feedback")
        require(calibration.selectShortestVisible(index: 3), "visible group confirmed")
        require(calibration.finishWithCurrentResult(), "early finish allowed")
        let adopted = calibration.suggestedMinimum!
        model.applyCalibration(adopted)
        require(model.minimumMovement == adopted && model.engine.minimumMovement == adopted, "actual calibration action returns and applies its result")
        require(preferences.string(forKey: "calibrationNote") == model.calibrationNote, "calibration note saved")

        for i in 1...100 {
            model.applyCalibration(Double(i) / 4)
            require(model.minimumMovement == Double(i) / 4, "repeated real calibration action returns normally")
        }
        let beforeInvalid = model.minimumMovement
        require(!model.setMinimumMovement(.nan), "NaN UI value rejected")
        require(!model.setMinimumMovement(.infinity), "infinite UI value rejected")
        require(model.minimumMovement == beforeInvalid, "invalid values preserve last good threshold")
        model.applyCalibration(.nan)
        require(model.minimumMovement == beforeInvalid && model.error != nil, "invalid calibration cannot overwrite its valid result")
        _ = model.setMinimumMovement(-3)
        require(model.minimumMovement == 0 && model.engine.minimumMovement == 0, "negative manual value safely clamps once")
        _ = model.setMinimumMovement(126.5)
        require(model.minimumMovement == 126.5, "large measured threshold not silently reduced")

        require(model.setBrushWidth(1.75), "actual pen width accepted")
        require(!model.setBrushWidth(.nan) && !model.setBrushWidth(0), "invalid pen width rejected")
        require(model.brushWidth == 1.75, "invalid pen width preserves valid value")
        require(model.setMinimumSpacing(3.2, axis: .x), "horizontal spacing accepted")
        require(model.setMinimumSpacing(5.1, axis: .y), "vertical spacing accepted")
        require(!model.setMinimumSpacing(.infinity, axis: .x), "infinite spacing rejected")
        require(!model.setMinimumSpacing(-1, axis: .y), "negative spacing rejected")
        require(model.minimumSpacingX == 3.2 && model.minimumSpacingY == 5.1, "axes stay independent")
        model.spacingCalibration.axis = .x
        _ = model.spacingCalibration.setArea(CGRect(x: 100, y: 100, width: 540, height: 420))
        require(!model.spacingCalibration.numberedPaths(brushWidth: 1.75, minimumMovement: 3).isEmpty, "actual numbered spacing plan prepared")
        require(model.spacingCalibration.markDrawn(), "completed spacing round accepts feedback")
        require(model.spacingCalibration.selectShortestVisible(index: 3), "clear pair group confirmed")
        require(model.spacingCalibration.finishWithCurrentResult(), "spacing early finish allowed")
        let adoptedSpacing = model.spacingCalibration.suggestedMinimum!
        model.applySpacingCalibration(adoptedSpacing)
        require(model.minimumSpacingX == adoptedSpacing && model.minimumSpacingY == 5.1, "spacing feedback adoption updates only measured axis")
        model.applySpacingCalibration(4.25)
        require(model.minimumSpacingX == 4.25 && model.minimumSpacingY == 5.1, "real apply-spacing action updates just measured axis")
        model.region = CGRect(x: 100, y: 100, width: 800, height: 600)
        model.scheduleProcessing()

        let restored = AppModel(preferences: preferences, showsApplicationUI: false)
        require(!restored.autoMinimizeOnRun, "unchecked window preference restores across launches")
        restored.autoMinimizeOnRun = true
        require(preferences.object(forKey: "autoMinimizeOnRun") as? Bool == true,
                "window preference can be enabled again")
        require(restored.autoClearCalibration, "cleanup settings restore without eraser geometry")
        require(restored.minimumMovement == 126.5 && restored.engine.minimumMovement == 126.5, "saved threshold restores without recursive initialization")
        require(restored.brushWidth == 1.75 && restored.minimumSpacingX == 4.25 && restored.minimumSpacingY == 5.1, "physical settings restore")
        let deadline = Date().addingTimeInterval(10)
        while (model.busy || restored.busy) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        require(!model.busy && !restored.busy && model.plans.count == DrawingMode.allCases.count && restored.plans.count == DrawingMode.allCases.count, "all mode previews regenerate after calibration")
        require(model.plans.values.allSatisfy { $0.size == CGSize(width: 800, height: 600) && $0.lineWidth == 1.75 && $0.minimumMovement == 126.5 }, "plan geometry stays in screen points")
        model.selectedMode = .solid
        require(model.selectedPlan?.mode == .solid && model.precisionText.contains("按实际笔宽重叠") && model.precisionText.contains("保留白孔"), "solid mode exposes the generated preview and fill precision")
        withExtendedLifetime(subscription) { }
        let joinedSuite = suite + ".joined"
        let joinedPreferences = UserDefaults(suiteName: joinedSuite)!
        defer { joinedPreferences.removePersistentDomain(forName: joinedSuite) }
        joinedPreferences.set([10.0, 20.0], forKey: "penButton")
        joinedPreferences.set([30.0, 40.0], forKey: "eraserButton")
        joinedPreferences.set("shared-main-tools", forKey: "toolTargetIdentity")
        let joined = AppModel(preferences: joinedPreferences, showsApplicationUI: false)
        require(joined.pressDelay == 0.12 && joined.releaseDelay == 0.12, "human-like default stroke holds")
        require(joined.setStrokeDelay(0.18, press: true) && joined.setStrokeDelay(0.14, press: false), "hold settings apply without recursion")
        require(joined.engine.pressDelay == 0.18 && joined.engine.releaseDelay == 0.14, "engine holds match UI")
        require(!joined.setStrokeDelay(.nan, press: true) && !joined.setStrokeDelay(-1, press: false), "invalid delays cannot change valid values")
        joined.region = CGRect(x: 100, y: 100, width: 300, height: 550)
        joined.targetPID = 4321
        joined.targetName = "主画布测试"
        joined.syncUnifiedCanvas()
        require(joined.unifiedCalibration.area == joined.region, "unified calibration inherits the main portrait canvas")
        require(joined.penButton == CGPoint(x: 10, y: 20) && joined.eraserButton == CGPoint(x: 30, y: 40), "unified uses the main shared tool positions")
        _ = try joined.unifiedCalibration.makeRound(brushWidth: joined.brushWidth, knownMovement: joined.minimumMovement, releaseDelay: joined.releaseDelay)
        require(joined.unifiedCalibration.markDrawn(), "joint round unlocks feedback only after completion")
        for metric in CalibrationMetric.allCases { _ = joined.unifiedCalibration.select(metric: metric, index: 1) }
        joined.syncUnifiedCanvas()
        require(joined.unifiedCalibration.hasDrawn && joined.unifiedCalibration.canSubmitFeedback, "reopening the same main canvas preserves current selections")
        let confirmedRound = joined.unifiedCalibration.round
        let endingSpeedBeforeApply = joined.unifiedCalibration.endingTestSpeed
        joined.confirmAndApplyUnifiedCalibration()
        let provisional = joined.unifiedCalibration.results!
        require(joined.error == nil && joined.speed == provisional.speed
                && joined.minimumMovement == provisional.movement
                && joined.minimumSpacingX == provisional.spacingX && joined.minimumSpacingY == provisional.spacingY,
                "real confirm button immediately applies all selected results")
        require(joined.releaseDelay == provisional.releaseDelay && joined.endExtension == provisional.endExtension,
                "confirm preserves the selected ending parameters")
        require(joined.unifiedCalibration.round == confirmedRound
                && joined.unifiedCalibration.endingTestSpeed == endingSpeedBeforeApply
                && joined.unifiedCalibration.feedbackSubmitted && !joined.engine.running && !joined.running,
                "confirm ends without starting drawing, advancing the round or forcing ending retest")
        require(joined.status == "联合校准已结束，结果已应用。"
                && joinedPreferences.double(forKey: "drawingSpeed") == provisional.speed,
                "confirmation reports completion and persists adopted settings")
        joined.confirmAndApplyUnifiedCalibration()
        require(joined.error == nil && joined.unifiedCalibration.round == confirmedRound && !joined.engine.running,
                "repeated confirm is stable and never starts another round")
        require(joined.unifiedCalibration.setEndingTestSpeed(provisional.speed), "ending retested at the intended drawing speed")
        _ = try joined.unifiedCalibration.makeRound(brushWidth: joined.brushWidth, knownMovement: joined.minimumMovement, releaseDelay: joined.releaseDelay)
        require(joined.unifiedCalibration.markDrawn(), "ending speed verification completes")
        for metric in CalibrationMetric.allCases { _ = joined.unifiedCalibration.select(metric: metric, index: 1) }
        require(joined.unifiedCalibration.submitFeedback() && joined.unifiedCalibration.endingMatchesAdoptedSpeed, "same selected V and new E complete verification")
        let combined = joined.unifiedCalibration.results!
        joined.confirmAndApplyUnifiedCalibration()
        require(joined.minimumMovement == combined.movement && joined.minimumSpacingX == combined.spacingX && joined.minimumSpacingY == combined.spacingY && joined.speed == combined.speed, "joint adoption applies all four values")
        require(joined.releaseDelay == combined.releaseDelay && joined.endExtension == combined.endExtension, "joint ending test applies both hold and geometric compensation")
        require(joined.unifiedCalibration.refine(), "joint calibration continues after adoption")
        let continuedRound = joined.unifiedCalibration.round
        _ = try joined.unifiedCalibration.makeRound(brushWidth: joined.brushWidth, knownMovement: joined.minimumMovement, releaseDelay: joined.releaseDelay)
        require(joined.unifiedCalibration.round == continuedRound && joined.unifiedCalibration.results != nil, "adopted movement does not reset retained brackets")
        joined.region = joined.region!.offsetBy(dx: 10, dy: 20)
        joined.syncUnifiedCanvas()
        require(joined.unifiedCalibration.area == joined.region && !joined.unifiedCalibration.hasDrawn, "changed main canvas invalidates drawing and inherits exact Quartz coordinates")
        joined.targetPID = 5678
        joined.syncUnifiedCanvas()
        require(joined.unifiedCalibration.round == 1 && joined.unifiedCalibration.results == nil, "changing the main target resets incompatible calibration results")
        let joinedRestored = AppModel(preferences: joinedPreferences, showsApplicationUI: false)
        require(joinedRestored.pressDelay == 0.18 && joinedRestored.releaseDelay == combined.releaseDelay && joinedRestored.speed == combined.speed && joinedRestored.endExtension == combined.endExtension, "joint speed, holds and compensation restore")
        require(joined.setEndExtension(8), "positive ending compensation accepted")
        require(!joined.setEndExtension(.nan) && !joined.setEndExtension(-1) && joined.endExtension == 8, "invalid ending compensation preserves the last valid value")
        let compensatedDeadline = Date().addingTimeInterval(10)
        while joined.busy && Date() < compensatedDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        require(!joined.busy && joined.plans.count == DrawingMode.allCases.count, "compensation updates all previews and reserves canvas margins")
        for plan in joined.plans.values {
            let base = DrawingEngine.mapPaths(joined.paths(plan), to: joined.region!, brushWidth: joined.brushWidth)
            let actual = DrawingEngine.compensatedPaths(joined.paths(plan), to: joined.region!, brushWidth: joined.brushWidth, endExtension: joined.endExtension)
            require(base.count == actual.count, "compensated formal plan retains all strokes")
            for (path, extended) in zip(base, actual) where path.count > 1 {
                require(abs(hypot(extended.last!.x - path.last!.x, extended.last!.y - path.last!.y) - 8) < 0.000_001, "formal image plan reserves the complete calibrated extension at every endpoint")
            }
        }
        print("PASS movement and spacing adoption / independent axes / UI setters / one publication / invalid values / persistence / screen-point plans / four previews")
    }
}
