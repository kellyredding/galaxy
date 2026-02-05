import SwiftUI
import SwiftTerm
import AppKit

// Direct NSView wrapper with explicit focus handling
struct FocusableTerminalView: NSViewRepresentable {
    let session: Session
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(terminalView: session.terminalView, session: session)
        return container
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // Update session reference and active state for drag-drop filtering
        nsView.session = session
        nsView.isActive = isActive  // This triggers updateDragRegistration via didSet

        // Also update drag registration when session state changes (e.g., session stopped)
        nsView.refreshDragRegistration()

        if isActive {
            nsView.requestFocus()
        }
    }
}

// Container that properly handles focus, drag-drop, and passes events to terminal
class TerminalHostView: NSView {
    let terminalView: LocalProcessTerminalView
    var session: Session
    // Track if this is the active session - controls drag-drop registration
    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                updateDragRegistration()
            }
        }
    }
    private var isSetUp = false

    // Drag highlight overlay (drawn on top of terminal)
    private var dragHighlightView: DragHighlightView?

    // Drag-drop state
    private var isReceivingDrag = false {
        didSet {
            dragHighlightView?.isHighlighted = isReceivingDrag
        }
    }

    // Event monitor for Ctrl+Arrow key interception
    private var keyEventMonitor: Any?

    init(terminalView: LocalProcessTerminalView, session: Session) {
        self.terminalView = terminalView
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        // Note: Don't register for drags here - done dynamically via updateDragRegistration()

        // Set up key event monitor for Ctrl+Arrow → line navigation
        setupKeyEventMonitor()
    }

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Set up local event monitor to intercept Ctrl+Arrow for line navigation.
    /// Translates Ctrl+Left → Ctrl+A (beginning of line) and Ctrl+Right → Ctrl+E (end of line).
    /// This matches Terminal.app's configurable keyboard shortcuts behavior.
    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Only handle if our terminal is the first responder
            guard self.window?.firstResponder === self.terminalView else { return event }

            // Only intercept when Control is pressed without Option or Command
            let controlOnly = event.modifierFlags.intersection([.control, .option, .command]) == .control

            if controlOnly {
                switch event.keyCode {
                case 123: // Left arrow → beginning of line (Ctrl+A = 0x01)
                    self.terminalView.send([0x01])
                    return nil  // Consume the event
                case 124: // Right arrow → end of line (Ctrl+E = 0x05)
                    self.terminalView.send([0x05])
                    return nil  // Consume the event
                default:
                    break
                }
            }

            return event  // Pass through unhandled events
        }
    }

    /// Register or unregister for drag types based on active state.
    /// Only the active session should be a drop target.
    private func updateDragRegistration() {
        if isActive && session.isRunning && !session.hasExited {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    /// Called from updateNSView to refresh drag registration when session state changes
    func refreshDragRegistration() {
        updateDragRegistration()
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

        // Hide SwiftTerm's built-in scrollbar (it's private, so find via subviews)
        hideTerminalScrollbar()

        // Add drag highlight overlay ON TOP of terminal view
        let highlight = DragHighlightView(frame: bounds)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight, positioned: .above, relativeTo: terminalView)
        dragHighlightView = highlight

        // Request focus after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.requestFocus()
        }
    }

    /// Hide the built-in scrollbar from SwiftTerm
    private func hideTerminalScrollbar() {
        for subview in terminalView.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        dragHighlightView?.frame = bounds
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

    // MARK: - Drag and Drop

    /// Check if the session can accept drops (must be running AND active)
    private var canAcceptDrop: Bool {
        return isActive && session.isRunning && !session.hasExited
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop else {
            // Show "not allowed" cursor for stopped sessions
            NSCursor.operationNotAllowed.set()
            return []
        }

        // Validate that we have file URLs
        let dominated = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])

        if dominated {
            isReceivingDrag = true
            NSCursor.dragCopy.set()
            return .copy
        }

        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop else {
            NSCursor.operationNotAllowed.set()
            return []
        }

        NSCursor.dragCopy.set()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isReceivingDrag = false
        NSCursor.arrow.set()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrag = false
        NSCursor.arrow.set()

        guard canAcceptDrop else {
            return false
        }

        // Focus the window and activate the app when a file is dropped
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // Extract file URLs from the pasteboard
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }

        // Deduplicate URLs by path (some drag sources provide duplicates)
        var seenPaths = Set<String>()
        var uniqueUrls: [URL] = []
        for url in urls {
            let path = url.standardized.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                uniqueUrls.append(url)
            }
        }

        // Send raw paths (like Cmd+V paste) so Claude Code shows gray box treatment
        let pathsText = uniqueUrls.map { $0.path }.joined(separator: " ") + " "

        // Send to terminal with bracketed paste mode
        sendTextToTerminal(pathsText, asPaste: true)

        return true
    }

    // MARK: - Terminal Text Injection

    /// Send text to the terminal with bracketed paste mode support.
    /// Manually sends escape sequences via terminalView.send() - no clipboard involvement.
    private func sendTextToTerminal(_ text: String, asPaste: Bool) {
        let bracketedMode = terminalView.terminal.bracketedPasteMode

        if asPaste && bracketedMode {
            // Send bracketed paste sequences:
            // 1. Start sequence (ESC[200~)
            // 2. Text content
            // 3. End sequence (ESC[201~)
            terminalView.send(Array(EscapeSequences.bracketedPasteStart))
            terminalView.send(txt: text)
            terminalView.send(Array(EscapeSequences.bracketedPasteEnd))
        } else {
            // Send plain text
            terminalView.send(txt: text)
        }
    }
}

// MARK: - Drag Highlight Overlay View

/// Transparent overlay view that draws a highlight border when files are dragged over
class DragHighlightView: NSView {
    var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Critical: allow mouse events to pass through to terminal underneath
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isHighlighted else { return }

        // Draw border highlight with enough inset for clean corners
        // 1px border needs 0.5px inset from edge to render fully inside bounds
        // Plus a little extra margin so corners don't clip against parent edges
        let borderRect = bounds.insetBy(dx: 2, dy: 2)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: 3, yRadius: 3)
        borderPath.lineWidth = 1

        // Use system accent color
        NSColor.controlAccentColor.setStroke()
        borderPath.stroke()
    }

    // Allow mouse events to pass through to the terminal view underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
