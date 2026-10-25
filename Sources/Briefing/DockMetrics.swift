import AppKit
import SwiftUI

/// How much of a screen the Dock occupies, so content can keep its distance from it.
///
/// When the Dock is always shown, macOS reports exactly that through `visibleFrame`.
/// When it hides automatically, `visibleFrame` ignores it — but it still slides in on hover —
/// so its size is estimated from the Dock's own settings (tile size, side of the screen).
enum DockMetrics {
    static func insets(for screen: NSScreen) -> EdgeInsets {
        let frame = screen.frame
        let visible = screen.visibleFrame

        let measured = EdgeInsets(
            top: 0,
            leading: max(0, visible.minX - frame.minX),
            bottom: max(0, visible.minY - frame.minY),
            trailing: max(0, frame.maxX - visible.maxX)
        )
        if measured.leading > 0 || measured.bottom > 0 || measured.trailing > 0 {
            return measured
        }

        // Auto-hidden Dock (or one on another display): estimate its thickness.
        // The Dock appears on the primary display, which is where the dashboard is shown.
        guard screen == NSScreen.screens.first else { return EdgeInsets() }

        let tile = (pref("tilesize") as? NSNumber)?.doubleValue ?? 48
        let thickness = CGFloat(min(max(tile, 16), 128)) + 22    // icon + the Dock's own padding
        switch pref("orientation") as? String {
        case "left": return EdgeInsets(top: 0, leading: thickness, bottom: 0, trailing: 0)
        case "right": return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: thickness)
        default: return EdgeInsets(top: 0, leading: 0, bottom: thickness, trailing: 0)
        }
    }

    private static func pref(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString)
    }
}
