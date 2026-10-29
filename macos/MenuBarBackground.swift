import CoreGraphics
import Foundation

/// Never stretch captured foreground pixels across the menu bar. Estimate the
/// background from padding above/below the text and generate a smooth gradient.
/// This remains safe when crowded native status items move alongside app menus.
enum MenuBarBackground {
    static func make(from image: CGImage, beforeX: CGFloat) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, width <= 32768, height > 0, height <= 512,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let converted = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard converted else { return nil }
        // Leave the native extras bar out of the estimate. A wider patch and
        // medians resist antialiasing, isolated symbols, and a shifted Help label.
        let edge = beforeX.isFinite ? Int(min(CGFloat(width), max(1, beforeX.rounded(.down)))) : width
        let start = max(0, edge - 96), end = edge
        func median(rows: Range<Int>) -> [Int]? {
            var channels = [[Int](), [Int](), [Int]()]
            for y in rows { for x in start..<end {
                let offset = (y * width + x) * 4
                guard pixels[offset + 3] >= 250 else { continue }
                for c in 0..<3 { channels[c].append(Int(pixels[offset + c])) }
            } }
            guard !channels[0].isEmpty else { return nil }
            return channels.map { values in let sorted = values.sorted(); return sorted[sorted.count / 2] }
        }
        let padding = height >= 8 ? min(3, max(1, height / 12)) : 0
        let band = min(height - padding, max(1, min(4, height / 8)))
        let topRows = padding..<(padding + band)
        let bottomStart = max(0, height - padding - band)
        let bottomRows = bottomStart..<(bottomStart + band)
        var top = median(rows: topRows), bottom = median(rows: bottomRows)
        // Large edge disagreement suggests a border, foreground, or transparency.
        // A single robust color is preferable to recreating a glyph-shaped band.
        if top == nil || bottom == nil || zip(top ?? [], bottom ?? []).contains(where: { abs($0 - $1) > 48 }) {
            guard let flat = median(rows: 0..<height) else { return nil }
            top = flat; bottom = flat
        }
        guard let first = top, let last = bottom else { return nil }
        var gradient = [UInt8](repeating: 255, count: height * 4)
        for y in 0..<height {
            let t = height == 1 ? 0 : Double(y) / Double(height - 1)
            for c in 0..<3 {
                gradient[y * 4 + c] = UInt8((Double(first[c]) * (1 - t) + Double(last[c]) * t).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(gradient) as CFData) else { return nil }
        return CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
