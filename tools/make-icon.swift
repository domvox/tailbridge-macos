// Draws the TailBridge app icon into an .iconset directory for `iconutil -c icns`.
// The mark is two open bands that swap places twice, on a graphite tile (Apple's 824/1024 icon grid).
// Only CoreGraphics and ImageIO; no network, no external files.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Mark geometry in 1024-unit tile coordinates (y grows downward).
/// x0/x1: band ends, a: half the distance between the bands, w: band width, g: gap at a crossing.
struct Geometry { let x0, x1, a, w, g: CGFloat }

/// 16 and 32 px use optically tuned proportions: thicker bands, wider gaps, band edges on whole pixels.
func geometry(forPixels px: Int) -> Geometry {
    if px <= 16 { return Geometry(x0: 192, x1: 832, a: 192, w: 128, g: 64) }
    if px <= 32 { return Geometry(x0: 192, x1: 832, a: 112, w: 96, g: 48) }
    return Geometry(x0: 222, x1: 802, a: 106, w: 77, g: 27)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let tileTop = color(0x2d3036), tileBottom = color(0x1a1c20)
let bandA = color(0xf1efe9), bandB = color(0x86cdbf)

/// One band: starts on row `from`, crosses to row `to` at the centre and returns.
func bandPath(_ m: Geometry, from: CGFloat, to: CGFloat) -> CGPath {
    let hl = 512 - m.x0, hr = m.x1 - 512
    let p = CGMutablePath()
    p.move(to: CGPoint(x: m.x0, y: from))
    p.addCurve(to: CGPoint(x: 512, y: to), control1: CGPoint(x: m.x0 + hl / 2, y: from), control2: CGPoint(x: m.x0 + hl / 2, y: to))
    p.addCurve(to: CGPoint(x: m.x1, y: from), control1: CGPoint(x: 512 + hr / 2, y: to), control2: CGPoint(x: 512 + hr / 2, y: from))
    return p
}

/// Strokes `path` in its own layer, then clears a gap where `over` passes on top near `crossing`.
func strokeBand(_ ctx: CGContext, _ path: CGPath, _ fill: CGColor, under over: CGPath, at crossing: CGPoint, _ m: Geometry) {
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setLineCap(.butt)
    ctx.setLineWidth(m.w)
    ctx.setStrokeColor(fill)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.saveGState()
    let r = m.w + m.g + 40
    ctx.addEllipse(in: CGRect(x: crossing.x - r, y: crossing.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(m.w + 2 * m.g)
    ctx.addPath(over)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.endTransparencyLayer()
}

func render(pixels px: Int) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no bitmap context") }
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    guard let gradient = CGGradient(colorsSpace: space, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1]) else {
        fatalError("no gradient")
    }
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()

    let m = geometry(forPixels: px)
    let top = 512 - m.a, bottom = 512 + m.a
    let a = bandPath(m, from: top, to: bottom), b = bandPath(m, from: bottom, to: top)
    strokeBand(ctx, a, bandA, under: b, at: CGPoint(x: m.x0 + (512 - m.x0) / 2, y: 512), m)
    strokeBand(ctx, b, bandB, under: a, at: CGPoint(x: 512 + (m.x1 - 512) / 2, y: 512), m)
    guard let image = ctx.makeImage() else { fatalError("no image") }
    return image
}

let slots: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("użycie: make-icon <katalog>.iconset\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
for (name, px) in slots {
    let url = dir.appendingPathComponent(name + ".png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(dest, render(pixels: px), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}
