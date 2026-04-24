import AppKit
import SwiftUI

/// 28px bar above the Shell pane. Shows a "Shell" label +
/// terminal icon centered, doubles as the divider drag
/// handle, and resets the split to 50/50 on double-click.
///
/// Uses an AppKit NSView (`ShellPaneBarNSView`) for drag
/// tracking because SwiftUI's built-in `DragGesture` gives
/// unreliable cursor feedback and double-click handling in
/// this context. Mirrors the pattern used by
/// `ResizeHandleNSView` in `ContentView.swift`.
struct ShellPaneBar: NSViewRepresentable {
    /// Fired once when a drag gesture begins (mouseDown
    /// other than a double-click). The split container
    /// uses this to enter "drag preview" mode — the panes
    /// stay at their current heights while a ghost line
    /// tracks the proposed new divider Y.
    let onDragBegan: () -> Void

    /// Fired repeatedly during drag with the cursor's Y
    /// delta from drag-start (screen coords, so positive =
    /// cursor moved up, negative = cursor moved down).
    let onDrag: (CGFloat) -> Void

    /// Fired once when the drag gesture ends (mouseUp).
    /// Committing the preview collapses the ghost line and
    /// snaps the panes to the new ratio with a single
    /// resize pass — avoiding the per-tick buffer reflow
    /// that live-dragging would cause.
    let onDragEnded: () -> Void

    /// Fired on double-click to reset the split ratio.
    let onResetSplit: () -> Void

    func makeNSView(context: Context) -> ShellPaneBarNSView {
        let view = ShellPaneBarNSView()
        view.onDragBegan = onDragBegan
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        view.onResetSplit = onResetSplit
        return view
    }

    func updateNSView(
        _ nsView: ShellPaneBarNSView, context: Context
    ) {
        nsView.onDragBegan = onDragBegan
        nsView.onDrag = onDrag
        nsView.onDragEnded = onDragEnded
        nsView.onResetSplit = onResetSplit
    }
}

final class ShellPaneBarNSView: NSView {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onResetSplit: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragStartY: CGFloat = 0
    private var isDragging = false

    // Stored so we can re-resolve their cgColor values when the
    // effective appearance changes (dark ↔ light). Layer-backed
    // cgColors are "frozen" at set time and don't track dynamic
    // NSColors automatically.
    private let topLine = NSView()
    private let bottomLine = NSView()

    private let iconView: NSImageView = {
        let img = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Shell"
        )
        let v = NSImageView(image: img ?? NSImage())
        v.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let labelField: NSTextField = {
        let field = NSTextField(labelWithString: "Shell")
        field.font = NSFont.systemFont(
            ofSize: 12, weight: .medium
        )
        field.textColor = .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        topLine.wantsLayer = true
        topLine.translatesAutoresizingMaskIntoConstraints = false

        bottomLine.wantsLayer = true
        bottomLine.translatesAutoresizingMaskIntoConstraints =
            false

        // Apply the theme-aware colors once now; re-applied on
        // every effective-appearance change below.
        applyAppearanceColors()

        let stack = NSStackView(
            views: [iconView, labelField]
        )
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topLine)
        addSubview(bottomLine)
        addSubview(stack)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leftAnchor.constraint(
                equalTo: leftAnchor
            ),
            topLine.rightAnchor.constraint(
                equalTo: rightAnchor
            ),
            topLine.heightAnchor.constraint(
                equalToConstant: 1
            ),

            bottomLine.bottomAnchor.constraint(
                equalTo: bottomAnchor
            ),
            bottomLine.leftAnchor.constraint(
                equalTo: leftAnchor
            ),
            bottomLine.rightAnchor.constraint(
                equalTo: rightAnchor
            ),
            bottomLine.heightAnchor.constraint(
                equalToConstant: 1
            ),

            stack.centerXAnchor.constraint(
                equalTo: centerXAnchor
            ),
            stack.centerYAnchor.constraint(
                equalTo: centerYAnchor
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .activeInActiveApp,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if !isDragging {
            NSCursor.resizeUpDown.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onResetSplit?()
            return
        }
        isDragging = true
        dragStartY = NSEvent.mouseLocation.y
        NSCursor.resizeUpDown.set()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let delta = NSEvent.mouseLocation.y - dragStartY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        isDragging = false
        NSCursor.arrow.set()
        if wasDragging {
            onDragEnded?()
        }
    }

    // MARK: - Dark/light appearance

    /// macOS auto-toggles `effectiveAppearance` when the user
    /// switches between Light and Dark mode. Layer-backed
    /// cgColors don't track dynamic NSColors, so we re-resolve
    /// them here to keep the bar readable after a theme flip.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    /// Resolve theme-aware colors for the bar background and
    /// the top/bottom border lines under the current effective
    /// appearance. Called from init and on appearance changes.
    ///
    /// Matches the Galaxy window's title/toolbar chrome:
    /// - Background: solid `NSColor.windowBackgroundColor`
    ///   (fully opaque so the stopped-session backdrop
    ///   doesn't bleed through when the shell pane is
    ///   expanded above a stopped Claude session)
    /// - Borders: `NSColor.separatorColor` (the semantic
    ///   macOS separator tint that adapts light ↔ dark)
    private func applyAppearanceColors() {
        let apply = {
            self.layer?.backgroundColor =
                NSColor.windowBackgroundColor.cgColor
            let borderColor =
                NSColor.separatorColor.cgColor
            self.topLine.layer?.backgroundColor = borderColor
            self.bottomLine.layer?.backgroundColor = borderColor
        }
        if #available(macOS 11.0, *) {
            effectiveAppearance
                .performAsCurrentDrawingAppearance(apply)
        } else {
            apply()
        }
    }
}
