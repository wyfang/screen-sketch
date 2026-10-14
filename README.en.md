# ScreenSketch

A local macOS application that converts images into black-and-white strokes and draws them inside a selected screen area using mouse events.

[Full user guide](./使用说明.txt) · [简体中文](./README.md)

## Features

- Four drawing modes: outlines, black-and-white halftones, crosshatched sketches, and solid fills. Previews render the actual planned paths and brush width.
- Exposure, contrast, shadow lift, and a black-and-white threshold for solid fills. Releasing a slider updates both the preview and drawing paths.
- Drag or two-point canvas selection using Quartz screen points, keeping Retina preview pixels separate from mouse travel distances.
- Joint calibration of minimum effective movement, X/Y spacing, movement speed, and stroke-ending hold/extension. Record pen and eraser buttons and replay calibration paths to clean the test area.
- Adjustable drawing speed. Keyboard or manual mouse input pauses foreground drawing; Continue resumes from the paused position.
- New images prioritize the selected mode and publish each completed preview separately. Obsolete processing results cannot replace newer previews.

## Usage

### Build and launch

Requires macOS 14 or later and Apple Command Line Tools or a configured Xcode installation. Running the application does not require Python, Node.js, or an external AI service.

```bash
git clone https://github.com/wyfang/screen-sketch.git
cd screen-sketch
bash build.sh
open ./屏幕绘图器.app
```

If compiler tools are missing, run `xcode-select --install` first. If an unfinished Xcode installation is selected but Command Line Tools are already installed, use:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash build.sh
```

The build produces `屏幕绘图器.app` at the repository root for the current Mac architecture, with an ad hoc local signature. It does not install or replace anything in `/Applications`. The application is not notarized by Apple.

### Draw

1. Import an image, select a black pen in the target canvas, and set its width.
2. Select the actual canvas area and enter the brush's visible width in screen points. Locate the pen and eraser buttons if automatic tool switching is needed.
3. Run joint calibration, select and apply acceptable results, then choose a drawing mode and image adjustments.
4. Allow the application under System Settings → Privacy & Security → Accessibility. Test one stroke before starting the full drawing.

Foreground drawing uses the system pointer and screen coordinates without checking target-process liveness or foreground focus. Keep the canvas and tool positions unchanged. Keyboard input, pointer movement, clicks, or scrolling pause drawing; resuming requires the application's Continue button.

Automatic cleanup uses the target eraser along calibration paths recorded during the current application session. The target canvas's eraser size determines the actual area removed. It does not intentionally clear the entire canvas.

### Tests

```bash
bash test.sh
bash test.sh EngineSpeedChecks EngineTargetChecks
```

Automated tests use an event sink and temporary generated images, without sending drawing events to a real canvas. Test artifacts are stored in `.build` and excluded from version control. Set `SCREEN_SKETCH_TEST_IMAGE` to use your own image for preview checks.

## Notes

Images are processed locally; imported files are not uploaded and no API key is required. Accessibility permission is used to send mouse events and observe pause input. Screen Recording permission is not required.

Background drawing is experimental. It posts mouse events to a target process and does not create a second system pointer. Whether WeChat mini programs, Figma, or browser canvases accept these events depends on the target software; confirm the test stroke first. An unavailable background target pauses drawing with progress preserved, without redirecting events to another process.

Previews simulate planned strokes with a fixed brush width. The target application's smoothing, event handling, antialiasing, and stroke-ending behavior can still produce differences. Visible brush width, calibration, and canvas size determine precision; when path budgets are reached, sampling is reduced across the entire image and reported. Solid fill does not preserve continuous grayscale, and image adjustments cannot recover details already clipped to pure white.

`Sources` contains application code, `Tests` contains regression checks, and `Tools` contains icon generation, preview export, offscreen UI rendering, and an independent test canvas. See the [user guide](./使用说明.txt) for the complete workflow.

## License

This repository is publicly visible. All rights to original code and documentation are reserved; no open-source license is granted. Public access does not grant additional rights. See [LICENSE](./LICENSE).

The project includes MIT-licensed components and adaptations from LingDong-/skeleton-tracing and soswow/fit-curve. Sources, pinned revisions, and modification details are in [NOTICE](./NOTICE); the original license texts are retained in [Resources/ThirdParty](./Resources/ThirdParty). Access to the code does not grant rights to imported images, user data, or third-party assets.
