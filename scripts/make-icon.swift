// Draws MacGlass' app icon (a CRT screen with scanlines) into an .iconset folder.
//   swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Body
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(calibratedWhite: 0.32, alpha: 1), NSColor(calibratedWhite: 0.12, alpha: 1)])?
        .draw(in: bodyPath, angle: -90)
    // Screen
    let screen = body.insetBy(dx: s * 0.08, dy: s * 0.08)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.1, yRadius: s * 0.1)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.85, alpha: 1),
                        NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.45, alpha: 1)])?
        .draw(in: screenPath, angle: -60)
    // Scanlines
    NSGraphicsContext.current?.saveGraphicsState()
    screenPath.addClip()
    let lines = 16
    let step = screen.height / CGFloat(lines)
    NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
    for i in 0..<lines {
        NSRect(x: screen.minX, y: screen.minY + CGFloat(i) * step, width: screen.width, height: step * 0.4).fill()
    }
    // Glass reflection
    let glare = NSBezierPath(ovalIn: NSRect(x: screen.minX - screen.width * 0.2, y: screen.midY,
                                            width: screen.width * 0.9, height: screen.height * 0.8))
    NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
    glare.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base * scale)?.write(to: out.appendingPathComponent(name))
    }
}
