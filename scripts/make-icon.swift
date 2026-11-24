// Draws the JackeryBar app icon: a dark squircle with the charge ring from the popup and a bolt.
//   swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS grid: 824×824 body centred in 1024 with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let rgb = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: rgb, colors: [NSColor(red: 0.20, green: 0.21, blue: 0.24, alpha: 1).cgColor,
                                                   NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint top highlight.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(6)
    ctx.addPath(shape); ctx.strokePath()

    let c = CGPoint(x: 512, y: 512), r: CGFloat = 270, w: CGFloat = 74
    // Track.
    ctx.setLineWidth(w); ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()

    // 78 % charge arc, clockwise from 12 o'clock, green gradient.
    let start = CGFloat.pi / 2, end = start - 0.78 * 2 * .pi
    ctx.saveGState()
    let arc = CGMutablePath(); arc.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
    ctx.addPath(arc.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)); ctx.clip()
    let green = CGGradient(colorsSpace: rgb, colors: [NSColor(red: 0.55, green: 0.93, blue: 0.55, alpha: 1).cgColor,
                                                      NSColor(red: 0.13, green: 0.72, blue: 0.42, alpha: 1).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: 300, y: 800), end: CGPoint(x: 720, y: 220), options: [])
    ctx.restoreGState()

    // Bolt.
    let bolt = CGMutablePath()
    bolt.addLines(between: [CGPoint(x: 548, y: 700), CGPoint(x: 398, y: 488), CGPoint(x: 498, y: 488),
                            CGPoint(x: 470, y: 324), CGPoint(x: 626, y: 548), CGPoint(x: 524, y: 548)])
    bolt.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.addPath(bolt); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(bolt); ctx.clip()
    let warm = CGGradient(colorsSpace: rgb, colors: [NSColor(red: 1, green: 0.86, blue: 0.35, alpha: 1).cgColor,
                                                     NSColor(red: 1, green: 0.62, blue: 0.18, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 512, y: 700), end: CGPoint(x: 512, y: 324), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try! draw(1024).representation(using: .png, properties: [:])!
    .write(to: out.deletingPathExtension().appendingPathExtension("png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
