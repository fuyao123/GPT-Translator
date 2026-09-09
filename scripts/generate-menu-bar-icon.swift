import AppKit

let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = projectURL.appendingPathComponent("Assets/menu-bar-icon.svg")
let outputURL = projectURL.appendingPathComponent("Assets/MenuBarIcon.png")

guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Unable to load menu-bar-icon.svg")
}

let targetSize = NSSize(width: 48, height: 38)
let image = NSImage(size: targetSize)
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
source.draw(in: NSRect(origin: .zero, size: targetSize))
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render MenuBarIcon.png")
}
try png.write(to: outputURL)
