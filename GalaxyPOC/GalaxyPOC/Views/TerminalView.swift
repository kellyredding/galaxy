import SwiftUI
import SwiftTerm
import AppKit

// Direct NSView wrapper with explicit focus handling
struct FocusableTerminalView: NSViewRepresentable {
    let session: Session
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(terminalView: session.terminalView)
        return container
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        if isActive {
            nsView.requestFocus()
        }
    }
}

// Container that properly handles focus and passes events to terminal
class TerminalHostView: NSView {
    let terminalView: LocalProcessTerminalView
    private var isSetUp = false

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if !isSetUp && window != nil {
            setupTerminal()
            isSetUp = true
        }
    }

    private func setupTerminal() {
        // Add terminal view with autoresizing
        terminalView.frame = bounds
        terminalView.autoresizingMask = [.width, .height]
        addSubview(terminalView)

        // Request focus after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.requestFocus()
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
    }

    func requestFocus() {
        guard let window = window else { return }

        // Force terminal to become first responder
        DispatchQueue.main.async { [weak self] in
            guard let terminal = self?.terminalView else { return }
            window.makeFirstResponder(terminal)
        }
    }

    // Forward mouse events to request focus
    override func mouseDown(with event: NSEvent) {
        requestFocus()
        // Let the event propagate normally - terminal will get it as first responder
        super.mouseDown(with: event)
    }

    // Don't accept first responder - let terminal be the responder
    override var acceptsFirstResponder: Bool { false }
}
