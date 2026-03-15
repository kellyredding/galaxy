import SwiftUI
import SwiftTerm
import AppKit
import Combine

extension Notification.Name {
    static let enterScrollback = Notification.Name("enterScrollback")
}

// Direct NSView wrapper with explicit focus handling
struct FocusableTerminalView: NSViewRepresentable {
    let session: Session
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(terminalView: session.terminalView, session: session)
        return container
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        let wasActive = nsView.isActive

        // Update session reference and active state for drag-drop filtering
        nsView.session = session
        nsView.isActive = isActive  // This triggers updateDragRegistration via didSet

        // Also update drag registration when session state changes (e.g., session stopped)
        nsView.refreshDragRegistration()

        // Hide inactive terminals at the AppKit level so they don't intercept
        // NSDragging hitTest. SwiftUI's .allowsHitTesting(false) + .opacity(0)
        // don't set NSView.isHidden, so AppKit's hitTest still finds them.
        nsView.isHidden = !isActive

        // Only grab focus on activation transition, not every re-render.
        // Unconditional requestFocus() steals focus from rename TextFields
        // and other non-terminal first responders. Legitimate focus restoration
        // for tab/session switching is handled by TerminalContainerView's
        // onChange handlers via restoreTerminalFocus().
        if isActive && !wasActive {
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

    // MARK: - Scrollback State

    /// The scrollback overlay (holds ScrollbackTerminalView + pill).
    /// Non-nil when scrollback mode is active.
    private var scrollbackOverlay: ScrollbackOverlayView?

    /// True when the scrollback overlay is visible.
    var isScrollbackActive: Bool { scrollbackOverlay != nil }

    /// Cooldown flag — when true, scroll-wheel-up is ignored to prevent
    /// trackpad momentum from immediately re-creating the scrollback view.
    private var scrollbackCooldown = false
    private var scrollbackCooldownTimer: DispatchWorkItem?

    /// Combine subscriptions for live settings sync (font, theme, hasExited).
    private var cancellables = Set<AnyCancellable>()

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
        cancellables.removeAll()
        scrollbackCooldownTimer?.cancel()
    }

    /// Set up local event monitor to intercept Ctrl+Arrow for line navigation.
    /// Translates Ctrl+Left → Ctrl+A (beginning of line) and Ctrl+Right → Ctrl+E (end of line).
    /// This matches Terminal.app's configurable keyboard shortcuts behavior.
    ///
    /// Naturally safe during scrollback: the guard checks
    /// `self.window?.firstResponder === self.terminalView`, which fails when
    /// ScrollbackTerminalView is first responder, so no bytes are sent.
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

