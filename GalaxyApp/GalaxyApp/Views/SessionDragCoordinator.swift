import Foundation
import SwiftUI

/// Manages drag state for session reordering in the sidebar.
/// Tracks the dragged session, calculates swap thresholds, and triggers array swaps.
class SessionDragCoordinator: ObservableObject {
    @Published var isDragging: Bool = false
    @Published var draggedSessionId: UUID?
    @Published var dragOffsetY: CGFloat = 0          // Preview Y offset from original position
    @Published var currentArrayIndex: Int = 0        // Current position in array (updates as swaps happen)

    var dragStartY: CGFloat = 0                      // Screen Y at drag start
    var dragStartIndex: Int = 0                      // Original array index
    var rowHeight: CGFloat = 44                      // Height of one session row
    var totalSessionCount: Int = 0                   // Total sessions (for boundary clamping)

    /// Called when preview crosses 50% threshold and a swap is needed
    var onSwapNeeded: ((Int, Int) -> Void)?

    // MARK: - Auto-scroll support

    /// Sidebar visible bounds in screen coordinates (set by SessionSidebar)
    var sidebarScreenFrame: CGRect = .zero

    /// Edge zone size for triggering auto-scroll
    private let autoScrollEdgeZone: CGFloat = 50

    /// Called when auto-scroll should happen (passes session ID to scroll to)
    var onScrollToSession: ((UUID) -> Void)?

    /// All session IDs in order (set by SessionSidebar for scroll targeting)
    var sessionIds: [UUID] = []

    /// Timer for continuous auto-scrolling
    private var autoScrollTimer: Timer?

    /// Current auto-scroll direction: -1 = up, 0 = none, +1 = down
    private var autoScrollDirection: Int = 0

    func startDrag(sessionId: UUID, index: Int, startY: CGFloat) {
        isDragging = true
        draggedSessionId = sessionId
        dragStartY = startY
        dragStartIndex = index
        currentArrayIndex = index
        dragOffsetY = 0
        autoScrollDirection = 0
    }

    func updateDrag(currentY: CGFloat) {
        guard isDragging, totalSessionCount > 0 else { return }

        // APPROACH 2: Decouple visual position from swap logic
        // Preview position follows mouse directly; swaps happen based on where preview IS

        // 1. Calculate pure mouse offset (no adjustment for swaps)
        let mouseDelta = dragStartY - currentY  // Inverted because screen Y increases downward

        // 2. Only allow swaps when mouse is within the visible sidebar bounds
        // This prevents swapping with off-screen items which causes issues
        let mouseInBounds = sidebarScreenFrame.height > 0 &&
            currentY >= sidebarScreenFrame.minY &&
            currentY <= sidebarScreenFrame.maxY

        if mouseInBounds {
            // 3. Calculate where the preview's center is in "row space"
            let previewTopY = CGFloat(dragStartIndex) * rowHeight + mouseDelta
            let previewCenterY = previewTopY + (rowHeight / 2)

            // 4. Determine which row index the preview center is over
            let targetIndex = Int(previewCenterY / rowHeight)
            let clampedTarget = max(0, min(totalSessionCount - 1, targetIndex))

            // 5. Swap until placeholder catches up to where preview is
            // Use while loop to handle fast mouse movement that skips multiple rows
            while clampedTarget > currentArrayIndex {
                let nextIndex = currentArrayIndex + 1
                if nextIndex < totalSessionCount {
                    onSwapNeeded?(currentArrayIndex, nextIndex)
                    currentArrayIndex = nextIndex
                } else {
                    break
                }
            }
            while clampedTarget < currentArrayIndex {
                let prevIndex = currentArrayIndex - 1
                if prevIndex >= 0 {
                    onSwapNeeded?(currentArrayIndex, prevIndex)
                    currentArrayIndex = prevIndex
                } else {
                    break
                }
            }
        }

        // 6. Clamp visual offset so preview stays within list bounds
        // Preview is positioned at dragStartIndex, so clamp relative to that
        let minOffset = -CGFloat(dragStartIndex) * rowHeight  // Would put preview at top (index 0)
        let maxOffset = CGFloat(totalSessionCount - 1 - dragStartIndex) * rowHeight  // Would put preview at bottom

        dragOffsetY = max(minOffset, min(maxOffset, mouseDelta))

        // Check for auto-scroll based on mouse position relative to sidebar bounds
        updateAutoScroll(mouseScreenY: currentY)
    }

    /// Check if mouse is near sidebar edges and manage auto-scroll timer
    /// NOTE: Auto-scroll disabled - causes sync issues with drag preview
    /// User can manually scroll (trackpad) while dragging if needed
    private func updateAutoScroll(mouseScreenY: CGFloat) {
        return  // Auto-scroll disabled
        guard sidebarScreenFrame.height > 0 else { return }

        // Screen Y is inverted (0 at bottom), sidebar frame is in screen coords
        let sidebarTop = sidebarScreenFrame.maxY
        let sidebarBottom = sidebarScreenFrame.minY

        let newDirection: Int
        if mouseScreenY > sidebarTop - autoScrollEdgeZone && currentArrayIndex > 0 {
            // Near top edge and can scroll up
            newDirection = -1
        } else if mouseScreenY < sidebarBottom + autoScrollEdgeZone && currentArrayIndex < totalSessionCount - 1 {
            // Near bottom edge and can scroll down
            newDirection = 1
        } else {
            newDirection = 0
        }

        // Start or stop timer based on direction change
        if newDirection != autoScrollDirection {
            autoScrollDirection = newDirection
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil

            if newDirection != 0 {
                // Start continuous scrolling
                autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.performAutoScroll()
                }
                // Perform first scroll immediately
                performAutoScroll()
            }
        }
    }

    /// Scroll one session in the current auto-scroll direction
    private func performAutoScroll() {
        guard autoScrollDirection != 0, !sessionIds.isEmpty else { return }

        let targetIndex: Int
        if autoScrollDirection < 0 {
            // Scroll up - target the session above current
            targetIndex = max(0, currentArrayIndex - 1)
        } else {
            // Scroll down - target the session below current
            targetIndex = min(sessionIds.count - 1, currentArrayIndex + 1)
        }

        guard targetIndex >= 0 && targetIndex < sessionIds.count else { return }
        let targetId = sessionIds[targetIndex]
        onScrollToSession?(targetId)

        // Adjust dragStartY to compensate for scroll movement
        // This keeps the placeholder aligned with the mouse as content scrolls
        // Screen Y increases upward (macOS), so:
        // - Scrolling up (showing items above) shifts content DOWN visually → decrease dragStartY
        // - Scrolling down (showing items below) shifts content UP visually → increase dragStartY
        if autoScrollDirection < 0 {
            dragStartY -= rowHeight
        } else {
            dragStartY += rowHeight
        }
        // Note: Normal mouseDragged → updateDrag() calls will handle recalculating dragOffsetY
    }

    func endDrag() {
        isDragging = false
        draggedSessionId = nil
        dragOffsetY = 0
        currentArrayIndex = 0
        dragStartIndex = 0
        dragStartY = 0

        // Clean up auto-scroll
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }
}
