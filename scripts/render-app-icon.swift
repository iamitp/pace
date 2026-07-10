import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let icons: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func scaled(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
    value * scale
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func drawArc(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool, width: CGFloat, color strokeColor: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    strokeColor.setStroke()
    path.stroke()
}

func drawIcon(pixels: Int, to url: URL) throws {
    let size = CGFloat(pixels)
    let scale = size / 1024
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "PaceIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let outer = NSBezierPath(
        roundedRect: NSRect(x: scaled(72, scale), y: scaled(72, scale), width: scaled(880, scale), height: scaled(880, scale)),
        xRadius: scaled(214, scale),
        yRadius: scaled(214, scale)
    )
    outer.addClip()
    let gradient = NSGradient(colors: [
        color(0.055, 0.067, 0.082),
        color(0.075, 0.086, 0.105),
        color(0.035, 0.041, 0.052)
    ])!
    gradient.draw(in: rect, angle: -38)

    let glow = NSBezierPath(ovalIn: NSRect(x: scaled(600, scale), y: scaled(610, scale), width: scaled(460, scale), height: scaled(460, scale)))
    color(0.22, 0.78, 0.72, 0.14).setFill()
    glow.fill()

    let base = NSBezierPath(ovalIn: NSRect(x: scaled(206, scale), y: scaled(188, scale), width: scaled(612, scale), height: scaled(612, scale)))
    color(0.10, 0.12, 0.15, 0.72).setFill()
    base.fill()

    let center = NSPoint(x: scaled(512, scale), y: scaled(450, scale))
    drawArc(center: center, radius: scaled(292, scale), start: 205, end: -25, clockwise: true, width: scaled(64, scale), color: color(0.20, 0.23, 0.28))
    drawArc(center: center, radius: scaled(292, scale), start: 205, end: 136, clockwise: true, width: scaled(64, scale), color: color(0.18, 0.78, 0.70))
    drawArc(center: center, radius: scaled(292, scale), start: 132, end: 54, clockwise: true, width: scaled(64, scale), color: color(0.94, 0.73, 0.29))
    drawArc(center: center, radius: scaled(292, scale), start: 50, end: -25, clockwise: true, width: scaled(64, scale), color: color(0.94, 0.33, 0.30))

    for angle in stride(from: 205.0, through: -25.0, by: -38.0) {
        let radians = CGFloat(angle * .pi / 180)
        let tickCenter = NSPoint(
            x: center.x + cos(radians) * scaled(292, scale),
            y: center.y + sin(radians) * scaled(292, scale)
        )
        let tick = NSBezierPath(ovalIn: NSRect(x: tickCenter.x - scaled(9, scale), y: tickCenter.y - scaled(9, scale), width: scaled(18, scale), height: scaled(18, scale)))
        color(1, 1, 1, 0.78).setFill()
        tick.fill()
    }

    let needleAngle = CGFloat.pi / 6
    let needleEnd = NSPoint(
        x: center.x + cos(needleAngle) * scaled(238, scale),
        y: center.y + sin(needleAngle) * scaled(238, scale)
    )
    let needle = NSBezierPath()
    needle.lineWidth = scaled(34, scale)
    needle.lineCapStyle = .round
    needle.move(to: center)
    needle.line(to: needleEnd)
    color(0.97, 0.98, 1.0).setStroke()
    needle.stroke()

    let hubShadow = NSBezierPath(ovalIn: NSRect(x: center.x - scaled(74, scale), y: center.y - scaled(74, scale), width: scaled(148, scale), height: scaled(148, scale)))
    color(0.015, 0.018, 0.024, 0.42).setFill()
    hubShadow.fill()

    let hub = NSBezierPath(ovalIn: NSRect(x: center.x - scaled(58, scale), y: center.y - scaled(58, scale), width: scaled(116, scale), height: scaled(116, scale)))
    color(0.97, 0.98, 1.0).setFill()
    hub.fill()
    let hubCore = NSBezierPath(ovalIn: NSRect(x: center.x - scaled(24, scale), y: center.y - scaled(24, scale), width: scaled(48, scale), height: scaled(48, scale)))
    color(0.055, 0.067, 0.082).setFill()
    hubCore.fill()

    let lowerRail = NSBezierPath(roundedRect: NSRect(x: scaled(298, scale), y: scaled(234, scale), width: scaled(428, scale), height: scaled(42, scale)), xRadius: scaled(21, scale), yRadius: scaled(21, scale))
    color(0.86, 0.89, 0.93, 0.22).setFill()
    lowerRail.fill()

    let highlight = NSBezierPath(roundedRect: NSRect(x: scaled(118, scale), y: scaled(672, scale), width: scaled(788, scale), height: scaled(236, scale)), xRadius: scaled(164, scale), yRadius: scaled(164, scale))
    color(1, 1, 1, 0.05).setFill()
    highlight.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PaceIcon", code: 2)
    }
    try png.write(to: url)
}

for icon in icons {
    try drawIcon(pixels: icon.pixels, to: outputDirectory.appendingPathComponent(icon.name))
}
