import SwiftUI
import AppKit

/// SwiftUI wrapper for the AppKit drag handle view.
/// Provides smooth mouse event handling for drag-to-reorder functionality.
struct SessionRowDragHandle: NSViewRepresentable {
    let sessionId: UUID
    let sessionIndex: Int

    // Access coordinator via environment - avoids per-row observation
    @EnvironmentObject var coordinator: SessionDragCoordinator

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.sessionId = sessionId
        view.sessionIndex = sessionIndex
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.sessionId = sessionId
        nsView.sessionIndex = sessionIndex

        // Set callbacks each time - captures current coordinator reference
        nsView.onDragStart = { [weak coordinator] id, index, startY in
            coordinator?.startDrag(sessionId: id, index: index, startY: startY)
        }
        nsView.onDragUpdate = { [weak coordinator] currentY in
            coordinator?.updateDrag(currentY: currentY)
        }
        nsView.onDragEnd = { [weak coordinator] in
            coordinator?.endDrag()
        }
    }
}
