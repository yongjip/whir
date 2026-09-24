import AppKit

// Export every size from the same master to preserve the seven-block W and its material.
// Usage: swift scripts/make_icon.swift <out.iconset>

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make_icon.swift <out.iconset>\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let renderURL = root.appendingPathComponent("store/assets/app-icon-render.png")
let masterURL = root.appendingPathComponent("store/assets/app-icon-master.png")
guard let master = NSBitmapImageRep(data: try Data(contentsOf: renderURL)),
      master.pixelsWide == master.pixelsHigh, master.pixelsWide >= 1024,
      let source = master.cgImage else {
    fputs("Icon master must be a square PNG of at least 1024 pixels.\n", stderr)
    exit(1)
}
let image = NSImage(cgImage: source, size: NSSize(width: master.pixelsWide, height: master.pixelsHigh))

private func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    // A common export mask gives both the generated render and its alpha a clean silhouette.
    let side = CGFloat(px)
    let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.08, y: side * 0.08,
                                               width: side * 0.84, height: side * 0.84),
                            xRadius: side * 0.185, yRadius: side * 0.185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.08, alpha: 0.18)
    shadow.shadowBlurRadius = side * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    tile.addClip()
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero,
               operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(master.pixelsWide).write(to: masterURL)

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let items: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in items {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(items.count) icons from \(masterURL.lastPathComponent) to \(out)")
