import CoreGraphics
import Foundation

// Prints "x y w h" for the largest on-screen normal window owned by the named app.
// Uses CGWindowList rather than System Events so no Automation permission is needed.
let app = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sift"
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var best: (CGFloat, CGRect)? = nil
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == app,
          (w[kCGWindowLayer as String] as? Int) == 0,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
          width > 400 else { continue }
    let area = width * height
    if best == nil || area > best!.0 { best = (area, CGRect(x: x, y: y, width: width, height: height)) }
}
guard let r = best?.1 else { exit(2) }
print("\(Int(r.origin.x)) \(Int(r.origin.y)) \(Int(r.size.width)) \(Int(r.size.height))")
