import AppKit
import Foundation

// Render App Store artwork with review-safe sample data. This is not a live UI capture.
let productName = "PaceDesk"
let sampleDataLabel = "Rendered App Store artwork | Review-safe sample data"

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "app-store/screenshots/mac")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let canvasWidth = 2880
let canvasHeight = 1800
let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

let palette = (
    ink: color(0.07, 0.08, 0.10),
    panel: color(0.10, 0.12, 0.15),
    panel2: color(0.13, 0.15, 0.19),
    stroke: color(0.80, 0.84, 0.90, 0.16),
    text: color(0.96, 0.97, 0.98),
    muted: color(0.66, 0.70, 0.76),
    teal: color(0.18, 0.78, 0.70),
    amber: color(0.94, 0.72, 0.30),
    coral: color(0.94, 0.34, 0.31),
    blue: color(0.34, 0.58, 0.96),
    green: color(0.36, 0.78, 0.45),
    surface: color(0.93, 0.94, 0.96),
    surface2: color(0.84, 0.87, 0.90)
)

enum TextAlignment {
    case left
    case center
    case right
}

func font(_ size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSFont {
    if mono {
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
    return NSFont.systemFont(ofSize: size, weight: weight)
}

func drawText(
    _ text: String,
    in rect: NSRect,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color textColor: NSColor = palette.text,
    alignment: TextAlignment = .left,
    mono: Bool = false,
    wrap: Bool = false
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }()
    paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font(size, weight: weight, mono: mono),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect, withAttributes: attributes)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        path.lineWidth = lineWidth
        stroke.setStroke()
        path.stroke()
    }
}

func line(from start: NSPoint, to end: NSPoint, width: CGFloat = 2, color: NSColor = palette.stroke) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

func drawArc(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool, width: CGFloat, color strokeColor: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    strokeColor.setStroke()
    path.stroke()
}

func drawGaugeIcon(center: NSPoint, radius: CGFloat, needle: CGFloat) {
    drawArc(center: center, radius: radius, start: 205, end: -25, clockwise: true, width: radius * 0.24, color: color(0.20, 0.23, 0.28))
    drawArc(center: center, radius: radius, start: 205, end: 72, clockwise: true, width: radius * 0.24, color: palette.teal)
    drawArc(center: center, radius: radius, start: 68, end: 16, clockwise: true, width: radius * 0.24, color: palette.amber)
    let angle = CGFloat((205 - (230 * needle)) * .pi / 180)
    let end = NSPoint(x: center.x + cos(angle) * radius * 0.78, y: center.y + sin(angle) * radius * 0.78)
    line(from: center, to: end, width: max(2, radius * 0.13), color: color(0.98, 0.98, 1))
    rounded(NSRect(x: center.x - radius * 0.18, y: center.y - radius * 0.18, width: radius * 0.36, height: radius * 0.36), radius: radius * 0.18, fill: color(0.98, 0.98, 1))
}

func drawDesktop(title: String, selectedMenuIconX: CGFloat = 2290) {
    NSGradient(colors: [
        color(0.94, 0.95, 0.96),
        color(0.85, 0.88, 0.91),
        color(0.79, 0.84, 0.87)
    ])!.draw(in: canvas, angle: -28)

    let accent = NSBezierPath(ovalIn: NSRect(x: -260, y: 880, width: 1200, height: 820))
    color(0.18, 0.78, 0.70, 0.16).setFill()
    accent.fill()
    let accent2 = NSBezierPath(ovalIn: NSRect(x: 2140, y: -160, width: 860, height: 760))
    color(0.94, 0.72, 0.30, 0.14).setFill()
    accent2.fill()

    rounded(NSRect(x: 0, y: 1728, width: 2880, height: 72), radius: 0, fill: color(0.98, 0.98, 0.985, 0.92))
    drawText(productName, in: NSRect(x: 56, y: 1748, width: 170, height: 34), size: 24, weight: .semibold, color: palette.ink)
    drawText("File", in: NSRect(x: 244, y: 1749, width: 70, height: 32), size: 22, color: color(0.22, 0.24, 0.28))
    drawText("View", in: NSRect(x: 324, y: 1749, width: 78, height: 32), size: 22, color: color(0.22, 0.24, 0.28))
    drawText("Window", in: NSRect(x: 412, y: 1749, width: 110, height: 32), size: 22, color: color(0.22, 0.24, 0.28))
    drawText("Tue 17:42", in: NSRect(x: 2590, y: 1749, width: 180, height: 32), size: 22, color: color(0.22, 0.24, 0.28), alignment: .right)

    rounded(NSRect(x: selectedMenuIconX - 18, y: 1741, width: 66, height: 44), radius: 14, fill: color(0.14, 0.16, 0.20, 0.13))
    drawGaugeIcon(center: NSPoint(x: selectedMenuIconX + 15, y: 1762), radius: 15, needle: 0.65)
    drawText(title, in: NSRect(x: 104, y: 90, width: 880, height: 52), size: 32, weight: .semibold, color: color(0.18, 0.20, 0.24))
    drawText(sampleDataLabel, in: NSRect(x: 104, y: 50, width: 920, height: 28), size: 18, weight: .medium, color: color(0.34, 0.37, 0.42))
}

