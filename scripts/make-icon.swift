// Renders AppIcon.iconset into the directory given as the first argument.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: 824/1024 rounded square, centred.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.70, alpha: 1))!
        .draw(in: path, angle: -60)
    NSGraphicsContext.current?.restoreGraphicsState()

    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
    if let photo = symbol("photo.on.rectangle.angled", size: s * 0.36, weight: .medium) {
        let r = NSRect(x: (s - photo.size.width) / 2, y: s * 0.40, width: photo.size.width, height: photo.size.height)
        photo.draw(in: r)
    }
    if let arrow = symbol("arrow.down.circle.fill", size: s * 0.17, weight: .semibold) {
        let r = NSRect(x: (s - arrow.size.width) / 2, y: s * 0.17, width: arrow.size.width, height: arrow.size.height)
        arrow.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
    }
}
