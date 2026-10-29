import AppKit

func menuBarBackgroundSelfTest() throws {
    func check(_ value: Bool, _ name: String) throws { if !value { throw BridgeError(AppMessage(raw: "Menu background: " + name)) } }
    func image(width: Int = 160, height: Int = 60, _ color: (Int, Int) -> [UInt8]) -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<height { for x in 0..<width { bytes += color(x, y) } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func rgb(_ image: CGImage, _ y: Int) -> [Double] {
        // These fixtures/output images are explicit RGBA8 in sRGB. Reading
        // through NSColor would reinterpret calibrated RGB before comparison.
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow
        return (0..<3).map { Double(data[offset + $0]) / 255 }
    }
    let plain = image { _, y in [UInt8(60 - y / 6), UInt8(35 - y / 6), UInt8(25 - y / 6), 255] }
    let glyph = image { x, y in
        if x >= 125 && x <= 129 && ([23, 24, 35, 36, 37].contains(y)) { return [255, 255, 255, 255] }
        return [UInt8(60 - y / 6), UInt8(35 - y / 6), UInt8(25 - y / 6), 255]
    }
    let base = MenuBarBackground.make(from: plain, beforeX: 130)!
    let fixed = MenuBarBackground.make(from: glyph, beforeX: 130)!
    for y in 0..<60 {
        try check(zip(rgb(base,y),rgb(fixed,y)).allSatisfy { abs($0-$1) < 0.01 }, "Help glyph does not enter the background")
        try check(rgb(fixed,y).max()! < 0.3, "no white horizontal streaks")
    }
    for light in [false, true] {
        let source = image { x,y in
            let bg: UInt8 = light ? 235 : 25, fg: UInt8 = light ? 0 : 255
            let isText = y >= 10 && y <= 46 && x % 9 < 5
            return [isText ? fg : bg, isText ? fg : bg, isText ? fg : bg, 255]
        }
        let result = MenuBarBackground.make(from: source,beforeX: 160)!
        try check(abs(rgb(result,30)[0] - (light ? 235.0 : 25.0) / 255) < 0.02, "dark and light menus ignore dense lettering")
    }
    let edgeText = image { _,y in y < 8 ? [255,255,255,255] : [30,30,30,255] }
    let fallback = MenuBarBackground.make(from: edgeText,beforeX: 100)!
    try check(rgb(fallback,30)[0] < 0.2, "contaminated edge uses the flat fallback")
    for x: CGFloat in [-100,0,1,160,10000,.nan,.infinity] {
        try check(MenuBarBackground.make(from: glyph,beforeX: x) != nil, "invalid and extreme positions stay bounded")
    }
    let tiny = image(width:1,height:1) { _,_ in [40,50,60,255] }
    try check(MenuBarBackground.make(from:tiny,beforeX:0)?.width == 1, "one-pixel image")
    let clear = image { _,_ in [0,0,0,0] }
    try check(MenuBarBackground.make(from:clear,beforeX:100) == nil, "transparent sample safely rejected")
    for c in 0..<3 {
        let values = (0..<60).map { rgb(fixed,$0)[c] }
        try check(zip(values,values.dropFirst()).allSatisfy { $0 >= $1 }, "generated gradient has no text-shaped peaks")
    }
    print("PASS: menu background glyph rejection, light/dark themes, smooth gradient, fallback and bounds")
}
