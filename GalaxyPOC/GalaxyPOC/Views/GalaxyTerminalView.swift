import AppKit
import SwiftTerm

/// Custom terminal view that extends LocalProcessTerminalView.
/// This allows us to intercept terminal events (like bell) without
/// replacing the terminalDelegate, which breaks SwiftTerm's internal behavior.
class GalaxyTerminalView: LocalProcessTerminalView {
    /// Callback invoked when terminal receives a bell (BEL character)
    var onBell: (() -> Void)?

    /// Callback invoked when PTY output is received (for busy state detection)
    var onDataReceived: (() -> Void)?

    /// Override bell() to intercept bell events without replacing terminalDelegate
    /// We don't call super.bell() because we handle all bell behavior through onBell callback
    public override func bell(source: Terminal) {
        onBell?()
    }

    /// Override dataReceived to detect PTY output activity.
    /// Fires on SwiftTerm's dispatch queue — callers must dispatch to main for UI updates.
    public override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?()
    }
}
