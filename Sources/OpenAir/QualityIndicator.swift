import AppKit
import SwiftUI

/// A resolution-independent image keeps the status indicator at six points on
/// both standard and Retina displays, instead of using a full-size emoji glyph.
func qualityDotImage(color: NSColor, diameter: CGFloat = 6) -> NSImage {
    let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }
    image.isTemplate = false
    // Provide a text baseline while preserving the compact intrinsic image size.
    image.alignmentRect = NSRect(x: 0, y: -2, width: diameter, height: diameter + 2)
    return image
}

/// MenuBarExtra maps these children to the native status button's separate image
/// and title. Interpolating an Image into Text loses the attachment on macOS 26.
struct QualityMenuLabel: View {
    let color: NSColor
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: qualityDotImage(color: color)).renderingMode(.original)
            Text(title)
        }
    }
}
