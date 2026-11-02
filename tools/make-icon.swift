// Usage: swift tools/make-icon.swift <out.iconset dir>
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: s*0.06, y: s*0.06, width: s*0.88, height: s*0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s*0.2, yRadius: s*0.2)
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.07, alpha: 1)])!.draw(in: bg, angle: -90)
    let c = NSPoint(x: s/2, y: s/2)
    NSColor(white: 1, alpha: 0.92).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - s*0.27, y: c.y - s*0.27, width: s*0.54, height: s*0.54))
    ring.lineWidth = s*0.045; ring.stroke()
    NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - s*0.16, y: c.y - s*0.16, width: s*0.32, height: s*0.32)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
