import AppKit
import Foundation
let root = CommandLine.arguments[1]
let dir = URL(fileURLWithPath: root).appendingPathComponent("ThoughtStream.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let s = CGFloat(pixels) / 1024
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 45*s, dy: 45*s), xRadius: 205*s, yRadius: 205*s)
        NSGradient(starting: NSColor(red: 0.30, green: 0.27, blue: 0.78, alpha: 1), ending: NSColor(red: 0.12, green: 0.16, blue: 0.36, alpha: 1))!.draw(in: shape, angle: -75)
        for (i, width) in [560.0, 420.0, 280.0].enumerated() {
            let row = NSRect(x: 232*s, y: CGFloat(652-i*166)*s, width: width*s, height: 76*s)
            NSColor.white.withAlphaComponent(CGFloat(1.0 - Double(i)*0.18)).setFill()
            NSBezierPath(roundedRect: row, xRadius: 38*s, yRadius: 38*s).fill()
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: dir.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
