import AppKit

/// AppKit NSView that handles mouse events directly for smooth drag-to-reorder.
/// This view renders the grip icon and handles cursor changes + drag callbacks.
class DragHandleNSView: NSView {
    var sessionId: UUID?
    var sessionIndex: Int = 0
    var onDragStart: ((UUID, Int, CGFloat) -> Void)?
    var onDragUpdate: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onSidebarFrameUpdate: ((CGRect) -> Void)?

    private var isDragging = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    // Grip icon dimensions
    private let lineWidth: CGFloat = 8
    private let lineHeight: CGFloat = 1.5
    private let lineSpacing: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }  // Use top-left origin for consistency

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw 3 horizontal lines (grip icon)
        let color: NSColor = isHovered || isDragging
            ? .secondaryLabelColor
            : .secondaryLabelColor.withAlphaComponent(0.3)
        color.setFill()

        let totalHeight = (lineHeight * 3) + (lineSpacing * 2)
        let startY = (bounds.height - totalHeight) / 2
        let startX = (bounds.width - lineWidth) / 2

        for i in 0..<3 {
            let y = startY + CGFloat(i) * (lineHeight + lineSpacing)
            let rect = NSRect(x: startX, y: y, width: lineWidth, height: lineHeight)
            NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if !isDragging {
            NSCursor.openHand.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isDragging {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let sessionId = sessionId else { return }

        isDragging = true
        NSCursor.closedHand.set()
        needsDisplay = true
        StatusLineService.shared.pauseUpdates()  // Pause for performance

        let screenY = NSEvent.mouseLocation.y
        onDragStart?(sessionId, sessionIndex, screenY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        NSCursor.closedHand.set()  // Reinforce cursor during drag

        let screenY = NSEvent.mouseLocation.y

        // Update sidebar frame for auto-scroll edge detection
        // Use the enclosing scroll view's frame if available, otherwise estimate from window
        if let scrollView = enclosingScrollView {
            let scrollBoundsInWindow = scrollView.convert(scrollView.bounds, to: nil)
            if let window = scrollView.window {
                let screenFrame = window.convertToScreen(scrollBoundsInWindow)
                onSidebarFrameUpdate?(screenFrame)
            }
        }

        onDragUpdate?(screenY)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }

        isDragging = false
        StatusLineService.shared.resumeUpdates()  // Resume after drag

        // Reset cursor based on whether still hovering
        if isHovered {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }

        needsDisplay = true
        onDragEnd?()
    }
}