func drawWindow(_ rect: NSRect, title: String, activeTab: String) {
    rounded(rect.offsetBy(dx: 0, dy: -16), radius: 28, fill: color(0.12, 0.13, 0.16, 0.18))
    rounded(rect, radius: 28, fill: palette.panel, stroke: palette.stroke, lineWidth: 2)
    rounded(NSRect(x: rect.minX, y: rect.maxY - 88, width: rect.width, height: 88), radius: 28, fill: color(0.14, 0.16, 0.20))
    rounded(NSRect(x: rect.minX, y: rect.maxY - 118, width: rect.width, height: 52), radius: 0, fill: color(0.14, 0.16, 0.20))

    rounded(NSRect(x: rect.minX + 28, y: rect.maxY - 55, width: 20, height: 20), radius: 10, fill: color(0.96, 0.36, 0.34))
    rounded(NSRect(x: rect.minX + 58, y: rect.maxY - 55, width: 20, height: 20), radius: 10, fill: color(0.96, 0.72, 0.32))
    rounded(NSRect(x: rect.minX + 88, y: rect.maxY - 55, width: 20, height: 20), radius: 10, fill: color(0.40, 0.80, 0.42))
    drawText(title, in: NSRect(x: rect.midX - 170, y: rect.maxY - 62, width: 340, height: 34), size: 24, weight: .semibold, alignment: .center)

    let tabs = ["Now", "Sessions", "System"]
    let tabWidth: CGFloat = 158
    let tabY = rect.maxY - 252
    let startX = rect.minX + 40
    rounded(NSRect(x: startX, y: tabY, width: tabWidth * 3, height: 54), radius: 14, fill: color(0.07, 0.08, 0.10, 0.75), stroke: palette.stroke)
    for (index, tab) in tabs.enumerated() {
        let tabRect = NSRect(x: startX + CGFloat(index) * tabWidth + 6, y: tabY + 6, width: tabWidth - 12, height: 42)
        if tab == activeTab {
            rounded(tabRect, radius: 10, fill: color(0.90, 0.92, 0.96, 0.16))
        }
        drawText(tab, in: NSRect(x: tabRect.minX, y: tabRect.minY + 9, width: tabRect.width, height: 24), size: 19, weight: tab == activeTab ? .semibold : .medium, color: tab == activeTab ? palette.text : palette.muted, alignment: .center)
    }
}

func drawHeader(in rect: NSRect, subtitle: String) {
    drawGaugeIcon(center: NSPoint(x: rect.minX + 62, y: rect.maxY - 168), radius: 34, needle: 0.62)
    drawText(productName, in: NSRect(x: rect.minX + 114, y: rect.maxY - 152, width: 320, height: 42), size: 34, weight: .semibold)
    drawText(subtitle, in: NSRect(x: rect.minX + 116, y: rect.maxY - 186, width: 440, height: 32), size: 20, color: palette.muted)
    rounded(NSRect(x: rect.maxX - 88, y: rect.maxY - 180, width: 46, height: 46), radius: 13, fill: color(0.90, 0.94, 0.96, 0.13), stroke: palette.stroke)
    drawText("R", in: NSRect(x: rect.maxX - 88, y: rect.maxY - 166, width: 46, height: 28), size: 18, weight: .semibold, alignment: .center)
}

func drawQuotaCard(_ rect: NSRect, title: String, status: String, reset: String, percent: CGFloat, accent: NSColor) {
    rounded(rect, radius: 18, fill: palette.panel2, stroke: palette.stroke)
    drawText(title, in: NSRect(x: rect.minX + 24, y: rect.maxY - 52, width: rect.width - 48, height: 28), size: 20, weight: .semibold)
    drawText(status, in: NSRect(x: rect.minX + 24, y: rect.maxY - 86, width: rect.width - 48, height: 26), size: 18, color: palette.muted)
    let center = NSPoint(x: rect.midX, y: rect.minY + 112)
    drawArc(center: center, radius: 54, start: 205, end: -25, clockwise: true, width: 16, color: color(0.35, 0.39, 0.45, 0.58))
    drawArc(center: center, radius: 54, start: 205, end: 205 - (230 * percent), clockwise: true, width: 16, color: accent)
    drawText("\(Int((percent * 100).rounded()))%", in: NSRect(x: center.x - 44, y: center.y - 15, width: 88, height: 34), size: 24, weight: .semibold, alignment: .center)
    drawText(reset, in: NSRect(x: rect.minX + 22, y: rect.minY + 24, width: rect.width - 44, height: 24), size: 16, color: palette.muted, alignment: .center)
}

