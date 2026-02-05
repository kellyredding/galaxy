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

    func startDrag(sessionId: UUID, index: Int, startY: CGFloat) {
        isDragging = true
        draggedSessionId = sessionId
        dragStartY = startY
        dragStartIndex = index
        currentArrayIndex = index
        dragOffsetY = 0
    }

    func updateDrag(currentY: CGFloat) {
        guard isDragging, totalSessionCount > 0 else { return }

        // Calculate raw offset from start position
        let rawOffset = dragStartY - currentY  // Inverted because screen Y increases downward

        // Calculate where the preview center is relative to array positions
        // The preview's "logical position" in the array based on its visual position
        let offsetFromOriginal = rawOffset / rowHeight
        let targetPosition = CGFloat(dragStartIndex) + offsetFromOriginal

        // Check if we need to swap with adjacent item
        // Swap when preview center crosses 50% of the adjacent row
        if currentArrayIndex < Int(targetPosition + 0.5) {
            // Moving down - swap with next item
            let nextIndex = currentArrayIndex + 1
            // Clamp: don't go beyond last session
            if nextIndex < totalSessionCount {
                if let onSwap = onSwapNeeded {
                    onSwap(currentArrayIndex, nextIndex)
                }
                currentArrayIndex = nextIndex
            }
        } else if currentArrayIndex > Int(targetPosition + 0.5) {
            // Moving up - swap with previous item
            let prevIndex = currentArrayIndex - 1
            // Clamp: don't go above first session
            if prevIndex >= 0 {
                if let onSwap = onSwapNeeded {
                    onSwap(currentArrayIndex, prevIndex)
                }
                currentArrayIndex = prevIndex
            }
        }

        // Update visual offset
        // The offset is relative to where the item WOULD be if at dragStartIndex
        // Since currentArrayIndex changes, we adjust the visual offset accordingly
        let indexDelta = currentArrayIndex - dragStartIndex
        var newOffset = rawOffset - (CGFloat(indexDelta) * rowHeight)

        // Clamp visual offset so preview stays within list bounds
        // At index 0: can't go above 0 (negative offset from position 0)
        // At last index: can't go below last position
        let minOffset = -CGFloat(currentArrayIndex) * rowHeight  // Would put preview at top (index 0)
        let maxOffset = CGFloat(totalSessionCount - 1 - currentArrayIndex) * rowHeight  // Would put preview at bottom

        newOffset = max(minOffset, min(maxOffset, newOffset))
        dragOffsetY = newOffset
    }

    func endDrag() {
        isDragging = false
        draggedSessionId = nil
        dragOffsetY = 0
        currentArrayIndex = 0
        dragStartIndex = 0
        dragStartY = 0
    }
}
