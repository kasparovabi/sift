import CoreGraphics
import Foundation

// Prints the CGWindowID of the largest on-screen normal window owned by an app
// whose name (ignoring spaces) is "ClaudeOS". Lets us screencapture -l<id> the
// window regardless of focus or z-order.
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
var best: (id: Int, area: CGFloat)?
for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String else { continue }
    guard owner.replacingOccurrences(of: " ", with: "") == "ClaudeOS" else { continue }
    guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if best == nil || area > best!.area { best = (number, area) }
}
if let best { print(best.id) } else { exit(2) }
