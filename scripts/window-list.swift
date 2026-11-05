// Lists on-screen windows of one app as tab-separated lines: id, layer, x, y, width, height, title.
// The app is given by its window owner name ("Bambu Studio") or its process id.
//   swift scripts/window-list.swift "Bambu Studio"   (or the binary scripts/bambu-gui-check.sh builds)
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Bambu Studio"
let pid = Int(owner)
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info where (w[kCGWindowOwnerName as String] as? String) == owner || (pid != nil && (w[kCGWindowOwnerPID as String] as? Int) == pid) {
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let title = (w[kCGWindowName as String] as? String ?? "").replacingOccurrences(of: "\t", with: " ")
    print("\(id)\t\(layer)\t\(Int(b["X"] ?? 0))\t\(Int(b["Y"] ?? 0))\t\(Int(b["Width"] ?? 0))\t\(Int(b["Height"] ?? 0))\t\(title)")
}