func drawRow(_ rect: NSRect, title: String, detail: String, accent: NSColor, glyph: String) {
    rounded(rect, radius: 14, fill: palette.panel2, stroke: palette.stroke)
    rounded(NSRect(x: rect.minX + 18, y: rect.midY - 18, width: 36, height: 36), radius: 9, fill: accent.withAlphaComponent(0.16), stroke: accent.withAlphaComponent(0.28))
    drawText(glyph, in: NSRect(x: rect.minX + 18, y: rect.midY - 11, width: 36, height: 24), size: 15, weight: .bold, color: accent, alignment: .center)
    drawText(title, in: NSRect(x: rect.minX + 72, y: rect.midY + 2, width: rect.width - 96, height: 28), size: 19, weight: .medium)
    drawText(detail, in: NSRect(x: rect.minX + 72, y: rect.midY - 26, width: rect.width - 96, height: 25), size: 16, color: palette.muted)
}

func drawSectionTitle(_ text: String, at point: NSPoint, width: CGFloat) {
    drawText(text.uppercased(), in: NSRect(x: point.x, y: point.y, width: width, height: 28), size: 15, weight: .semibold, color: palette.muted)
}

func drawMetric(_ rect: NSRect, title: String, value: String, detail: String, accent: NSColor, glyph: String) {
    rounded(rect, radius: 20, fill: palette.panel2, stroke: palette.stroke)
    rounded(NSRect(x: rect.minX + 26, y: rect.maxY - 82, width: 54, height: 54), radius: 15, fill: accent.withAlphaComponent(0.16), stroke: accent.withAlphaComponent(0.28))
    drawText(glyph, in: NSRect(x: rect.minX + 26, y: rect.maxY - 67, width: 54, height: 26), size: 16, weight: .bold, color: accent, alignment: .center)
    drawText(title, in: NSRect(x: rect.minX + 100, y: rect.maxY - 64, width: rect.width - 130, height: 28), size: 19, color: palette.muted)
    drawText(value, in: NSRect(x: rect.minX + 26, y: rect.minY + 112, width: rect.width - 52, height: 46), size: 36, weight: .semibold)
    drawText(detail, in: NSRect(x: rect.minX + 26, y: rect.minY + 62, width: rect.width - 52, height: 36), size: 20, color: palette.muted)
}

func drawOperatorHud() {
    drawDesktop(title: "Menu-bar HUD with reset windows and sample work state")
    let popover = NSRect(x: 1520, y: 336, width: 780, height: 1120)
    drawWindow(popover, title: productName, activeTab: "Now")
    drawHeader(in: popover, subtitle: "Review-safe work state")

    let contentX = popover.minX + 40
    let cardW: CGFloat = 330
    let cardH: CGFloat = 220
    let topY = popover.maxY - 472
    drawQuotaCard(NSRect(x: contentX, y: topY, width: cardW, height: cardH), title: "Focus 5h", status: "sample", reset: "resets 3h 18m", percent: 0.63, accent: palette.teal)
    drawQuotaCard(NSRect(x: contentX + cardW + 40, y: topY, width: cardW, height: cardH), title: "Build 5h", status: "active", reset: "resets 1h 42m", percent: 0.47, accent: palette.amber)
    drawQuotaCard(NSRect(x: contentX, y: topY - 254, width: cardW, height: cardH), title: "Focus week", status: "sample", reset: "resets 4d 7h", percent: 0.78, accent: palette.green)
    drawQuotaCard(NSRect(x: contentX + cardW + 40, y: topY - 254, width: cardW, height: cardH), title: "Build week", status: "sample", reset: "resets 3d 15h", percent: 0.58, accent: palette.blue)

    drawSectionTitle("Alerts", at: NSPoint(x: contentX, y: topY - 326), width: 680)
    drawRow(NSRect(x: contentX, y: topY - 404, width: 700, height: 78), title: "clear", detail: "No active PaceDesk alerts", accent: palette.green, glyph: "OK")
    drawSectionTitle("Continuity", at: NSPoint(x: contentX, y: topY - 468), width: 680)
    drawRow(NSRect(x: contentX, y: topY - 546, width: 700, height: 78), title: "Sample peers: 2", detail: "Desktop and notebook snapshots current", accent: palette.teal, glyph: "IC")
    drawRow(NSRect(x: contentX, y: topY - 638, width: 700, height: 78), title: "Todos: 12", detail: "3 active, 4 deferred", accent: palette.amber, glyph: "TD")

    let detail = NSRect(x: 460, y: 420, width: 760, height: 860)
    rounded(detail, radius: 26, fill: color(1, 1, 1, 0.58), stroke: color(0.50, 0.55, 0.60, 0.16), lineWidth: 2)
    drawText("PaceDesk keeps sample work context visible while your active app stays in front.", in: NSRect(x: detail.minX + 48, y: detail.maxY - 164, width: detail.width - 96, height: 118), size: 32, weight: .semibold, color: palette.ink, wrap: true)
    drawRow(NSRect(x: detail.minX + 48, y: detail.maxY - 292, width: detail.width - 96, height: 86), title: "Sample reset clocks", detail: "Quota windows are visible without opening a dashboard", accent: palette.teal, glyph: "RT")
    drawRow(NSRect(x: detail.minX + 48, y: detail.maxY - 400, width: detail.width - 96, height: 86), title: "Sample state", detail: "Sessions, alerts, todos, and sync status together", accent: palette.blue, glyph: "ST")
    drawRow(NSRect(x: detail.minX + 48, y: detail.maxY - 508, width: detail.width - 96, height: 86), title: "Menu-bar first", detail: "A compact icon opens the HUD from any app", accent: palette.amber, glyph: "MB")
}

