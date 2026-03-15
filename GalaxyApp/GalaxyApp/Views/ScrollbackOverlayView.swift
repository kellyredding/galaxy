import AppKit
import SwiftTerm

/// Container NSView that holds a ScrollbackTerminalView and a floating pill
/// indicator. Draws a 1px accent-color border around the entire view.
class ScrollbackOverlayView: NSView {
    let scrollbackTerminalView: ScrollbackTerminalView
    private let pillLabel: NSTextField

    init(frame: NSRect, scrollbackTerminalView: ScrollbackTerminalView) {
        self.scrollbackTerminalView = scrollbackTerminalView
        self.pillLabel = NSTextField(labelWithString: "Scrollback · Esc to exit")
        super.init(frame: frame)
        wantsLayer = true

        // Add scrollback terminal view filling the entire frame
        scrollbackTerminalView.frame = bounds
        scrollbackTerminalView.autoresizingMask = [.width, .height]
        addSubview(scrollbackTerminalView)

        // Configure pill indicator
        configurePill()

        // Draw 1px accent-color border
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Pill Indicator

    private func configurePill() {
        pillLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        pillLabel.textColor = contrastingTextColor()
        pillLabel.backgroundColor = NSColor.controlAccentColor
        pillLabel.drawsBackground = true
        pillLabel.isBezeled = false
        pillLabel.isEditable = false
        pillLabel.isSelectable = false
        pillLabel.alignment = .center
        pillLabel.sizeToFit()

        // Tight padding — flush against the top-right corner
        let hPadding: CGFloat = 6
        let vPadding: CGFloat = 2
        let pillWidth = pillLabel.frame.width + hPadding * 2
        let pillHeight = pillLabel.frame.height + vPadding * 2

        // Anchor flush to top-right corner (inside the 1px border)
        pillLabel.frame = NSRect(
            x: bounds.width - pillWidth - 1,
            y: bounds.height - pillHeight - 1,
            width: pillWidth,
            height: pillHeight
        )
        pillLabel.autoresizingMask = [.minXMargin, .minYMargin]

        // Vertically center the text within the pill by using a
        // centered baseline offset via the cell's drawing rect
        (pillLabel.cell as? NSTextFieldCell)?.isScrollable = false

        // Square corners matching the terminal view
        pillLabel.wantsLayer = true
        pillLabel.layer?.cornerRadius = 0

        addSubview(pillLabel, positioned: .above, relativeTo: scrollbackTerminalView)
    }

    /// Compute contrasting text color based on accent color luminance.
    /// luma = 0.299*r + 0.587*g + 0.114*b; use black if luma > 0.5, white otherwise.
    private func contrastingTextColor() -> NSColor {
        guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return .white
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.5 ? .black : .white
    }

    // MARK: - Event Passthrough

    /// Pill must be transparent to all events (scroll, click, drag) so they
    /// pass through to the ScrollbackTerminalView underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // If the hit is on the pill, pass through to the terminal view
        let pointInPill = pillLabel.convert(point, from: self)
        if pillLabel.bounds.contains(pointInPill) {
            return scrollbackTerminalView.hitTest(convert(point, to: scrollbackTerminalView))
        }
        return super.hitTest(point)
    }

    // MARK: - Dynamic Accent Color

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Update border and pill colors when accent color changes
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        pillLabel.backgroundColor = NSColor.controlAccentColor
        pillLabel.textColor = contrastingTextColor()
    }
}
