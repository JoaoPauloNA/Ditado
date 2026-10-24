import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.22, alpha: 1),
                   ending: NSColor(calibratedRed: 0.055, green: 0.08, blue: 0.09, alpha: 1))!.draw(in: background, angle: -70)
        let mint = NSColor(calibratedRed: 0.45, green: 0.92, blue: 0.78, alpha: 1)
        mint.setStroke()
        for (index, height) in [160, 300, 460, 580, 360, 240, 130].enumerated() {
            let line = NSBezierPath()
            line.lineWidth = 48
            line.lineCapStyle = .round
            let x = 272 + index * 80
            line.move(to: NSPoint(x: x, y: 512 - height / 2))
            line.line(to: NSPoint(x: x, y: 512 + height / 2))
            line.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