func drawSessionsHistory() {
    drawDesktop(title: "Session history with review-safe sample data")
    let window = NSRect(x: 380, y: 240, width: 2120, height: 1260)
    drawWindow(window, title: productName, activeTab: "Sessions")

    let content = NSRect(x: window.minX + 46, y: window.minY + 56, width: window.width - 92, height: window.height - 390)
    rounded(NSRect(x: content.minX, y: content.minY, width: 420, height: content.height), radius: 22, fill: color(0.07, 0.08, 0.10, 0.70), stroke: palette.stroke)
    drawHeader(in: NSRect(x: content.minX + 18, y: content.minY + content.height - 210, width: 384, height: 210), subtitle: "Sample session ledger")
    drawRow(NSRect(x: content.minX + 28, y: content.maxY - 362, width: 364, height: 82), title: "24h", detail: "9 sessions, 2.4M sample units", accent: palette.teal, glyph: "24")
    drawRow(NSRect(x: content.minX + 28, y: content.maxY - 462, width: 364, height: 82), title: "7d", detail: "41 sessions, 10.8M sample units", accent: palette.blue, glyph: "7D")
    drawRow(NSRect(x: content.minX + 28, y: content.maxY - 562, width: 364, height: 82), title: "Source mix", detail: "App, terminal, and browser samples", accent: palette.amber, glyph: "SR")

    let table = NSRect(x: content.minX + 462, y: content.minY, width: content.width - 462, height: content.height)
    rounded(table, radius: 22, fill: palette.panel2, stroke: palette.stroke)
    drawText("Sample Sessions", in: NSRect(x: table.minX + 34, y: table.maxY - 70, width: 360, height: 40), size: 28, weight: .semibold)
    drawText("Input", in: NSRect(x: table.minX + 40, y: table.maxY - 126, width: 190, height: 28), size: 16, weight: .semibold, color: palette.muted)
    drawText("Workspace", in: NSRect(x: table.minX + 260, y: table.maxY - 126, width: 520, height: 28), size: 16, weight: .semibold, color: palette.muted)
    drawText("Status", in: NSRect(x: table.minX + 840, y: table.maxY - 126, width: 220, height: 28), size: 16, weight: .semibold, color: palette.muted)
    drawText("Usage", in: NSRect(x: table.maxX - 250, y: table.maxY - 126, width: 190, height: 28), size: 16, weight: .semibold, color: palette.muted, alignment: .right)
    line(from: NSPoint(x: table.minX + 34, y: table.maxY - 146), to: NSPoint(x: table.maxX - 34, y: table.maxY - 146), width: 1, color: palette.stroke)

    let rows = [
        ("Focus", "Research sprint", "active", "1.32M", palette.teal),
        ("Build", "Release checklist", "complete", "428k", palette.blue),
        ("Review", "App Store metadata", "complete", "312k", palette.amber),
        ("Plan", "Backlog grooming", "queued", "206k", palette.coral),
        ("Write", "Support notes", "complete", "184k", palette.green),
        ("Ship", "Asset verification", "complete", "96k", palette.teal)
    ]

    for (index, row) in rows.enumerated() {
        let y = table.maxY - 232 - CGFloat(index) * 116
        rounded(NSRect(x: table.minX + 28, y: y - 20, width: table.width - 56, height: 90), radius: 14, fill: index % 2 == 0 ? color(0.09, 0.10, 0.13, 0.76) : color(0.12, 0.14, 0.17, 0.76), stroke: palette.stroke)
        rounded(NSRect(x: table.minX + 42, y: y + 2, width: 116, height: 44), radius: 12, fill: row.4.withAlphaComponent(0.16), stroke: row.4.withAlphaComponent(0.26))
        drawText(row.0, in: NSRect(x: table.minX + 42, y: y + 12, width: 116, height: 24), size: 16, weight: .semibold, color: row.4, alignment: .center)
        drawText(row.1, in: NSRect(x: table.minX + 260, y: y + 10, width: 520, height: 28), size: 22, weight: .medium)
        drawText(row.2, in: NSRect(x: table.minX + 840, y: y + 10, width: 220, height: 28), size: 20, color: palette.muted)
        drawText(row.3, in: NSRect(x: table.maxX - 250, y: y + 10, width: 190, height: 28), size: 20, weight: .semibold, alignment: .right, mono: true)
    }
}

