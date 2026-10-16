// Tacet's app icon, drawn as vectors with Core Graphics (no SF Symbols: their
// licence doesn't allow them in app icons).
//
//   swift Icon/make-icon.swift preview <dir>          512 px previews, every variant, light + dark
//   swift Icon/make-icon.swift iconset <variant> <dir> Tacet.iconset for iconutil (light)
//
// Geometry follows the macOS app icon grid: a 1024 canvas, an 824 pt squircle
// inset 100 pt, a soft drop shadow below it.
import AppKit

enum Variant: String, CaseIterable { case night, resting, glass }
enum Look: String, CaseIterable { case light, dark }

// MARK: Shapes

/// Apple-style continuous-corner square (superellipse, n = 6).
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 6.0, steps = 720
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// One "<" chevron as a stroked outline with round caps and joins.
func chevron(tipX: CGFloat, midY: CGFloat, width: CGFloat, height: CGFloat, line: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: tipX + width, y: midY + height / 2))
    p.addLine(to: CGPoint(x: tipX, y: midY))
    p.addLine(to: CGPoint(x: tipX + width, y: midY - height / 2))
    // normalized(): the stroked outline overlaps itself at the inner join,
    // which showed as a small notch in the edge highlight.
    return p.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
}

/// The double chevron «, centred on `center`.
func doubleChevron(center: CGPoint, size: CGFloat) -> (back: CGPath, front: CGPath) {
    let line = size * 0.16
    let w = size * 0.36, h = size * 0.78, gap = size * 0.30
    let total = w + gap
    let left = center.x - total / 2
    let front = chevron(tipX: left, midY: center.y, width: w, height: h, line: line)
    let back = chevron(tipX: left + gap, midY: center.y, width: w, height: h, line: line)
    return (back, front)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: Drawing

/// Draws on a 1024 × 1024 canvas (y up).
func draw(_ v: Variant, _ look: Look, in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)
    let dark = look == .dark

    // Drop shadow, as on system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    // Background.
    let top = CGPoint(x: 512, y: 924), bottom = CGPoint(x: 512, y: 100)
    switch (v, dark) {
    case (.night, false): linear(ctx, shape, [color(0x3B3F9E), color(0x141C46)], from: top, to: bottom)
    case (.night, true): linear(ctx, shape, [color(0x22245A), color(0x070A1A)], from: top, to: bottom)
    case (.resting, false): linear(ctx, shape, [color(0xFBFCFE), color(0xDCE2EE)], from: top, to: bottom)
    case (.resting, true): linear(ctx, shape, [color(0x30333D), color(0x121419)], from: top, to: bottom)
    case (.glass, false): linear(ctx, shape, [color(0x5AA8F0), color(0x5536C8)], from: CGPoint(x: 160, y: 924), to: CGPoint(x: 864, y: 100))
    case (.glass, true): linear(ctx, shape, [color(0x24496E), color(0x231552)], from: CGPoint(x: 160, y: 924), to: CGPoint(x: 864, y: 100))
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Variant details behind the glyph.
    switch v {
    case .night:
        // A faint menu bar across the top, with a hairline under it.
        ctx.setFillColor(color(0xFFFFFF, dark ? 0.06 : 0.09))
        ctx.fill(CGRect(x: 100, y: 800, width: 824, height: 124))
        ctx.setFillColor(color(0xFFFFFF, dark ? 0.10 : 0.16))
        ctx.fill(CGRect(x: 100, y: 798, width: 824, height: 3))
    case .resting:
        // The line the chevron rests on (a staff line / the menu bar edge).
        let bar = CGPath(roundedRect: CGRect(x: 250, y: 318, width: 524, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil)
        ctx.addPath(bar)
        ctx.setFillColor(dark ? color(0xB9B6FF, 0.55) : color(0x4B4AB8, 0.35))
        ctx.fillPath()
    case .glass:
        break
    }

    // Glass sheen: a soft light from the top, and an edge highlight.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0xFFFFFF, dark ? 0.10 : 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 400, y: 960), startRadius: 0, endCenter: CGPoint(x: 400, y: 960), endRadius: 620, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(color(0xFFFFFF, dark ? 0.12 : (v == .resting ? 0.9 : 0.22)))
    ctx.strokePath()
    ctx.restoreGState()

    // The double chevron.
    let center: CGPoint
    let size: CGFloat
    switch v {
    case .night: (center, size) = (CGPoint(x: 512, y: 470), 400)
    case .resting: (center, size) = (CGPoint(x: 512, y: 560), 360)
    case .glass: (center, size) = (CGPoint(x: 512, y: 512), 440)
    }
    let glyph = doubleChevron(center: center, size: size)

    func glassFill(_ path: CGPath, top: CGColor, bottom: CGColor, shadow: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, shadow))
        ctx.addPath(path)
        ctx.setFillColor(bottom)
        ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, path, [top, bottom], from: CGPoint(x: 512, y: center.y + size / 2), to: CGPoint(x: 512, y: center.y - size / 2))
        // Specular edge on top.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.addPath(path)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(color(0xFFFFFF, 0.35))
        ctx.strokePath()
        ctx.restoreGState()
    }

    switch (v, dark) {
    case (.night, _):
        let a: CGFloat = dark ? 0.82 : 1
        glassFill(glyph.back, top: color(0xFFFFFF, 0.55 * a), bottom: color(0xC9CFFF, 0.40 * a), shadow: 0.25)
        glassFill(glyph.front, top: color(0xFFFFFF, a), bottom: color(0xD6DBFF, 0.92 * a), shadow: 0.35)
    case (.resting, false):
        glassFill(glyph.back, top: color(0x7C7BE6, 0.55), bottom: color(0x4B4AB8, 0.55), shadow: 0.10)
        glassFill(glyph.front, top: color(0x6E6CF0), bottom: color(0x3F3DAA), shadow: 0.22)
    case (.resting, true):
        glassFill(glyph.back, top: color(0xD9D7FF, 0.45), bottom: color(0xA9A6F5, 0.45), shadow: 0.30)
        glassFill(glyph.front, top: color(0xE6E4FF), bottom: color(0xA9A6F5), shadow: 0.40)
    case (.glass, _):
        let a: CGFloat = dark ? 0.85 : 1
        glassFill(glyph.back, top: color(0xFFFFFF, 0.45 * a), bottom: color(0xFFFFFF, 0.25 * a), shadow: 0.20)
        glassFill(glyph.front, top: color(0xFFFFFF, 0.98 * a), bottom: color(0xE8E4FF, 0.88 * a), shadow: 0.35)
    }
}

func render(_ v: Variant, _ look: Look, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(v, look, in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: Main

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "preview":
    let dir = URL(fileURLWithPath: args.dropFirst().first ?? "Icon/previews")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for v in Variant.allCases {
        for look in Look.allCases {
            try render(v, look, pixels: 512).write(to: dir.appendingPathComponent("\(v.rawValue)-\(look.rawValue).png"))
        }
    }
    print("Previews in \(dir.path)")
case "iconset":
    let rest = Array(args.dropFirst())
    guard let name = rest.first, let v = Variant(rawValue: name), rest.count > 1 else {
        print("usage: iconset <\(Variant.allCases.map(\.rawValue).joined(separator: "|"))> <dir>"); exit(1)
    }
    let dir = URL(fileURLWithPath: rest[1])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try render(v, .light, pixels: base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
        try render(v, .light, pixels: base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    print("Iconset in \(dir.path)")
default:
    print("usage: make-icon.swift preview <dir> | iconset <variant> <dir>")
}
