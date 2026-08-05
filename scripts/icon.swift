import AppKit

// Renders a 1024×1024 app icon: dark gradient rounded square with a terminal
// prompt chevron and an accent underscore cursor. Output: /tmp/sift_icon_1024.png

let px = 1024
let size = CGFloat(px)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Rounded background + gradient
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.225
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.22, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.08, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Terminal chevron ">"
let chevron = NSBezierPath()
chevron.lineWidth = size * 0.065
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: size * 0.31, y: size * 0.63))
chevron.line(to: NSPoint(x: size * 0.47, y: size * 0.50))
chevron.line(to: NSPoint(x: size * 0.31, y: size * 0.37))
NSColor.white.setStroke()
chevron.stroke()

// Accent underscore cursor
let accent = NSColor(calibratedRed: 0.91, green: 0.58, blue: 0.34, alpha: 1)
let underscore = NSBezierPath(
    roundedRect: CGRect(x: size * 0.53, y: size * 0.355, width: size * 0.20, height: size * 0.055),
    xRadius: size * 0.025, yRadius: size * 0.025
)
accent.setFill()
underscore.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let url = URL(fileURLWithPath: "/tmp/sift_icon_1024.png")
try! png.write(to: url)
print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
