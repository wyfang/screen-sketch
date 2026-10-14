import AppKit
guard CommandLine.arguments.count == 2 else {
    fputs("用法：MakeIcon 输出iconset目录\n", stderr)
    exit(64)
}
let destination = CommandLine.arguments[1]
let icon = NSImage(size: NSSize(width: 1024, height: 1024))
icon.lockFocus()
let bounds = CGRect(x: 30, y: 30, width: 964, height: 964)
NSColor(calibratedRed: 0.15, green: 0.31, blue: 0.26, alpha: 1).setFill()
NSBezierPath(roundedRect: bounds, xRadius: 205, yRadius: 205).fill()
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: CGRect(x: 188, y: 175, width: 648, height: 678), xRadius: 60, yRadius: 60).fill()
let stroke = NSBezierPath()
stroke.move(to: CGPoint(x: 285, y: 365)); stroke.curve(to: CGPoint(x: 500, y: 340), controlPoint1: CGPoint(x: 305, y: 505), controlPoint2: CGPoint(x: 455, y: 230))
stroke.curve(to: CGPoint(x: 714, y: 535), controlPoint1: CGPoint(x: 556, y: 463), controlPoint2: CGPoint(x: 602, y: 333))
stroke.lineWidth = 22; stroke.lineCapStyle = .round
NSColor(calibratedRed: 0.25, green: 0.44, blue: 0.35, alpha: 1).setStroke(); stroke.stroke()
let pencil = NSBezierPath(); pencil.move(to: CGPoint(x: 470, y: 538)); pencil.line(to: CGPoint(x: 677, y: 745)); pencil.line(to: CGPoint(x: 739, y: 683)); pencil.line(to: CGPoint(x: 532, y: 476)); pencil.close()
NSColor(calibratedRed: 0.85, green: 0.62, blue: 0.28, alpha: 1).setFill(); pencil.fill()
let tip = NSBezierPath(); tip.move(to: CGPoint(x: 470, y: 538)); tip.line(to: CGPoint(x: 532, y: 476)); tip.line(to: CGPoint(x: 446, y: 452)); tip.close()
NSColor(calibratedRed: 0.88, green: 0.78, blue: 0.61, alpha: 1).setFill(); tip.fill()
let graphite = NSBezierPath(); graphite.move(to: CGPoint(x: 460, y: 488)); graphite.line(to: CGPoint(x: 483, y: 465)); graphite.line(to: CGPoint(x: 446, y: 452)); graphite.close()
NSColor.darkGray.setFill(); graphite.fill()
icon.unlockFocus()
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    if pixels <= 512 { try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(pixels)x\(pixels).png")) }
    if pixels >= 32 { try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(pixels / 2)x\(pixels / 2)@2x.png")) }
}
