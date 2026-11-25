import AppKit
import Foundation

public enum ColorExtractor {
    public static let fallbackHex = "#3A3D42"

    /// Extracts a rich, visually legible header color from an app icon.
    public static func dominantHeaderColorHex(from image: NSImage?) -> String {
        guard let image else { return fallbackHex }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return fallbackHex
        }

        let targetSize = 24
        guard let resized = resize(bitmap: bitmap, size: targetSize) else {
            return fallbackHex
        }

        var buckets: [Int: (r: Double, g: Double, b: Double, weight: Double)] = [:]

        for y in 0..<resized.pixelsHigh {
            for x in 0..<resized.pixelsWide {
                guard let color = resized.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let alpha = color.alphaComponent
                guard alpha > 0.5 else { continue }

                var h: CGFloat = 0
                var s: CGFloat = 0
                var b: CGFloat = 0
                var a: CGFloat = 0
                color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

                // Skip near-white, near-black, and very gray pixels when looking for brand tint
                if s < 0.18 || b < 0.18 || (s < 0.25 && b > 0.85) {
                    continue
                }

                let hueBucket = Int(h * 18.0) % 18
                let weight = Double(s * b * alpha)
                var entry = buckets[hueBucket] ?? (0, 0, 0, 0)
                entry.r += Double(color.redComponent) * weight
                entry.g += Double(color.greenComponent) * weight
                entry.b += Double(color.blueComponent) * weight
                entry.weight += weight
                buckets[hueBucket] = entry
            }
        }

        guard let best = buckets.values.max(by: { $0.weight < $1.weight }), best.weight > 0.2 else {
            return fallbackHex
        }

        let avgColor = NSColor(
            srgbRed: best.r / best.weight,
            green: best.g / best.weight,
            blue: best.b / best.weight,
            alpha: 1.0
        )

        // Clamp brightness so white header text always remains crisp and legible
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        avgColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let clampedB = min(max(b, 0.45), 0.94)
        let clampedS = min(max(s, 0.50), 0.92)
        let tuned = NSColor(hue: h, saturation: clampedS, brightness: clampedB, alpha: 1.0)
            .usingColorSpace(.sRGB) ?? avgColor

        let ri = Int(round(tuned.redComponent * 255))
        let gi = Int(round(tuned.greenComponent * 255))
        let bi = Int(round(tuned.blueComponent * 255))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    private static func resize(bitmap: NSBitmapImageRep, size: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
