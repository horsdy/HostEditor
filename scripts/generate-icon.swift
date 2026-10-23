import AppKit

// One drawing is used at every size, including the menu bar. No font dependency.
func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let plate = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.27, blue: 0.32, alpha: 1),
               ending: NSColor(srgbRed: 0.025, green: 0.075, blue: 0.13, alpha: 1))!.draw(in: plate, angle: -55)
    NSColor(srgbRed: 0.36, green: 0.86, blue: 0.76, alpha: 0.4).setStroke(); plate.lineWidth = 10; plate.stroke()
    let h = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(218,235),(323,789),(448,789),(406,565),(596,565),(638,789),
        (763,789),(658,235),(533,235),(575,455),(385,455),(343,235)]
    h.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { h.line(to: NSPoint(x: point.0, y: point.1)) }; h.close()
    NSGradient(starting: NSColor(srgbRed: 0.46, green: 0.97, blue: 0.77, alpha: 1),
               ending: NSColor(srgbRed: 0.92, green: 1, blue: 0.99, alpha: 1))!.draw(in: h, angle: 65)
    // A routing arrow through the crossbar evokes address-to-host mapping.
    let route = NSBezierPath(); route.move(to: NSPoint(x: 414, y: 510)); route.line(to: NSPoint(x: 565, y: 510))
    route.move(to: NSPoint(x: 531, y: 539)); route.line(to: NSPoint(x: 565, y: 510)); route.line(to: NSPoint(x: 531, y: 481))
    NSColor(srgbRed: 0.04, green: 0.18, blue: 0.22, alpha: 1).setStroke()
    route.lineWidth = 16; route.lineCapStyle = .round; route.lineJoinStyle = .round; route.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("HostEditor.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(size: 1024).write(to: output.appendingPathComponent("HostEditor.png"))
