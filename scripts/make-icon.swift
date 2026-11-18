// Draws the Corner Drop app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift            (from the repo root)
//   swift scripts/make-icon.swift preview.png  (just the 1024px PNG)
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // Icon body on Apple's macOS grid: 824pt square, ~185pt corner radius, soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    color(0xE8457A).setFill()
    bodyPath.fill()
    ctx.restoreGState()
    NSGradient(starting: color(0xE23E73), ending: color(0xFF9E8A))!.draw(in: bodyPath, angle: 90)

    // Subtle top sheen.
    ctx.saveGState()
    bodyPath.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.18))!
        .draw(in: CGRect(x: 100, y: 560, width: 824, height: 364), angle: 90)
    ctx.restoreGState()

    // The pop-out list, tucked into the bottom-left corner.
    let panel = CGRect(x: 172, y: 172, width: 540, height: 470)
    let panelPath = roundedRect(panel, 64)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 34, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    NSColor.white.withAlphaComponent(0.95).setFill()
    panelPath.fill()
    ctx.restoreGState()

    // Three file rows, newest (highlighted) nearest the corner.
    let thumbColors: [(UInt32, UInt32)] = [(0x4F8DFD, 0x7FB2FF), (0xFFB547, 0xFFD27F), (0x37C28A, 0x7BE0B3)]
    let rowHeight: CGFloat = 132
    for i in 0..<3 {
        let y = panel.minY + 36 + CGFloat(2 - i) * (rowHeight + 6)
        let row = CGRect(x: panel.minX + 26, y: y, width: panel.width - 52, height: rowHeight)
        if i == 2 {
            color(0xE8457A, 0.14).setFill()
            roundedRect(row, 30).fill()
        }
        let thumb = CGRect(x: row.minX + 22, y: row.midY - 44, width: 88, height: 88)
        NSGradient(starting: color(thumbColors[i].0), ending: color(thumbColors[i].1))!
            .draw(in: roundedRect(thumb, 22), angle: 90)
        color(0x2B2B33, 0.78).setFill()
        roundedRect(CGRect(x: thumb.maxX + 28, y: row.midY + 6, width: [250, 210, 280][i], height: 28), 14).fill()
        color(0x2B2B33, 0.32).setFill()
        roundedRect(CGRect(x: thumb.maxX + 28, y: row.midY - 34, width: [150, 180, 120][i], height: 22), 11).fill()
    }
    return true
}

func png(_ image: NSImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
if args.count > 1 {
    try png(image, size: 1024).write(to: URL(fileURLWithPath: args[1]))
    print("Wrote \(args[1])")
    exit(0)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(image, size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(image, size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
