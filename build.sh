#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_app="$task_root/屏幕绘图器.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -O -parse-as-library \
  "$task_root/Sources/App.swift" "$task_root/Sources/DrawingEngine.swift" \
  "$task_root/Sources/ImageProcessor.swift" "$task_root/Sources/SkeletonTracing.swift" \
  "$task_root/Sources/BezierFitter.swift" "$task_root/Sources/FillPlanner.swift" \
  "$task_root/Sources/ScreenRegionPicker.swift" \
  "$task_root/Sources/MovementCalibration.swift" \
  "$task_root/Sources/SpacingCalibration.swift" "$task_root/Sources/CanvasMetrics.swift" \
  "$task_root/Sources/ScreenPointPicker.swift" "$task_root/Sources/CalibrationCleanup.swift" \
  "$task_root/Sources/CalibrationAutomation.swift" \
  "$task_root/Sources/UnifiedCalibration.swift" \
  -o "$task_app/Contents/MacOS/ScreenSketch" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework JavaScriptCore
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp -R "$task_root/Resources/ThirdParty" "$task_app/Contents/Resources/"
if [[ -f "$task_root/Resources/AppIcon.icns" ]]; then
  cp "$task_root/Resources/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
fi
/usr/bin/codesign --force --deep --sign - --identifier com.wangyifang.screensketch "$task_app"
printf '已生成：%s\n' "$task_app"
