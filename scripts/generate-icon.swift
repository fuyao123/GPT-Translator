import AppKit

let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = projectURL.appendingPathComponent("Assets/material-translate.svg")
let outputURL = projectURL.appendingPathComponent("Assets/AppIcon-1024.png")

guard let symbol = NSImage(contentsOf: svgURL) else {
    fatalError("无法读取 \(svgURL.path)")
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("无法创建位图")
}

bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("无法创建绘图上下文")
}
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.48, green: 0.20, blue: 0.88, alpha: 1)
])!
gradient.draw(in: tile, angle: -45)

NSColor.white.withAlphaComponent(0.16).setStroke()
tile.lineWidth = 8
tile.stroke()

symbol.draw(
    in: NSRect(x: 172, y: 172, width: 680, height: 680),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法导出 PNG")
}
try png.write(to: outputURL)
print(outputURL.path)
