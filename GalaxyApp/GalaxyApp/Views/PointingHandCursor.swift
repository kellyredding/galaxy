import AppKit
import SwiftUI

extension View {
    /// Hand cursor while the pointer is over a clickable control.
    ///
    /// Not to be applied to a disabled control. The cursor is part of the
    /// affordance, so offering it on something that will not respond promises
    /// what the click cannot deliver.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
