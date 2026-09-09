#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift output.iconset\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let copper = NSColor(srgbRed: 0.86, green: 0.57, blue: 0.41, alpha: 1)
let warmWhite = NSColor(srgbRed: 0.94, green: 0.91, blue: 0.86, alpha: 1)
let track = NSColor(srgbRed: 0.27, green: 0.25, blue: 0.23, alpha: 1)
let background = NSColor(srgbRed: 0.105, green: 0.10, blue: 0.095, alpha: 1)

func drawIcon() {
    background.setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196).fill()
    let center = NSPoint(x: 512, y: 475)
    func arc(to angle: CGFloat, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 68
        path.lineCapStyle = .round
        path.appendArc(withCenter: center, radius: 278, startAngle: 210, endAngle: angle, clockwise: true)
        path.stroke()
    }
    arc(to: -30, color: track)
    arc(to: 53, color: copper)
    warmWhite.setStroke()
    let needle = NSBezierPath()
    needle.lineWidth = 38
    needle.lineCapStyle = .round
    needle.move(to: center)
    needle.line(to: NSPoint(x: 645, y: 652))
    needle.stroke()
    warmWhite.setFill()
    NSBezierPath(ovalIn: NSRect(x: 475, y: 438, width: 74, height: 74)).fill()
    copper.setFill()
    NSBezierPath(roundedRect: NSRect(x: 398, y: 267, width: 228, height: 30), xRadius: 15, yRadius: 15).fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.coderInvalidValue)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
    }
}
