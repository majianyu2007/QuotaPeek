import AppKit
import Foundation

// All geometry is original artwork, drawn in a 1024-point coordinate system.
func drawIcon(size: Int, to destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "QuotaPeek.Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create icon bitmap."])
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                            xRadius: 196, yRadius: 196)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.19, green: 0.23, blue: 0.29, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.17, alpha: 1))!
        .draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.15).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    let center = NSPoint(x: 512, y: 502)
    func arc(from start: CGFloat, to end: CGFloat, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: 252, startAngle: start,
                       endAngle: end, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
    arc(from: 220, to: -40, color: NSColor.white.withAlphaComponent(0.10), width: 60)
    arc(from: 220, to: 88,
        color: NSColor(calibratedRed: 0.30, green: 0.83, blue: 0.76, alpha: 1), width: 60)
    arc(from: 72, to: 28,
        color: NSColor(calibratedRed: 0.65, green: 0.58, blue: 0.94, alpha: 1), width: 60)

    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: 627, y: 637))
    needle.lineWidth = 24
    needle.lineCapStyle = .round
    NSColor(calibratedWhite: 0.94, alpha: 1).setStroke()
    needle.stroke()
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 482, y: 472, width: 60, height: 60)).fill()

    // A compact readout anchors the gauge without tiny text at Dock sizes.
    NSColor(calibratedRed: 0.30, green: 0.83, blue: 0.76, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 409, y: 284, width: 206, height: 34),
                 xRadius: 17, yRadius: 17).fill()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "QuotaPeek.Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot encode icon PNG."])
    }
    try png.write(to: destination)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try drawIcon(size: points, to: output.appendingPathComponent("icon_\(points)x\(points).png"))
        try drawIcon(size: points * 2, to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
