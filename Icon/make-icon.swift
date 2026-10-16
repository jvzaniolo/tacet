// Tacet's app icon, drawn as vectors with Core Graphics (no SF Symbols: their
// licence doesn't allow them in app icons).
//
// Direction "Glass" (2026-10-16): neutral dark glass, always dark. A graphite
// squircle with a rim light; the double chevron « as frosted white glass,
// the front chevron solid, the one behind translucent.
//
//   swift Icon/make-icon.swift preview <dir>           512 px previews of every variant
//   swift Icon/make-icon.swift iconset <variant> <dir> Tacet.iconset for iconutil (full bleed)
//   swift Icon/make-icon.swift png <variant> <px> <file> [masked]  one PNG (site exports)
//
// Geometry follows the macOS app icon grid: a 1024 canvas, an 824 pt squircle
// inset 100 pt. The .icns is drawn full bleed: macOS 26+ applies its own mask
// and glass edge (a pre-masked shape that doesn't match exactly is put on a
// gray plate).
import AppKit

enum Variant: String, CaseIterable { case graphite, plate, bold }

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
func doubleChevron(center: CGPoint, size: CGFloat, weight: CGFloat = 0.16) -> (back: CGPath, front: CGPath) {
    let line = size * weight
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

/// Draws on a 1024 × 1024 canvas (y up). `fullBleed`: fill the whole square
/// and let macOS apply its own mask (the app icon); otherwise draw the
/// squircle with its shadow and rim (previews, site images).
func draw(_ v: Variant, fullBleed: Bool = false, in ctx: CGContext) {
    let body = fullBleed ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = fullBleed ? CGPath(rect: body, transform: nil) : squircle(body)
    let topY = body.maxY, bottomY = body.minY

    if !fullBleed {
        // Drop shadow, as on system icons.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(color(0x1C1C1F))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Graphite base: lighter at the top, near black at the bottom.
    linear(ctx, shape, [color(0x4A4A50), color(0x2A2A2E), color(0x1C1C1F)], from: CGPoint(x: 512, y: topY), to: CGPoint(x: 512, y: bottomY))

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Glass bloom from the top and a faint sheen across the upper half.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bloom = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: topY + 80), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: topY + 80), endRadius: 640, options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.07), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: topY), end: CGPoint(x: 512, y: (topY + bottomY) / 2), options: [])

    if v == .plate {
        // A second, frosted glass pane under the chevrons.
        let pane = CGPath(roundedRect: CGRect(x: 232, y: 232, width: 560, height: 560), cornerWidth: 140, cornerHeight: 140, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.45))
        ctx.addPath(pane)
        ctx.setFillColor(color(0x55555C, 0.55))
        ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, pane, [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0.03)], from: CGPoint(x: 512, y: 792), to: CGPoint(x: 512, y: 232))
        ctx.saveGState()
        ctx.addPath(pane)
        ctx.clip()
        ctx.addPath(pane)
        ctx.setLineWidth(5)
        ctx.setStrokeColor(color(0xFFFFFF, 0.22))
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    if !fullBleed {
        // Rim light: bright along the top edge, fading down the sides.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setLineWidth(7)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.42), color(0xFFFFFF, 0.08), color(0xFFFFFF, 0.04)] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: topY), end: CGPoint(x: 512, y: bottomY), options: [])
        ctx.restoreGState()
    }

    // The double chevron.
    let (center, size): (CGPoint, CGFloat) = switch v {
    case .graphite: (CGPoint(x: 512, y: 512), 450)
    case .plate: (CGPoint(x: 512, y: 512), 340)
    case .bold: (CGPoint(x: 512, y: 512), 500)
    }
    let glyph = doubleChevron(center: center, size: size, weight: v == .bold ? 0.20 : 0.16)
    let glyphTop = center.y + size * 0.48, glyphBottom = center.y - size * 0.48

    /// Frosted white glass: a soft shadow under it, a vertical fill, a bright
    /// specular band across its top and a thin edge.
    func glass(_ path: CGPath, top: CGFloat, bottom: CGFloat, shadow: CGFloat, specular: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, shadow))
        ctx.addPath(path)
        ctx.setFillColor(color(0xFFFFFF, bottom))
        ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, path, [color(0xFFFFFF, top), color(0xF2F2F7, bottom)], from: CGPoint(x: 512, y: glyphTop), to: CGPoint(x: 512, y: glyphBottom))
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let spec = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, specular), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(spec, start: CGPoint(x: 512, y: glyphTop), end: CGPoint(x: 512, y: center.y + size * 0.05), options: [])
        ctx.addPath(path)
        ctx.setLineWidth(6)
        ctx.setStrokeColor(color(0xFFFFFF, 0.5))
        ctx.strokePath()
        ctx.restoreGState()
    }

    switch v {
    case .graphite, .plate:
        glass(glyph.back, top: 0.42, bottom: 0.22, shadow: 0.30, specular: 0.25)
        glass(glyph.front, top: 0.98, bottom: 0.80, shadow: 0.55, specular: 0.6)
    case .bold:
        glass(glyph.back, top: 0.50, bottom: 0.28, shadow: 0.30, specular: 0.25)
        glass(glyph.front, top: 1.0, bottom: 0.85, shadow: 0.55, specular: 0.6)
    }
}

func render(_ v: Variant, pixels: Int, fullBleed: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(v, fullBleed: fullBleed, in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "preview":
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "Icon/previews")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for v in Variant.allCases {
        try render(v, pixels: 512).write(to: dir.appendingPathComponent("\(v.rawValue).png"))
        for px in [16, 32, 64] {
            try render(v, pixels: px).write(to: dir.appendingPathComponent("\(v.rawValue)-\(px).png"))
        }
    }
    print("Previews in \(dir.path)")
case "iconset":
    guard args.count > 2, let v = Variant(rawValue: args[1]) else {
        print("usage: iconset <\(Variant.allCases.map(\.rawValue).joined(separator: "|"))> <dir>"); exit(1)
    }
    let dir = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try render(v, pixels: base, fullBleed: true).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
        try render(v, pixels: base * 2, fullBleed: true).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    print("Iconset in \(dir.path)")
case "png":
    guard args.count > 3, let v = Variant(rawValue: args[1]), let px = Int(args[2]) else {
        print("usage: png <variant> <px> <file> [masked]"); exit(1)
    }
    try render(v, pixels: px, fullBleed: !args.contains("masked")).write(to: URL(fileURLWithPath: args[3]))
default:
    print("usage: make-icon.swift preview <dir> | iconset <variant> <dir> | png <variant> <px> <file> [masked]")
}
