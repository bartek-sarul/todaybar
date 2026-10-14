// Generates AppIcon.icns: swiftc tools/icon.swift -o /tmp/icon && /tmp/icon
import AppKit

func render(_ s: Int) -> Data {
    let f = CGFloat(s) / 1024
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: f, y: f)
    func rr(_ r: CGRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }
    // tile (macOS icon grid: 824pt body inside 1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowOffset = NSSize(width: 0, height: -12); sh.shadowBlurRadius = 24; sh.set()
    NSColor.black.setFill(); rr(tile, 185).fill()
    ctx.restoreGState()
    ctx.saveGState(); rr(tile, 185).addClip()
    NSGradient(colors: [NSColor(red: 0.25, green: 0.55, blue: 1, alpha: 1), NSColor(red: 0.30, green: 0.30, blue: 0.85, alpha: 1)])!.draw(in: tile, angle: -90)
    ctx.restoreGState()
    // calendar card
    let card = CGRect(x: 232, y: 232, width: 560, height: 560)
    ctx.saveGState()
    let sh2 = NSShadow(); sh2.shadowColor = NSColor.black.withAlphaComponent(0.25); sh2.shadowOffset = NSSize(width: 0, height: -10); sh2.shadowBlurRadius = 20; sh2.set()
    NSColor.white.setFill(); rr(card, 70).fill()
    ctx.restoreGState()
    ctx.saveGState(); rr(card, 70).addClip()
    NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
    CGRect(x: card.minX, y: card.maxY - 150, width: card.width, height: 150).fill()
    ctx.restoreGState()
    // rings
    NSColor(white: 1, alpha: 0.95).setFill()
    for x in [card.minX + 150, card.maxX - 150] { rr(CGRect(x: x - 22, y: card.maxY - 60, width: 44, height: 90), 22).fill() }
    // rows: events, today highlighted
    let ink = NSColor(white: 0.82, alpha: 1)
    for (i, hl) in [false, true, false].enumerated() {
        let y = card.maxY - 270 - CGFloat(i) * 115
        if hl { NSColor(red: 0.25, green: 0.55, blue: 1, alpha: 0.18).setFill(); rr(CGRect(x: card.minX + 40, y: y - 30, width: card.width - 80, height: 84), 30).fill() }
        (hl ? NSColor(red: 0.25, green: 0.55, blue: 1, alpha: 1) : ink).setFill()
        NSBezierPath(ovalIn: CGRect(x: card.minX + 70, y: y - 2, width: 28, height: 28)).fill()
        rr(CGRect(x: card.minX + 125, y: y + 2, width: hl ? 330 : (i == 0 ? 280 : 220), height: 20), 10).fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b).png"))
    try! render(b * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", "AppIcon.icns"]; try! p.run(); p.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "icon-preview.png"))
print(NSTemporaryDirectory() + "icon-preview.png")
