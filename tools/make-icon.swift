// Dessine l'icône de Rafale : trois flèches qui tombent ensemble dans un bac.
// Usage : swift tools/make-icon.swift <dossier de sortie>
// Produit icon-1024.png (icône de l'app) et MenuIcon.png (barre de menus, monochrome).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(_ size: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    draw(ctx.cgContext)
    return rep.representation(using: .png, properties: [:])!
}

/// Le motif, dans un carré `r` : trois flèches décalées en hauteur, un bac en dessous.
func glyph(_ ctx: CGContext, in r: CGRect, color: CGColor, weight: CGFloat) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    ctx.setStrokeColor(color)
    ctx.setLineWidth(weight * r.width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let tip: CGFloat = 0.30, head: CGFloat = 0.082
    for (x, top) in [(0.17, 0.80), (0.50, 0.99), (0.83, 0.69)] as [(CGFloat, CGFloat)] {
        ctx.move(to: pt(x, top))
        ctx.addLine(to: pt(x, tip))
        ctx.move(to: pt(x - head, tip + head))
        ctx.addLine(to: pt(x, tip))
        ctx.addLine(to: pt(x + head, tip + head))
    }
    ctx.move(to: pt(0.04, 0.19))
    ctx.addLine(to: pt(0.04, 0.05))
    ctx.addLine(to: pt(0.96, 0.05))
    ctx.addLine(to: pt(0.96, 0.19))
    ctx.strokePath()
}

// Icône de l'app : carré arrondi de 824 px sur un canevas de 1024, ombre portée.
let app = render(1024) { ctx in
    let square = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: square, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [CGColor(red: 1.00, green: 0.66, blue: 0.22, alpha: 1),
                  CGColor(red: 0.98, green: 0.36, blue: 0.30, alpha: 1),
                  CGColor(red: 0.80, green: 0.14, blue: 0.42, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 250, y: 924), end: CGPoint(x: 774, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Reflet discret en haut.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(glow, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.22))
    glyph(ctx, in: square.insetBy(dx: 190, dy: 190), color: CGColor(gray: 1, alpha: 1), weight: 0.088)
}
try app.write(to: out.appendingPathComponent("icon-1024.png"))

// Barre de menus : 18 pt en @2x, noir sur transparent (image modèle).
let menu = render(36) { ctx in
    glyph(ctx, in: CGRect(x: 5, y: 4, width: 26, height: 28), color: CGColor(gray: 0, alpha: 1), weight: 0.105)
}
try menu.write(to: out.appendingPathComponent("MenuIcon.png"))
print("OK")
