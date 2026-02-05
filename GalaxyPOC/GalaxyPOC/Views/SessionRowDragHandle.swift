import SwiftUI
import AppKit

/// SwiftUI wrapper for the AppKit drag handle view.
/// Provides smooth mouse event handling for drag-to-reorder functionality.
struct SessionRowDragHandle: NSViewRepresentable {
    let sessionId: UUID
    let sessionIndex: Int
    @ObservedObject var coordinator: SessionDragCoordinator

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.sessionId = sessionId
        view.sessionIndex = sessionIndex
        view.onDragStart = { id, index, startY in
            coordinator.startDrag(sessionId: id, index: index, startY: startY)
        }
        view.onDragUpdate = { currentY in
            coordinator.updateDrag(currentY: currentY)
        }
        view.onDragEnd = {
            coordinator.endDrag()
        }
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.sessionId = sessionId
        nsView.sessionIndex = sessionIndex
        // Callbacks are already set and reference the coordinator
    }
}
