// Draws the app icon into Resources/AppIcon.icns and docs/icon.png. Run from the repo root: swift scripts/make-icon.swift
import AppKit

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // macOS icon grid: 824pt body centered in 1024, continuous-corner rounded square
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath)
    ctx.setFillColor(.black)
    ctx.fillPath()

    // hourglass built from squares: rows of 5, 3, 1, 3, 5
    ctx.setFillColor(.white)
    let cell: CGFloat = 92, gap: CGFloat = 14, step = cell + gap
    let rows = [5, 3, 1, 3, 5]
    let height = CGFloat(rows.count) * step - gap
    for (row, count) in rows.enumerated() {
        let y = 512 + height / 2 - CGFloat(row + 1) * step + gap
        let width = CGFloat(count) * step - gap
        for i in 0..<count {
            ctx.fill(CGRect(x: 512 - width / 2 + CGFloat(i) * step, y: y, width: cell, height: cell))
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! draw(size: points * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/icon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Built Resources/AppIcon.icns and docs/icon.png")
