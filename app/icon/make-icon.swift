// Draws ZC Care's icons from the ZoolCoder mark, icon/mark.svg (a copy of
// website-zoolcoder's public/logo/mark.svg): AppIcon.icns, the mark on an
// electric blue squircle, and MenuBarMark.pdf, a template for the menu bar.
// Usage: swift icon/make-icon.swift OUT_DIR; `make app-icon` runs it.
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let svg = try String(contentsOf: here.appendingPathComponent("mark.svg"), encoding: .utf8)

/// The mark's viewBox: 1040 square from (109, 97).
let box = CGRect(x: 109, y: 97, width: 1040, height: 1040)

/// The SVG's paths in order: the ink blades, then the accent blade and spark.
/// They hold only absolute M, L and C, which is all this reads.
let paths: [CGPath] = {
    let re = try! NSRegularExpression(pattern: #"<path[^>]* d="([^"]+)""#)
    return re.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).map { m in
        let d = String(svg[Range(m.range(at: 1), in: svg)!])
        let path = CGMutablePath()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        func flush() {
            var i = 0
            while i < numbers.count {
                // y flips: SVG grows down, Core Graphics up.
                func pt(_ k: Int) -> CGPoint { CGPoint(x: numbers[k] - box.minX, y: box.maxY - numbers[k + 1]) }
                switch command {
                case "M": path.move(to: pt(i)); command = "L"; i += 2
                case "L": path.addLine(to: pt(i)); i += 2
                case "C": path.addCurve(to: pt(i + 4), control1: pt(i), control2: pt(i + 2)); i += 6
                default: i = numbers.count
                }
            }
            numbers = []
        }
        var token = ""
        for ch in d + " " {
            if ch.isLetter {
                if !token.isEmpty { numbers.append(CGFloat(Double(token)!)); token = "" }
                flush()
                command = ch
            } else if ch == " " || ch == "," {
                if !token.isEmpty { numbers.append(CGFloat(Double(token)!)); token = "" }
            } else {
                token.append(ch)
            }
        }
        flush()
        if command == "Z" || command == "z" { path.closeSubpath() }
        return path
    }
}()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Fills the mark into rect, each path in its colour.
func drawMark(_ ctx: CGContext, in rect: CGRect, colors: [CGColor]) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
    for (path, c) in zip(paths, colors) {
        ctx.addPath(path)
        ctx.setFillColor(c)
        ctx.fillPath(using: .evenOdd)
    }
    ctx.restoreGState()
}

/// The app icon at 1024: Apple's grid puts an 824 squircle in the middle,
/// with room for the shadow below.
func appIcon(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0B1E5C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let blue = CGGradient(colorsSpace: nil, colors: [color(0x3D7BFF), color(0x2457E6), color(0x0B1E5C)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(blue, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0x9CC3FF, 0.40), color(0x9CC3FF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 800), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 800), endRadius: 520, options: [])
    // A hairline rim, lighter at the top, as macOS icons have.
    ctx.addPath(shape)
    ctx.setLineWidth(6)
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x05060A, 0.45))
    drawMark(ctx, in: CGRect(x: 222, y: 222, width: 580, height: 580),
             colors: [color(0xF3F5F7), color(0xA9C8FF)])
    return ctx.makeImage()!
}

func png(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(appIcon(size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(appIcon(size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

// The menu bar's mark: 18 points, black, as a template; macOS tints it.
var page = CGRect(x: 0, y: 0, width: 18, height: 18)
let pdf = NSMutableData()
let pdfCtx = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &page, nil)!
pdfCtx.beginPDFPage(nil)
drawMark(pdfCtx, in: page.insetBy(dx: 1, dy: 1), colors: [color(0x000000), color(0x000000)])
pdfCtx.endPDFPage()
pdfCtx.closePDF()
try pdf.write(to: out.appendingPathComponent("MenuBarMark.pdf"))
print("wrote \(out.path)/AppIcon.icns and MenuBarMark.pdf")
