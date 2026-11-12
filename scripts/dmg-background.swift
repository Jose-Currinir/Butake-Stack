// Draws the background of the installer window (build/dmg-background.tiff): a soft brand gradient,
// an arrow from the app to Aplicaciones and the instruction. 1x and 2x, joined by package-dmg.sh.
// Usage: swift scripts/dmg-background.swift <output-folder>
import AppKit

let width: CGFloat = 660, height: CGFloat = 420
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
let green = NSColor(srgbRed: 0.04, green: 0.51, blue: 0.28, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(srgbRed: 0.93, green: 0.97, blue: 0.95, alpha: 1)])!
        .draw(in: bounds, angle: -90)
    // Soft light behind each icon (Finder places them at y = 190 from the top).
    for x in [170.0, 490.0] {
        NSGradient(colors: [green.withAlphaComponent(0.10), green.withAlphaComponent(0)])!
            .draw(in: NSBezierPath(ovalIn: NSRect(x: x - 110, y: height - 190 - 110, width: 220, height: 220)), relativeCenterPosition: .zero)
    }
    // Arrow between them.
    let arrow = NSBezierPath()
    let y = height - 190
    arrow.move(to: NSPoint(x: 262, y: y)); arrow.line(to: NSPoint(x: 392, y: y))
    arrow.move(to: NSPoint(x: 376, y: y + 12)); arrow.line(to: NSPoint(x: 394, y: y)); arrow.line(to: NSPoint(x: 376, y: y - 12))
    arrow.lineWidth = 4; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    green.withAlphaComponent(0.75).setStroke(); arrow.stroke()
    // Instruction.
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: style]
    let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor(white: 0.42, alpha: 1), .paragraphStyle: style]
    NSAttributedString(string: "Arrastra Butake Stack a Aplicaciones", attributes: title).draw(in: NSRect(x: 0, y: 112, width: width, height: 24))
    NSAttributedString(string: "Luego ábrelo desde Aplicaciones: te mostrará cómo empezar.", attributes: detail).draw(in: NSRect(x: 0, y: 88, width: width, height: 20))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(scale: 1).write(to: output.appendingPathComponent("dmg-background.png"))
try render(scale: 2).write(to: output.appendingPathComponent("dmg-background@2x.png"))
