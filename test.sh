#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")" && pwd)"
task_tests=(
  AppModelChecks CalibrationAutomationChecks CalibrationChecks CalibrationCleanupChecks
  CanvasMetricsChecks EngineActionChecks EngineChecks EngineProfileChecks EngineSpeedChecks
  EngineTargetChecks EngineTimingChecks FillGeometryChecks GeometryChecks HalftoneGeometryChecks
  ImageAdjustmentModelChecks ImageToneChecks OutlineQualityChecks PreviewGenerationChecks
  ProcessorChecks ProcessorPhysicalChecks ScreenPointPickerChecks SpacingCalibrationChecks
  UnifiedCalibrationChecks UnifiedCalibrationFlowChecks
)

usage() {
  printf '用法：./test.sh [测试名称 ...]\n'
  printf '不传参数或使用 --all：运行全部测试。--list：列出测试。\n'
  printf '示例：./test.sh EngineTargetChecks EngineSpeedChecks ImageToneChecks\n'
  printf '可选：SCREEN_SKETCH_TEST_IMAGE=/绝对路径/图片.png ./test.sh PreviewGenerationChecks\n'
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --list) printf '%s\n' "${task_tests[@]}"; exit 0 ;;
  --all)
    if [[ $# -ne 1 ]]; then usage >&2; exit 2; fi
    set -- "${task_tests[@]}"
    ;;
  '') set -- "${task_tests[@]}" ;;
esac

# 先验证所有名称，避免拼写错误时运行一部分测试后才失败。
for task_name in "$@"; do
  task_found=false
  for task_known in "${task_tests[@]}"; do
    if [[ "$task_name" == "$task_known" ]]; then task_found=true; break; fi
  done
  if [[ "$task_found" != true ]]; then
    printf '未知测试：%s；使用 ./test.sh --list 查看可用名称。\n' "$task_name" >&2
    exit 2
  fi
done
if [[ "$(uname -s)" != Darwin ]]; then
  printf '这些测试依赖 macOS 14+ 的 AppKit、Quartz 和 Swift 工具链。\n' >&2
  exit 1
fi

task_output="$task_root/.build/tests"
mkdir -p "$task_output/module-cache"
task_processor=(ImageProcessor SkeletonTracing BezierFitter FillPlanner)
task_app=(App DrawingEngine ImageProcessor SkeletonTracing BezierFitter FillPlanner
  ScreenRegionPicker MovementCalibration SpacingCalibration CanvasMetrics ScreenPointPicker
  CalibrationCleanup CalibrationAutomation UnifiedCalibration)

for task_name in "$@"; do
  task_flags=(-D ENGINE_TESTS)
  case "$task_name" in
    AppModelChecks|ImageAdjustmentModelChecks|PreviewGenerationChecks)
      task_sources=("${task_app[@]}"); task_flags+=(-D VIEW_RENDERER) ;;
    Engine*Checks|GeometryChecks) task_sources=(DrawingEngine) ;;
    FillGeometryChecks|HalftoneGeometryChecks|ImageToneChecks|OutlineQualityChecks|ProcessorChecks|ProcessorPhysicalChecks)
      task_sources=("${task_processor[@]}") ;;
    CalibrationChecks) task_sources=(MovementCalibration) ;;
    SpacingCalibrationChecks) task_sources=(SpacingCalibration) ;;
    CanvasMetricsChecks) task_sources=(CanvasMetrics) ;;
    ScreenPointPickerChecks) task_sources=(ScreenPointPicker) ;;
    CalibrationCleanupChecks)
      task_sources=(DrawingEngine CalibrationCleanup MovementCalibration SpacingCalibration) ;;
    CalibrationAutomationChecks)
      task_sources=(DrawingEngine CalibrationCleanup CalibrationAutomation MovementCalibration SpacingCalibration) ;;
    UnifiedCalibrationChecks) task_sources=(UnifiedCalibration) ;;
    UnifiedCalibrationFlowChecks)
      task_sources=(DrawingEngine CalibrationCleanup CalibrationAutomation UnifiedCalibration) ;;
  esac
  task_inputs=()
  for task_source in "${task_sources[@]}"; do
    task_inputs+=("$task_root/Sources/$task_source.swift")
  done
  printf '\n编译并运行 %s\n' "$task_name"
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$task_output/module-cache" \
    "${task_flags[@]}" "${task_inputs[@]}" "$task_root/Tests/$task_name.swift" \
    -o "$task_output/$task_name"
  "$task_output/$task_name"
done
printf '\n全部选定测试通过（%s 项）。\n' "$#"
