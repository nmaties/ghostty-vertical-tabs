// Draws the app icon and writes Resources/AppIcon.icns plus docs/icon.png.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a 1024 x 1024 canvas, scaled to `size` pixels.
func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Body: the macOS icon grid's rounded square, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x161A24).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x232838), ending: color(0x12151D))!.draw(in: bodyPath, angle: -90)

    // Sidebar: a lighter strip down the left side, clipped to the body.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    color(0xFFFFFF, 0.06).setFill()
    CGRect(x: 100, y: 100, width: 300, height: 824).fill()
    color(0xFFFFFF, 0.10).setFill()
    CGRect(x: 398, y: 100, width: 4, height: 824).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Tabs, top to bottom; the second one is selected.
    let tabX: CGFloat = 156, tabW: CGFloat = 190, tabH: CGFloat = 64
    for (i, top) in [790, 690, 590, 490].enumerated() {
        let rect = CGRect(x: tabX, y: CGFloat(top) - tabH, width: i == 1 ? tabW : tabW - CGFloat(i % 2 == 0 ? 30 : 50), height: tabH)
        (i == 1 ? color(0x7AA2F7) : color(0xFFFFFF, 0.22)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill()
    }

    // Terminal prompt ">_" on the right.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 500, y: 620))
    chevron.line(to: NSPoint(x: 600, y: 540))
    chevron.line(to: NSPoint(x: 500, y: 460))
    chevron.lineWidth = 56
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    color(0x9ECE6A).setStroke()
    chevron.stroke()
    color(0x9ECE6A).setFill()
    NSBezierPath(roundedRect: CGRect(x: 640, y: 432, width: 170, height: 56), xRadius: 28, yRadius: 28).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: base), to: "\(iconset)/icon_\(base)x\(base).png")
    writePNG(drawIcon(size: base * 2), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
try! fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)
writePNG(drawIcon(size: 512), to: "docs/icon.png")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
