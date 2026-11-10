// Disegna l'icona di BeyondClone (1024×1024) e la salva in PNG.
// Uso: swift Support/make_icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linear(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

// Sfondo: quadrato arrotondato secondo la griglia delle icone macOS (824 px con margine di 100).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1B2A4A))
ctx.fillPath()
ctx.restoreGState()
linear(tilePath, [rgb(0x2F6BFF), rgb(0x1A2F6E)], from: CGPoint(x: 0, y: 924), to: CGPoint(x: 0, y: 100))
// Riflesso morbido in alto.
linear(tilePath, [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)], from: CGPoint(x: 0, y: 924), to: CGPoint(x: 0, y: 560))

// Due pannelli affiancati: i due lati del confronto.
let panelW: CGFloat = 300, panelH: CGFloat = 520, gap: CGFloat = 56
let panelY: CGFloat = 252
let leftX = size / 2 - gap / 2 - panelW
let rightX = size / 2 + gap / 2

struct Line { let width: CGFloat; let color: UInt32? }
let leftLines: [Line] = [
    .init(width: 0.78, color: nil), .init(width: 0.55, color: nil), .init(width: 0.86, color: 0xFF5A5F),
    .init(width: 0.62, color: nil), .init(width: 0.70, color: 0xFFA43A), .init(width: 0.48, color: nil),
    .init(width: 0.80, color: nil),
]
let rightLines: [Line] = [
    .init(width: 0.78, color: nil), .init(width: 0.55, color: nil), .init(width: 0.0, color: nil),
    .init(width: 0.62, color: nil), .init(width: 0.58, color: 0xFFA43A), .init(width: 0.48, color: nil),
    .init(width: 0.66, color: 0x34C77B),
]

func panel(x: CGFloat, lines: [Line]) {
    let r = CGRect(x: x, y: panelY, width: panelW, height: panelH)
    let p = rounded(r, 44)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000A30, 0.45))
    ctx.addPath(p)
    ctx.setFillColor(rgb(0xF4F7FF))
    ctx.fillPath()
    ctx.restoreGState()
    linear(p, [rgb(0xFFFFFF), rgb(0xDCE5FA)], from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))

    // Barra del titolo del pannello.
    ctx.setFillColor(rgb(0x1A2F6E, 0.12))
    ctx.fill(CGRect(x: r.minX, y: r.maxY - 70, width: r.width, height: 2))
    for i in 0..<3 {
        ctx.setFillColor(rgb(0x1A2F6E, 0.25))
        ctx.fillEllipse(in: CGRect(x: r.minX + 32 + CGFloat(i) * 30, y: r.maxY - 46, width: 18, height: 18))
    }

    // Righe di testo, alcune evidenziate come differenze.
    let lineH: CGFloat = 26, step: CGFloat = 58
    var y = r.maxY - 130
    for line in lines {
        let rowRect = CGRect(x: r.minX + 18, y: y - 14, width: r.width - 36, height: lineH + 28)
        if let c = line.color {
            ctx.addPath(rounded(rowRect, 14))
            ctx.setFillColor(rgb(c, 0.22))
            ctx.fillPath()
        }
        if line.width > 0 {
            let bar = CGRect(x: r.minX + 36, y: y, width: (r.width - 72) * line.width, height: lineH)
            ctx.addPath(rounded(bar, lineH / 2))
            ctx.setFillColor(line.color.map { rgb($0) } ?? rgb(0x2A3E78, 0.35))
            ctx.fillPath()
        }
        y -= step
    }
}

panel(x: leftX, lines: leftLines)
panel(x: rightX, lines: rightLines)

// Distintivo centrale con le frecce di sincronizzazione.
let center = CGPoint(x: size / 2, y: panelY + 70)
let badgeR: CGFloat = 112
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0x000A30, 0.5))
ctx.setFillColor(rgb(0xFF8A1F))
ctx.fillEllipse(in: CGRect(x: center.x - badgeR, y: center.y - badgeR, width: badgeR * 2, height: badgeR * 2))
ctx.restoreGState()
let badge = CGPath(ellipseIn: CGRect(x: center.x - badgeR, y: center.y - badgeR, width: badgeR * 2, height: badgeR * 2), transform: nil)
linear(badge, [rgb(0xFFB040), rgb(0xF26B0F)], from: CGPoint(x: 0, y: center.y + badgeR), to: CGPoint(x: 0, y: center.y - badgeR))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
ctx.setLineWidth(10)
ctx.strokeEllipse(in: CGRect(x: center.x - badgeR + 5, y: center.y - badgeR + 5, width: badgeR * 2 - 10, height: badgeR * 2 - 10))

func arc(_ start: CGFloat, _ end: CGFloat) {
    let r: CGFloat = 58
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
    // Punta della freccia alla fine dell'arco, orientata lungo la tangente.
    let tip = CGPoint(x: center.x + r * cos(end), y: center.y + r * sin(end))
    let tangent = end + .pi / 2
    let len: CGFloat = 40, half: CGFloat = 26
    let back = CGPoint(x: tip.x - len * cos(tangent) * 0.4, y: tip.y - len * sin(tangent) * 0.4)
    let front = CGPoint(x: tip.x + len * cos(tangent) * 0.6, y: tip.y + len * sin(tangent) * 0.6)
    let n = CGPoint(x: cos(end), y: sin(end))
    ctx.move(to: front)
    ctx.addLine(to: CGPoint(x: back.x + n.x * half, y: back.y + n.y * half))
    ctx.addLine(to: CGPoint(x: back.x - n.x * half, y: back.y - n.y * half))
    ctx.closePath()
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
}
arc(.pi * 0.15, .pi * 0.80)
arc(.pi * 1.15, .pi * 1.80)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Scritto \(out)")
