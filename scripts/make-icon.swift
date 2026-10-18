import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draws the app icon in the Tasker style: dark navy squircle with a blue rim glow, a stack of
// tilted glossy blue "screens", and an embossed play-and-broadcast symbol with a cyan→green sheen.
// Usage: make-icon <out.iconset>
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func roundedPolygon(_ pts: [CGPoint], radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n = pts.count
    let mid = CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2)
    p.move(to: mid)
    for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: radius) }
    p.closeSubpath()
    return p
}

let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// MARK: Background squircle (824 px shape on a 1024 canvas, macOS icon grid)
let shape: CGFloat = 824
let tileRect = CGRect(x: (S - shape) / 2, y: (S - shape) / 2, width: shape, height: shape)
let tile = CGPath(roundedRect: tileRect, cornerWidth: shape * 0.2237, cornerHeight: shape * 0.2237, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.45))
ctx.addPath(tile); ctx.setFillColor(rgb(0x070D22)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x0E1A3D), rgb(0x060B1D)]),
                       start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: [])
// Inner rim glow.
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0x2A5CFF, 1))
ctx.addPath(tile); ctx.setStrokeColor(rgb(0x2F63FF, 0.55)); ctx.setLineWidth(14); ctx.strokePath()
ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x3D6BFF, 0.6))
ctx.addPath(tile); ctx.setStrokeColor(rgb(0x3D6BFF, 0.35)); ctx.setLineWidth(6); ctx.strokePath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile); ctx.setStrokeColor(rgb(0x5C86FF, 0.18)); ctx.setLineWidth(2); ctx.strokePath()
ctx.restoreGState()

// MARK: Stacked screens
let cardSize = CGSize(width: 540, height: 380)
let cardPath = CGPath(roundedRect: CGRect(x: -cardSize.width / 2, y: -cardSize.height / 2,
                                          width: cardSize.width, height: cardSize.height),
                      cornerWidth: 56, cornerHeight: 56, transform: nil)

struct Layer { let dx: CGFloat; let dy: CGFloat; let angle: CGFloat; let top: UInt32; let bottom: UInt32; let side: UInt32 }
let layers = [
    Layer(dx: 62, dy: -96, angle: -3.5, top: 0x2E4BF0, bottom: 0x3A22C9, side: 0x22179A),
    Layer(dx: 32, dy: -50, angle: -2.0, top: 0x2A73F2, bottom: 0x2C3FE0, side: 0x1C2AB0),
    Layer(dx: 0, dy: 0, angle: 2.5, top: 0x35A9F6, bottom: 0x2552EC, side: 0x1A33C4),
]
let center = CGPoint(x: 490, y: 560)

for (i, l) in layers.enumerated() {
    ctx.saveGState()
    ctx.translateBy(x: center.x + l.dx, y: center.y + l.dy)
    ctx.rotate(by: l.angle * .pi / 180)

    // Thickness + glow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 40, color: rgb(0x2B55FF, 0.55))
    ctx.translateBy(x: 4, y: -16)
    ctx.addPath(cardPath); ctx.setFillColor(rgb(l.side)); ctx.fillPath()
    ctx.restoreGState()

    // Face.
    ctx.saveGState()
    ctx.addPath(cardPath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(l.top), rgb(l.bottom)]),
                           start: CGPoint(x: -cardSize.width / 2, y: cardSize.height / 2),
                           end: CGPoint(x: cardSize.width / 2, y: -cardSize.height / 2), options: [])
    if i == layers.count - 1 {
        // Soft sheen across the front screen.
        ctx.drawRadialGradient(gradient([rgb(0x7FE3FF, 0.35), rgb(0x7FE3FF, 0)]),
                               startCenter: CGPoint(x: 120, y: 150), startRadius: 0,
                               endCenter: CGPoint(x: 120, y: 150), endRadius: 380, options: [])
    }
    ctx.restoreGState()

    // Rim highlight.
    ctx.addPath(cardPath); ctx.setStrokeColor(rgb(0xFFFFFF, i == layers.count - 1 ? 0.28 : 0.16))
    ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: Embossed play + broadcast symbol on the front screen
let tip = CGPoint(x: 30, y: 0)
let triangle = roundedPolygon([CGPoint(x: -150, y: 112), CGPoint(x: -150, y: -112), CGPoint(x: tip.x, y: 0)], radius: 30)
let arcs = CGMutablePath()
for r: CGFloat in [82, 150] {
    arcs.move(to: CGPoint(x: tip.x + r * cos(-.pi / 4), y: r * sin(-.pi / 4)))
    arcs.addArc(center: tip, radius: r, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
}
let arcOutline = arcs.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10)
var symbol = triangle.union(arcOutline)
var grow = CGAffineTransform(scaleX: 1.22, y: 1.22)
symbol = symbol.copy(using: &grow) ?? symbol
let bounds = symbol.boundingBoxOfPath

ctx.saveGState()
let front = layers.last!
ctx.translateBy(x: center.x + front.dx, y: center.y + front.dy)
ctx.rotate(by: front.angle * .pi / 180)
ctx.translateBy(x: -bounds.midX, y: -bounds.midY + 4)

// Extrusion + drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: rgb(0x0A1680, 0.7))
for step in stride(from: CGFloat(20), through: 2, by: -2) {
    ctx.saveGState()
    ctx.translateBy(x: step * 0.25, y: -step)
    ctx.addPath(symbol); ctx.setFillColor(rgb(step > 12 ? 0x1830B8 : 0x2147DE)); ctx.fillPath()
    ctx.restoreGState()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
}
ctx.restoreGState()

// Face: cyan with a green highlight towards the top right.
ctx.saveGState()
ctx.addPath(symbol); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x2FA6F2), rgb(0x46CDF4), rgb(0x72F2C2)], [0, 0.55, 1]),
                       start: CGPoint(x: bounds.minX, y: bounds.minY),
                       end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)]),
                       start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.midY), options: [])
ctx.restoreGState()
ctx.addPath(symbol); ctx.setStrokeColor(rgb(0xFFFFFF, 0.5)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// MARK: Output iconset
let master = ctx.makeImage()!

func write(_ size: Int, _ name: String) {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    let url = URL(fileURLWithPath: "\(out)/\(name)")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    write(s, "icon_\(s)x\(s).png")
    write(s * 2, "icon_\(s)x\(s)@2x.png")
}
