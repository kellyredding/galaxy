import SwiftUI
import AppKit

/// SwiftUI wrapper for the AppKit drag handle view.
/// Provides smooth mouse event handling for drag-to-reorder
/// functionality. Used by both SessionRow and SessionMarkerRow —
/// "item" refers to either kind of sidebar row.
struct SessionRowDragHandle: NSViewRepresentable {
    let itemId: UUID
    let itemIndex: Int

    // Access coordinator via environment - avoids per-row observation
    @EnvironmentObject var coordinator: SessionDragCoordinator

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.itemId = itemId
        view.itemIndex = itemIndex
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.itemId = itemId
        nsView.itemIndex = itemIndex

        // Set callbacks each time - captures current coordinator reference
        nsView.onDragStart = { [weak coordinator] id, index, startY in
            coordinator?.startDrag(itemId: id, index: index, startY: startY)
        }
        nsView.onDragUpdate = { [weak coordinator] currentY in
            coordinator?.updateDrag(currentY: currentY)
        }
        nsView.onDragEnd = { [weak coordinator] in
            coordinator?.endDrag()
        }
        nsView.onSidebarFrameUpdate = { [weak coordinator] (frame: CGRect) in
            coordinator?.sidebarScreenFrame = frame
        }
    }
}
