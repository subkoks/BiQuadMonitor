// Original BiQuad mark: two antenna loops and radio waves. Regenerate with:
// swift scripts/generate_icon.swift && iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit
import Foundation

let directory = URL(fileURLWithPath: "dist/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(calibratedWhite: 0.18, alpha: 1), ending: NSColor(calibratedWhite: 0.075, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(calibratedWhite: 0.32, alpha: 0.65).setStroke()
    tile.lineWidth = 3
    tile.stroke()
    let orange = NSColor(calibratedRed: 1, green: 0.40, blue: 0.18, alpha: 1)
    orange.setStroke()
    for center in [CGFloat(354), CGFloat(670)] {
        let loop = NSBezierPath()
        loop.move(to: NSPoint(x: center, y: 310))
        loop.line(to: NSPoint(x: center - 158, y: 468))
        loop.line(to: NSPoint(x: center, y: 626))
        loop.line(to: NSPoint(x: center + 158, y: 468))
        loop.close()
        loop.lineWidth = 46
        loop.lineJoinStyle = .round
        loop.stroke()
    }
    NSColor(calibratedWhite: 0.93, alpha: 1).setStroke()
    let mast = NSBezierPath()
    mast.move(to: NSPoint(x: 512, y: 418))
    mast.line(to: NSPoint(x: 512, y: 225))
    mast.lineWidth = 38
    mast.lineCapStyle = .round
    mast.stroke()
    orange.setStroke()
    for radius in [CGFloat(145), CGFloat(232)] {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: NSPoint(x: 512, y: 614), radius: radius, startAngle: 56, endAngle: 124)
        wave.lineWidth = 33
        wave.lineCapStyle = .round
        wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: points * scale).write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
