// Menu bar item image, in the style of the Stats app's "mini" widgets: small caption above a big value.

import AppKit

enum Renderer {
    static let captionFont = NSFont.systemFont(ofSize: 8.5, weight: .regular)
    static let valueFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    struct Column { let caption: String; let value: String }

    static func image(soc: Double?, charging: Bool, columns: [Column], dimmed: Bool, height: CGFloat) -> NSImage {
        let pad: CGFloat = 3, iconW: CGFloat = 13, gap: CGFloat = 7
        let widths = columns.map { col -> CGFloat in
            let a = (col.caption as NSString).size(withAttributes: [.font: captionFont]).width
            let b = (col.value as NSString).size(withAttributes: [.font: valueFont]).width
            return ceil(max(a, b))
        }
        let width = pad + iconW + gap + widths.reduce(0, +) + gap * CGFloat(max(0, columns.count - 1)) + pad
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let alpha: CGFloat = dimmed ? 0.45 : 1
            let color = NSColor.black.withAlphaComponent(alpha)
            drawBattery(in: NSRect(x: pad, y: (height - 20) / 2, width: iconW, height: 20),
                        soc: soc, charging: charging, color: color)
            var x = pad + iconW + gap
            for (i, col) in columns.enumerated() {
                let w = widths[i]
                let cap = NSAttributedString(string: col.caption, attributes: [.font: captionFont, .foregroundColor: color])
                let val = NSAttributedString(string: col.value, attributes: [.font: valueFont, .foregroundColor: color])
                let cs = cap.size(), vs = val.size()
                // Stack: caption on top, value under it, centred vertically as a block.
                let block = cs.height + vs.height - 5
                let top = (height + block) / 2 + 0.5
                cap.draw(at: NSPoint(x: x, y: top - cs.height + 1))
                val.draw(at: NSPoint(x: x, y: top - cs.height - vs.height + 4))
                x += w + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func drawBattery(in r: NSRect, soc: Double?, charging: Bool, color: NSColor) {
        color.set()
        let capH: CGFloat = 2
        let body = NSRect(x: r.minX + 0.75, y: r.minY + 0.75, width: r.width - 1.5, height: r.height - capH - 1.5)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.5
        outline.stroke()
        NSBezierPath(roundedRect: NSRect(x: r.midX - 2.5, y: body.maxY + 0.5, width: 5, height: capH),
                     xRadius: 0.8, yRadius: 0.8).fill()

        let inner = body.insetBy(dx: 2, dy: 2)
        let level = CGFloat(min(100, max(0, soc ?? 0)) / 100)
        if level > 0 {
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(1.5, inner.height * level)),
                         xRadius: 1, yRadius: 1).fill()
        }
        if charging {
            // Punch a bolt out of the fill so it reads in template mode.
            let b = NSBezierPath()
            let cx = body.midX, cy = body.midY
            b.move(to: NSPoint(x: cx + 1.2, y: cy + 5.5))
            b.line(to: NSPoint(x: cx - 3.0, y: cy - 0.5))
            b.line(to: NSPoint(x: cx - 0.2, y: cy - 0.5))
            b.line(to: NSPoint(x: cx - 1.2, y: cy - 5.5))
            b.line(to: NSPoint(x: cx + 3.0, y: cy + 0.5))
            b.line(to: NSPoint(x: cx + 0.2, y: cy + 0.5))
            b.close()
            NSGraphicsContext.current?.compositingOperation = .xor
            b.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
    }
}
