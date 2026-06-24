import AppKit
import SwiftUI

/// SwiftUI wrapper: Image(nsImage: cachedIcon)
struct CIcon: View {
    let image: NSImage
    init(_ builder: () -> NSImage) { self.image = builder() }
    var body: some View { Image(nsImage: image).resizable() }
}

enum CustomIcons {
    // MARK: - Chrome button template icons (black drawings, isTemplate = true)

    /// Sidebar toggle: rectangle with vertical divider (spec L94, viewBox 0 0 16 13).
    static var sidebarToggle: NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 13), flipped: false) { _ in
            let p = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 0.7, width: 14.6, height: 11.6),
                                  xRadius: 2.5, yRadius: 2.5)
            p.lineWidth = 1.3
            p.stroke()
            NSBezierPath.strokeLine(from: NSPoint(x: 5.5, y: 1), to: NSPoint(x: 5.5, y: 12))
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Find / search: circle + diagonal line (spec L118, viewBox 0 0 14 14).
    static var find: NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: 6, y: 8), radius: 4.3, startAngle: 0, endAngle: 360)
            p.lineWidth = 1.4
            p.stroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 9.2, y: 4.8))
            line.line(to: NSPoint(x: 12.5, y: 1.5))
            line.lineWidth = 1.4
            line.lineCapStyle = .round
            line.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Open / folder: folder outline (spec L122, viewBox 0 0 15 14).
    static var openFolder: NSImage {
        let img = NSImage(size: NSSize(width: 15, height: 14), flipped: false) { _ in
            // SVG path: M1 3.3 Q1 2.1 2.2 2.1 L5.4 2.1 L6.8 3.6 L12.8 3.6 Q14 3.6 14 4.8 L14 10.4 Q14 11.6 12.8 11.6 L2.2 11.6 Q1 11.6 1 10.4 Z
            // Flipped Y: H=14, so svg_y → 14 - svg_y
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 1, y: 14 - 3.3))               // M1 3.3
            p.curve(to: NSPoint(x: 2.2, y: 14 - 2.1),             // Q1 2.1 → 2.2 2.1
                    controlPoint1: NSPoint(x: 1, y: 14 - 2.1), controlPoint2: NSPoint(x: 2.2, y: 14 - 2.1))
            p.line(to: NSPoint(x: 5.4, y: 14 - 2.1))              // L5.4 2.1
            p.line(to: NSPoint(x: 6.8, y: 14 - 3.6))              // L6.8 3.6
            p.line(to: NSPoint(x: 12.8, y: 14 - 3.6))             // L12.8 3.6
            p.curve(to: NSPoint(x: 14, y: 14 - 4.8),              // Q14 3.6 → 14 4.8
                    controlPoint1: NSPoint(x: 14, y: 14 - 3.6), controlPoint2: NSPoint(x: 14, y: 14 - 4.8))
            p.line(to: NSPoint(x: 14, y: 14 - 10.4))              // L14 10.4
            p.curve(to: NSPoint(x: 12.8, y: 14 - 11.6),           // Q14 11.6 → 12.8 11.6
                    controlPoint1: NSPoint(x: 14, y: 14 - 11.6), controlPoint2: NSPoint(x: 12.8, y: 14 - 11.6))
            p.line(to: NSPoint(x: 2.2, y: 14 - 11.6))             // L2.2 11.6
            p.curve(to: NSPoint(x: 1, y: 14 - 10.4),              // Q1 11.6 → 1 10.4
                    controlPoint1: NSPoint(x: 1, y: 14 - 11.6), controlPoint2: NSPoint(x: 1, y: 14 - 10.4))
            p.close()
            p.lineWidth = 1.4
            p.lineJoinStyle = .round
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Sidebar fixed-color icons

    /// Sidebar folder: filled folder (spec L69, viewBox 0 0 14 12, fill #C7C7CC).
    static func sidebarFolder(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 1, y: 12 - 9.5))               // M1 9.5
            p.curve(to: NSPoint(x: 2.5, y: 12 - 11),              // Q1 11 → 2.5 11
                    controlPoint1: NSPoint(x: 1, y: 12 - 11), controlPoint2: NSPoint(x: 2.5, y: 12 - 11))
            p.line(to: NSPoint(x: 5, y: 12 - 11))                 // L5 11
            p.line(to: NSPoint(x: 6.5, y: 12 - 9.5))              // L6.5 9.5
            p.line(to: NSPoint(x: 11.5, y: 12 - 9.5))             // L11.5 9.5
            p.curve(to: NSPoint(x: 13, y: 12 - 7.5),              // Q13 9.5 → 13 7.5
                    controlPoint1: NSPoint(x: 13, y: 12 - 9.5), controlPoint2: NSPoint(x: 13, y: 12 - 7.5))
            p.line(to: NSPoint(x: 13, y: 12 - 3))                 // L13 3
            p.curve(to: NSPoint(x: 11.5, y: 12 - 1.5),            // Q13 1.5 → 11.5 1.5
                    controlPoint1: NSPoint(x: 13, y: 12 - 1.5), controlPoint2: NSPoint(x: 11.5, y: 12 - 1.5))
            p.line(to: NSPoint(x: 2.5, y: 12 - 1.5))              // L2.5 1.5
            p.curve(to: NSPoint(x: 1, y: 12 - 3),                 // Q1 1.5 → 1 3
                    controlPoint1: NSPoint(x: 1, y: 12 - 1.5), controlPoint2: NSPoint(x: 1, y: 12 - 3))
            p.close()
            NSColor(hex: 0xC7C7CC).setFill()
            p.fill()
            return true
        }
    }

    /// Sidebar / palette file: document with two lines (spec L72, viewBox 0 0 11 13).
    static func docFile(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            let p = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 0.7, width: 9.6, height: 11.6),
                                  xRadius: 1.6, yRadius: 1.6)
            p.lineWidth = 1.0
            NSColor.white.setFill()
            p.fill()
            NSColor(hex: 0xC2C2C8).setStroke()
            p.stroke()
            let lineColor = NSColor(hex: 0xC2C2C8)
            lineColor.setStroke()
            NSBezierPath.defaultLineWidth = 1.0
            NSBezierPath.strokeLine(from: NSPoint(x: 3, y: 9), to: NSPoint(x: 8, y: 9))
            NSBezierPath.strokeLine(from: NSPoint(x: 3, y: 6.5), to: NSPoint(x: 8, y: 6.5))
            return true
        }
    }
}