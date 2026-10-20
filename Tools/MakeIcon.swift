import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bounds = NSRect(x: 56, y: 56, width: 912, height: 912)
NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.45, alpha: 1).setFill()
NSBezierPath(roundedRect: bounds, xRadius: 205, yRadius: 205).fill()
NSColor.white.withAlphaComponent(0.3).setFill()
for x in [320, 512, 704] {
    NSBezierPath(roundedRect: NSRect(x: x - 12, y: 266, width: 24, height: 492), xRadius: 12, yRadius: 12).fill()
}
for (x, y) in [(320, 595), (512, 405), (704, 545)] {
    NSColor(calibratedRed: 0.1, green: 0.48, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: x - 60, y: y - 60, width: 120, height: 120)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - 46, y: y - 46, width: 92, height: 92)).fill()
}
image.unlockFocus()
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
