import AppKit

let destination = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let outline = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
NSGradient(starting: NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.94, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.61, alpha: 1))!.draw(in: outline, angle: -75)
let circle = NSBezierPath(ovalIn: NSRect(x: 183, y: 183, width: 658, height: 658))
NSColor.white.withAlphaComponent(0.21).setStroke(); circle.lineWidth = 13; circle.stroke()
let heights: [CGFloat] = [100, 230, 350, 490, 350, 230, 100]
for (i, height) in heights.enumerated() {
    let bar = NSBezierPath(roundedRect: NSRect(x: 275 + CGFloat(i) * 71, y: 512 - height / 2, width: 48, height: height), xRadius: 24, yRadius: 24)
    NSColor.white.withAlphaComponent(i == 3 ? 1 : 0.89).setFill(); bar.fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
