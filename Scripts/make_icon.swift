// Builds the brand images from the logo file. Usage:
//   swift make_icon.swift logo  <Logo-Original.webp> <Logo.png>       square crop for the app
//   swift make_icon.swift icon  <Logo.png> <out.png>                  1024×1024 macOS app icon
import AppKit

func save(_ draw: (CGFloat) -> Void, size: CGFloat, to path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(size)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Apple's icon grid: a rounded square inside 1024 with 100 points of margin.
func tile(_ size: CGFloat) -> NSBezierPath {
    let inset = size * 100 / 1024
    return NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset), xRadius: size * 0.18, yRadius: size * 0.18)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "logo":
    // the original is 1024×572 with the X around (512, 285): cut a square that keeps the glow
    guard let source = NSImage(contentsOfFile: args[2]), let rep = source.representations.first else { exit(1) }
    let scale = CGFloat(rep.pixelsWide) / source.size.width
    let side: CGFloat = 520 / scale
    let crop = NSRect(x: 252 / scale, y: (572 - 285 - 260) / scale, width: side, height: side)
    try save({ s in source.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: crop, operation: .copy, fraction: 1) }, size: 1024, to: args[3])
case "icon":
    guard let logo = NSImage(contentsOfFile: args[2]) else { exit(1) }
    try save({ s in
        // the black of the logo picture fills the tile; the X sits in the middle with room around it
        NSColor(srgbRed: 0.016, green: 0.019, blue: 0.018, alpha: 1).setFill()
        tile(s).fill()
        tile(s).addClip()
        let side = s * 0.60
        logo.draw(in: NSRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
    }, size: 1024, to: args[3])
default:
    exit(2)
}
