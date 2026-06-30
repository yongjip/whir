import AppKit

// Renders the app icon (dark squircle + 3 ascending usage bars) at each size
// into an .iconset directory. Usage: swift scripts/make_icon.swift <out.iconset>

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // background squircle
    let margin = s * 0.085
    let side = s - 2 * margin
    let bg = NSBezierPath(roundedRect: NSRect(x: margin, y: margin, width: side, height: side),
                          xRadius: side * 0.2237, yRadius: side * 0.2237)
    NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    bg.fill()

    // 3 ascending bars
    let area = NSRect(x: margin, y: margin, width: side, height: side)
        .insetBy(dx: side * 0.28, dy: side * 0.28)
    let n = 3
    let gap = area.width * 0.16
    let bw = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
    let heights: [CGFloat] = [0.42, 0.7, 1.0]
    let colors = [NSColor.systemTeal, NSColor.systemBlue, NSColor.systemOrange]
    for i in 0..<n {
        let h = area.height * heights[i]
        let x = area.minX + CGFloat(i) * (bw + gap)
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: area.minY, width: bw, height: h),
                               xRadius: bw * 0.28, yRadius: bw * 0.28)
        colors[i].setFill()
        bar.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let items: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in items {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(items.count) icons to \(out)")
