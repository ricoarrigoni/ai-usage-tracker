#!/usr/bin/env swift
// Draws the app icon and writes packaging/AppIcon.icns. Two gauges, for the session and weekly limits.
// Usage: swift scripts/make-icon.swift
import AppKit

func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let c = graphics.cgContext
    let unit = CGFloat(size) / 1024
    c.scaleBy(x: unit, y: unit)

    func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    // The standard macOS icon shape: 824 points inside a 1024 canvas, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.32))
    c.addPath(shape)
    c.setFillColor(color(16, 24, 44))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shape)
    c.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(38, 52, 92), color(12, 18, 36)] as CFArray, locations: [0, 1]
    )!
    c.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    // Each gauge opens at the bottom and fills clockwise from the lower left.
    let center = CGPoint(x: 512, y: 496)
    let start = CGFloat.pi * 1.25
    let sweep = CGFloat.pi * 1.5
    func arc(radius: CGFloat, width: CGFloat, fill: CGFloat, ink: CGColor) {
        c.setLineCap(.round)
        c.setLineWidth(width)
        c.setStrokeColor(color(255, 255, 255, 0.13))
        c.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        c.strokePath()
        c.setStrokeColor(ink)
        c.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep * fill, clockwise: true)
        c.strokePath()
    }
    arc(radius: 276, width: 74, fill: 0.72, ink: color(0x4F, 0x9B, 0xF5))
    arc(radius: 168, width: 74, fill: 0.42, ink: color(0x2C, 0xC9, 0x92))

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try draw(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("packaging/AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(tool.terminationStatus)
