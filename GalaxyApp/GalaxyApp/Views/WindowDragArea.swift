import AppKit
import SwiftUI

/// Restores title-bar dragging over the control strip, which
/// `.fullSizeContentView` covers.
///
/// Mounted only in the strip's two flexible gaps. A representable
/// becomes a real `NSView` in the AppKit hierarchy while SwiftUI's own
/// controls do not, so one spanning the whole strip would swallow
/// mouse-downs meant for the tabs and glyphs drawn above it.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            performDoubleClickAction(on: window)
            return
        }
        window.performDrag(with: event)
    }

    /// `performDrag` covers the drag but not the double click, which a
    /// real title bar routes through the Dock pane's "Double-click a
    /// window's title bar to" setting.
    private func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard
            .string(forKey: "AppleActionOnDoubleClick")
        {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
