// Draws Glanzow's app icon: a window at night, split into panes, the one you look at aglow.
// Usage: swift scripts/icon.swift <out.iconset> [preview.png]
// Then: iconutil -c icns <out.iconset> -o Resources/Glanzow.icns
import AppKit
import CoreGraphics

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                            CGFloat(hex & 0xff) / 255, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// The macOS icon outline: a superellipse, whose corners curve continuously like the system's.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let x = r.midX + r.width / 2 * copysign(pow(abs(cos(t)), 2 / n), cos(t))
        let y = r.midY + r.height / 2 * copysign(pow(abs(sin(t)), 2 / n), sin(t))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// A rounded rectangle with its own radius per corner (bottom-left, bottom-right, top-right,
/// top-left; y up), so corners near the icon's edge stay concentric with it.
func pane(_ r: CGRect, _ bl: CGFloat, _ br: CGFloat, _ tr: CGFloat, _ tl: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + bl, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: br)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: tr)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: tl)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: bl)
    p.closeSubpath()
    return p
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k) // everything below is in a 1024 design space, y up
    let small = px <= 64    // where pixels are scarce: no fine lines, wider gutters

    // The body on Apple's grid (824 of 1024), with a soft shadow under it.
    let body = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: rgb(0x000000, 0.38)) // device pixels
    ctx.addPath(body); ctx.setFillColor(rgb(0x14122B)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x0C0B1D)), (1, rgb(0x211D45))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Three panes: a tall one on the left, two stacked on the right. The top right is lit.
    let gutter = max(26, 1.3 / k), inset: CGFloat = 74
    let inner = CGRect(x: 100 + inset, y: 100 + inset, width: 824 - 2 * inset, height: 824 - 2 * inset)
    let leftW = (inner.width - gutter) * 0.45, rightX = inner.minX + leftW + gutter, rightW = inner.maxX - rightX
    let halfH = (inner.height - gutter) / 2
    let outer: CGFloat = 92, inside: CGFloat = 34 // corner radii: near the icon's edge, and elsewhere
    let leftRect = CGRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
    let litRect = CGRect(x: rightX, y: inner.maxY - halfH, width: rightW, height: halfH)
    let lowRect = CGRect(x: rightX, y: inner.minY, width: rightW, height: halfH)
    let left = pane(leftRect, outer, inside, inside, outer)
    let lit = pane(litRect, inside, inside, outer, inside)
    let low = pane(lowRect, inside, outer, inside, inside)
    let gaze = CGPoint(x: litRect.minX + litRect.width * 0.44, y: litRect.minY + litRect.height * 0.54)

    // The light spills past its pane: into the gutters, the frame and the neighbours' near edges.
    ctx.saveGState()
    ctx.setBlendMode(.screen) // light adds to what's under it rather than tinting it
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFB547, 0.30)), (0.4, rgb(0xFF9F3A, 0.08)), (1, rgb(0xFF9F3A, 0))]),
                           startCenter: gaze, startRadius: 0, endCenter: gaze, endRadius: 430, options: [])
    // A halo that follows the lit pane's own shape, glowing out into the gaps around it.
    ctx.setShadow(offset: .zero, blur: 80 * k, color: rgb(0xFFB040, 0.95))
    ctx.addPath(lit); ctx.setFillColor(rgb(0xFFB040)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 26 * k, color: rgb(0xFFC860, 0.8))
    ctx.addPath(lit); ctx.fillPath()
    ctx.restoreGState()

    for (path, rect) in [(left, leftRect), (low, lowRect)] {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0x161433)), (1, rgb(0x262256))]),
                               start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        if !small { // a few lines of text, barely there
            let widths: [CGFloat] = [0.62, 0.44, 0.71, 0.36, 0.58, 0.67, 0.4, 0.55, 0.3, 0.6, 0.48, 0.66]
            var y = rect.maxY - 70
            for w in widths where y > rect.minY + 40 {
                ctx.addPath(CGPath(roundedRect: CGRect(x: rect.minX + 44, y: y, width: (rect.width - 88) * w, height: 13),
                                   cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
                y -= 44
            }
            ctx.setFillColor(rgb(0xB9B6D3, 0.11)); ctx.fillPath()
        }
        // Warm bounce from the lit pane, strongest on the edges that face it.
        ctx.setBlendMode(.screen)
        ctx.drawRadialGradient(gradient([(0, rgb(0xFFB547, 0.16)), (1, rgb(0xFFB547, 0))]),
                               startCenter: gaze, startRadius: 0, endCenter: gaze, endRadius: 380, options: [])
        ctx.restoreGState()
        if !small {
            ctx.addPath(path); ctx.setStrokeColor(rgb(0xB9B6D3, 0.13)); ctx.setLineWidth(2); ctx.strokePath()
        }
    }

    // The lit pane: hottest where the eyes rest, deepening to ember at its corners.
    ctx.saveGState()
    ctx.addPath(lit); ctx.clip()
    let reach = hypot(max(gaze.x - litRect.minX, litRect.maxX - gaze.x), max(gaze.y - litRect.minY, litRect.maxY - gaze.y))
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFF7E0)), (0.1, rgb(0xFFE9B0)), (0.38, rgb(0xFFCF6A)),
                                     (0.75, rgb(0xFBAE48)), (1, rgb(0xF08F34))]),
                           startCenter: gaze, startRadius: 0, endCenter: gaze, endRadius: reach, options: [.drawsAfterEndLocation])
    ctx.addPath(lit); ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(small ? 0 : 5); ctx.strokePath() // lightbox edge
    // A glassy rim along its top.
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0)), (1, rgb(0xFFFFFF, 0.32))]),
                           start: CGPoint(x: 0, y: litRect.maxY - 26), end: CGPoint(x: 0, y: litRect.maxY), options: [])
    // Where the eyes rest: a small bright point in its own glow.
    ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.8)), (1, rgb(0xFFFFFF, 0))]),
                           startCenter: gaze, startRadius: 0, endCenter: gaze, endRadius: small ? 70 : 84, options: [])
    let r: CGFloat = small ? 28 : 15
    ctx.addEllipse(in: CGRect(x: gaze.x - r, y: gaze.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    // The body's own glass: a faint sheen at the top and a hairline rim.
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0)), (1, rgb(0xFFFFFF, 0.07))]),
                           start: CGPoint(x: 512, y: 560), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
    if !small {
        ctx.addPath(body); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
let set = args.count > 1 ? args[1] : "Glanzow.iconset"
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    write(render(px: pt), to: "\(set)/icon_\(pt)x\(pt).png")
    write(render(px: pt * 2), to: "\(set)/icon_\(pt)x\(pt)@2x.png")
}

// Optional preview: every size, on light and on dark.
if args.count > 2 {
    let sizes = [512, 256, 128, 64, 32, 16]
    let w = sizes.reduce(0) { $0 + $1 + 40 } + 40, h = 2 * (512 + 80)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (row, ground) in [(1, rgb(0xF2F1F6)), (0, rgb(0x1E1E22))] {
        ctx.setFillColor(ground); ctx.fill(CGRect(x: 0, y: row * (512 + 80), width: w, height: 512 + 80))
        var x = 40
        for s in sizes {
            ctx.draw(render(px: s), in: CGRect(x: x, y: row * (512 + 80) + 40 + (512 - s) / 2, width: s, height: s))
            x += s + 40
        }
    }
    write(ctx.makeImage()!, to: args[2])
}