        // Add drag highlight overlay ON TOP of terminal view
        let highlight = DragHighlightView(frame: bounds)
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight, positioned: .above, relativeTo: terminalView)
        dragHighlightView = highlight

        // Wire up scroll-wheel-up interception for scrollback creation
        if let galaxyTV = terminalView as? GalaxyTerminalView {
            galaxyTV.onScrollUp = { [weak self] event in
                self?.handleScrollUp(event: event) ?? false
            }
        }

        // Observe session process exit — dismiss scrollback if process dies
        session.$hasExited
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exited in
                if exited { self?.dismissScrollback() }
            }
            .store(in: &cancellables)

        // Observe font size changes — apply to scrollback view if present
        session.$terminalFontSize
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Observe font family changes — apply to scrollback view if present
        SettingsManager.shared.$settings
            .map(\.terminalFontFamily)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Observe color theme changes — apply to scrollback view if present
        SettingsManager.shared.$settings
            .map(\.terminalColorThemeName)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySettingsToScrollback()
            }
            .store(in: &cancellables)

        // Observe Cmd+S menu action for scrollback entry
        NotificationCenter.default.publisher(for: .enterScrollback)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.enterScrollbackFromMenu()
            }
            .store(in: &cancellables)

        // Request focus after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.requestFocus()
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        dragHighlightView?.frame = bounds
        scrollbackOverlay?.frame = bounds
    }

    func requestFocus() {
        guard let window = window else { return }

        // If scrollback is active, make the scrollback view first responder
        // instead of the live terminal — otherwise scrollback is visible but
        // keyboard-dead after session switches.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let overlay = self.scrollbackOverlay {
                window.makeFirstResponder(overlay.scrollbackTerminalView)
            } else {
                window.makeFirstResponder(self.terminalView)
            }
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
        // Dismiss scrollback on file drag entry
        if isScrollbackActive {
            dismissScrollback()
        }

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

    // MARK: - Scrollback Lifecycle

    /// Enter scrollback mode from Cmd+S menu action. Only the active session's
    /// TerminalHostView should respond — all others ignore.
    private func enterScrollbackFromMenu() {
        guard isActive else { return }
        guard !isScrollbackActive else { return }

        let displayBuffer = terminalView.terminal.displayBuffer
        guard displayBuffer.yBase > 0 else { return }

        createScrollback(triggeringEvent: nil)
    }

    /// Handle scroll-wheel-up on the live terminal. Returns true if the event
    /// was consumed (scrollback overlay created), false to let normal scroll proceed.
    private func handleScrollUp(event: NSEvent) -> Bool {
        // Already in scrollback — let the overlay handle scroll events
        guard !isScrollbackActive else { return false }

        // Cooldown active — ignore to prevent momentum re-entry
        guard !scrollbackCooldown else { return false }

        // No scrollback content — nothing above the viewport to show
        let displayBuffer = terminalView.terminal.displayBuffer
        guard displayBuffer.yBase > 0 else { return false }

        createScrollback(triggeringEvent: event)
        return true
    }

    /// Create the scrollback overlay with a snapshot of the live terminal's buffer.
    /// If a triggering scroll event is provided, its delta is applied before the first draw.
    private func createScrollback(triggeringEvent: NSEvent? = nil) {
        // Step 3: Create scrollback view with the live terminal's frame
        let sbView = ScrollbackTerminalView(frame: terminalView.bounds)

        // Step 4: Apply the live terminal's font and color palette.
        // Font MUST be applied before buffer injection so cellDimension is
        // correct for the first draw.
        sbView.customBlockGlyphs = terminalView.customBlockGlyphs
        sbView.font = terminalView.font
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )
        sbView.nativeForegroundColor = theme.foregroundColor
        sbView.nativeBackgroundColor = theme.backgroundColorValue
        sbView.installColors(theme.swiftTermPalette)
        sbView.galaxyBoldForegroundColor = theme.boldForegroundColor

        // Step 5: Snapshot the live buffer (deep copy)
        let snapshot = terminalView.terminal.snapshotBuffer(terminalView.terminal.buffer)

        // Apply triggering scroll delta before first draw — prevents a
        // single-frame flash of identical content.
        if let event = triggeringEvent {
            let scrollLines = max(1, Int(event.deltaY))
            snapshot.yDisp = max(0, snapshot.yDisp - scrollLines)
        }

        // Step 6: Inject snapshot into scrollback view's terminal
        sbView.terminal.buffer = snapshot

        // Step 6b: Sync terminal dimensions to match the snapshot buffer
        sbView.terminal.cols = snapshot.cols
        sbView.terminal.rows = snapshot.rows

        // Dismiss callback
        sbView.onDismiss = { [weak self] in
            self?.dismissScrollback()
        }

        // Create overlay container with border and pill
        let overlay = ScrollbackOverlayView(frame: bounds, scrollbackTerminalView: sbView)
        overlay.autoresizingMask = [.width, .height]

        // Add above drag highlight so it's the topmost interactive layer
        addSubview(overlay, positioned: .above, relativeTo: dragHighlightView)
        scrollbackOverlay = overlay

        // Make scrollback view first responder for keyboard events
        window?.makeFirstResponder(sbView)

        // Force initial draw with correct scroll position
        sbView.setNeedsDisplay(sbView.bounds)
    }

    /// Dismiss and fully unload the scrollback overlay. Idempotent — safe to
    /// call from multiple exit paths in close succession.
    func dismissScrollback() {
        guard let overlay = scrollbackOverlay else { return }

        // Restore first responder to live terminal only if scrollback view
        // currently owns it — avoid stealing focus from something else.
        if window?.firstResponder === overlay.scrollbackTerminalView {
            window?.makeFirstResponder(terminalView)
        }

        overlay.removeFromSuperview()
        scrollbackOverlay = nil
        // ARC frees ScrollbackOverlayView → ScrollbackTerminalView → Terminal → snapshot Buffer

        // Start cooldown to prevent trackpad momentum from re-creating scrollback
        startScrollbackCooldown()
    }

    /// Start the post-dismiss cooldown. Clears on momentum end or ~300ms timeout
    /// (whichever comes first).
    private func startScrollbackCooldown() {
        scrollbackCooldown = true
        scrollbackCooldownTimer?.cancel()

        // Monitor for momentum end — clears cooldown early for trackpads
        var momentumMonitor: Any?
        momentumMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if event.momentumPhase == .ended || (event.momentumPhase == [] && event.phase == .ended) {
                self?.scrollbackCooldown = false
                self?.scrollbackCooldownTimer?.cancel()
                self?.scrollbackCooldownTimer = nil
                if let monitor = momentumMonitor {
                    NSEvent.removeMonitor(monitor)
                    momentumMonitor = nil
                }
            }
            return event
        }

        // Safety timeout — for discrete mouse wheels that don't send momentum events
        let timer = DispatchWorkItem { [weak self] in
            self?.scrollbackCooldown = false
            self?.scrollbackCooldownTimer = nil
            if let monitor = momentumMonitor {
                NSEvent.removeMonitor(monitor)
                momentumMonitor = nil
            }
        }
        scrollbackCooldownTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: timer)
    }

    /// Apply current font/theme settings to the scrollback view if present.
    private func applySettingsToScrollback() {
        guard let overlay = scrollbackOverlay else { return }
        let sbView = overlay.scrollbackTerminalView

        // Apply font (same logic as Session.applyTerminalFontSize)
        let family = SettingsManager.shared.settings.terminalFontFamily
        let size = session.terminalFontSize
        let font: NSFont
        if family == "SF Mono" {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        } else {
            font = NSFont(name: family, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        sbView.font = font

        // Apply color theme
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )
        sbView.nativeForegroundColor = theme.foregroundColor
        sbView.nativeBackgroundColor = theme.backgroundColorValue
        sbView.installColors(theme.swiftTermPalette)
        sbView.galaxyBoldForegroundColor = theme.boldForegroundColor
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