func drawPrivacyAndSystem() {
    drawDesktop(title: "Privacy, sandboxing, and review-safe sample data")
    let window = NSRect(x: 500, y: 260, width: 1880, height: 1220)
    drawWindow(window, title: productName, activeTab: "System")
    drawHeader(in: window, subtitle: "Privacy and system state")

    let contentX = window.minX + 58
    let contentTop = window.maxY - 292
    let gridW = (window.width - 150) / 3
    let gridH: CGFloat = 260
    drawMetric(NSRect(x: contentX, y: contentTop - gridH, width: gridW, height: gridH), title: "Distribution", value: "App Store", detail: "Mac App Store build", accent: palette.teal, glyph: "AS")
    drawMetric(NSRect(x: contentX + gridW + 32, y: contentTop - gridH, width: gridW, height: gridH), title: "Sample data", value: "Review-safe", detail: "rendered artwork, not captured UI", accent: palette.blue, glyph: "SD")
    drawMetric(NSRect(x: contentX + (gridW + 32) * 2, y: contentTop - gridH, width: gridW, height: gridH), title: "Privacy", value: "No tracking", detail: "no ad or user tracking", accent: palette.green, glyph: "NT")

    drawSectionTitle("System", at: NSPoint(x: contentX, y: contentTop - 326), width: 600)
    drawRow(NSRect(x: contentX, y: contentTop - 420, width: window.width - 116, height: 80), title: "App sandbox", detail: "standard macOS app sandbox posture", accent: palette.teal, glyph: "SB")
    drawRow(NSRect(x: contentX, y: contentTop - 516, width: window.width - 116, height: 80), title: "File access", detail: "user-approved locations only", accent: palette.blue, glyph: "FILE")
    drawRow(NSRect(x: contentX, y: contentTop - 612, width: window.width - 116, height: 80), title: "Energy impact", detail: "sample status for screenshot review", accent: palette.amber, glyph: "PWR")

    drawSectionTitle("Actions", at: NSPoint(x: contentX, y: contentTop - 690), width: 600)
    drawRow(NSRect(x: contentX, y: contentTop - 784, width: window.width - 116, height: 80), title: "Screenshot mode", detail: "rendered with sample data, not a live capture", accent: palette.coral, glyph: "ART")
    drawRow(NSRect(x: contentX, y: contentTop - 880, width: window.width - 116, height: 80), title: "Quit PaceDesk", detail: "standard menu-bar app control", accent: palette.muted, glyph: "QT")
}

func writeImage(named filename: String, drawing: () -> Void) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasWidth,
        pixelsHigh: canvasHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "PaceDeskScreenshots", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawing()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PaceDeskScreenshots", code: 2)
    }
    try png.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
    print("screenshot_asset=created product=\"\(productName)\" source=\"rendered_artwork\" dataset=\"review_safe_sample\" captured_ui=false path=\"\(outputDirectory.appendingPathComponent(filename).path)\"")
}

try writeImage(named: "01-pacedesk-menu-hud.png", drawing: drawOperatorHud)
try writeImage(named: "02-pacedesk-session-history.png", drawing: drawSessionsHistory)
try writeImage(named: "03-pacedesk-privacy-system.png", drawing: drawPrivacyAndSystem)
