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
        guard let terminalView = session.terminalView else {
            preconditionFailure(
                "FocusableTerminalView created for session without terminal"
            )
        }
        let container = TerminalHostView(
            terminalView: terminalView, session: session
        )
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

    /// The scrollback overlay (holds ScrollbackWebView + pill).
    /// Non-nil when scrollback mode is active.
    private var scrollbackOverlay: ScrollbackOverlayView?

    /// Retained buffer snapshot for settings-change rebuilds while scrollback
    /// is active. Nil'd on dismiss to release the deep-copy buffer memory.
    private var currentSnapshot: Buffer?

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
    /// ScrollbackWebView is first responder, so no bytes are sent.
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

        // Hide SwiftTerm's built-in caret — Claude Code renders its own cursor
        terminalView.caretView.isHidden = true

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

        // Observe session process exit — dismiss scrollback if process dies.
        // Force-dismiss to skip note confirmation — the process is gone so
        // there's nothing to send notes to.
        session.$hasExited
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exited in
                if exited { self?.dismissScrollback(force: true) }
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

        // If scrollback is active, make the WKWebView first responder
        // instead of the live terminal — otherwise scrollback is visible but
        // keyboard-dead after session switches.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let overlay = self.scrollbackOverlay {
                window.makeFirstResponder(overlay.scrollbackView.webView)
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
        // Dismiss scrollback on file drag entry — if notes exist, show
        // confirmation instead of auto-dismissing
        if isScrollbackActive {
            if scrollbackOverlay?.scrollbackView.hasNotes == true {
                showDismissConfirmation()
                return []
            }
            dismissScrollback(force: true)
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

    /// Handle scroll-wheel-up on the live terminal. Returns true if the event
    /// was consumed (scrollback overlay created), false to let normal scroll proceed.
    private func handleScrollUp(event: NSEvent) -> Bool {
        guard SettingsManager.shared.settings.scrollToEnterScrollback else { return false }
        guard !isScrollbackActive else { return false }
        guard !scrollbackCooldown else { return false }

        let displayBuffer = terminalView.terminal.displayBuffer
        guard displayBuffer.yBase > 0 else { return false }

        let scrollPosition = displayBuffer.yDisp
        terminalView.selection.selectNone()
        createScrollback(initialScrollLine: scrollPosition)
        return true
    }

    /// Start the post-dismiss cooldown. Clears on momentum end or ~300ms timeout
    /// (whichever comes first). Prevents trackpad momentum from immediately
    /// re-creating the scrollback view after dismiss.
    private func startScrollbackCooldown() {
        scrollbackCooldown = true
        scrollbackCooldownTimer?.cancel()

        // Monitor for momentum end — clears cooldown early for trackpads
        var momentumMonitor: Any?
        momentumMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if event.momentumPhase == .ended
                || (event.momentumPhase == [] && event.phase == .ended) {
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

    /// Enter scrollback mode from Cmd+S menu action. Only the active session's
    /// TerminalHostView should respond — all others ignore.
    private func enterScrollbackFromMenu() {
        guard isActive else { return }
        guard !isScrollbackActive else { return }

        let displayBuffer = terminalView.terminal.displayBuffer
        guard displayBuffer.yBase > 0 else { return }

        // Capture the live terminal's current scroll position — the
        // scrollback view opens at this position. Clear any selection now
        // but defer scrolling the live view to bottom until after the
        // WKWebView is visible (avoids a flash of the live view jumping).
        let scrollPosition = displayBuffer.yDisp
        terminalView.selection.selectNone()

        createScrollback(initialScrollLine: scrollPosition)
    }

    /// Create the scrollback overlay with an HTML rendering of the live terminal's buffer.
    private func createScrollback(initialScrollLine: Int? = nil) {
        // Snapshot the live buffer (deep copy)
        let snapshot = terminalView.terminal.snapshotBuffer(terminalView.terminal.buffer)
        self.currentSnapshot = snapshot

        // Use provided scroll position, or default to bottom of buffer
        let initialScrollLine = initialScrollLine ?? snapshot.yDisp

        // Get current font metrics for CSS matching
        let font = terminalView.font
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let cellDim = terminalView.cellDimension!
        let theme = TerminalColorTheme.theme(
            named: SettingsManager.shared.settings.terminalColorThemeName
        )

        // Render buffer to HTML
        let html = ScrollbackBufferRenderer.render(
            buffer: snapshot,
            terminal: terminalView.terminal,
            theme: theme,
            fontFamily: font.fontName,
            fontSize: font.pointSize,
            cellHeight: cellDim.height,
            cols: snapshot.cols
        )

        // Create web view with theme background for rubber-band overscroll
        let webView = ScrollbackWebView(
            frame: terminalView.bounds,
            html: html,
            initialScrollLine: initialScrollLine,
            backgroundColor: theme.backgroundColorValue
        )
        webView.onDismiss = { [weak self] in
            self?.dismissScrollback()
        }
        webView.onReady = { [weak self] in
            // Scroll the live terminal to the bottom now that the scrollback
            // overlay is visible — prevents a flash of the live view jumping.
            guard let self = self else { return }
            let buf = self.terminalView.terminal.displayBuffer
            self.terminalView.terminal.userScrolling = false
            buf.yDisp = buf.yBase
            self.terminalView.setNeedsDisplay(self.terminalView.bounds)

            // Restore note cards if this is a reload (theme/font change)
            webView.restoreNoteState()
        }
        webView.onConfirmDismiss = { [weak self] in
            self?.showDismissConfirmation()
        }
        webView.onSendToClaude = { [weak self] message in
            guard let self = self else { return }
            self.dismissScrollback(force: true)
            // Bracketed paste delivers multi-line content as a single
            // input block, then CR after a delay submits it.
            self.sendTextToTerminal(message, asPaste: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.terminalView.send([0x0D])
            }
        }
        webView.onConfirmDiscardForm = { [weak self] in
            self?.showDiscardNoteFormConfirmation()
        }
        webView.onConfirmDiscardEdit = { [weak self] in
            self?.showDiscardNoteEditConfirmation()
        }
        webView.onConfirmDragReplace = {
            [weak self] startLine, endLine in
            self?.showDragReplaceNoteConfirmation(
                startLine: startLine,
                endLine: endLine
            )
        }

        // Create overlay container with border and pill
        let overlay = ScrollbackOverlayView(frame: bounds, scrollbackView: webView)
        overlay.autoresizingMask = [.width, .height]

        // Add above drag highlight so it's the topmost interactive layer
        addSubview(overlay, positioned: .above, relativeTo: dragHighlightView)
        scrollbackOverlay = overlay

        // Make WKWebView first responder for keyboard events
        window?.makeFirstResponder(webView.webView)
    }

    /// Dismiss and fully unload the scrollback overlay. Idempotent — safe to
    /// call from multiple exit paths in close succession. When `force` is
    /// false and notes exist, shows a confirmation dialog instead.
    func dismissScrollback(force: Bool = false) {
        guard let overlay = scrollbackOverlay else { return }

        // Guard against losing unsaved notes
        if !force && overlay.scrollbackView.hasNotes {
            showDismissConfirmation()
            return
        }

        // Restore first responder to live terminal only if the WKWebView
        // currently owns it — avoid stealing focus from something else.
        if window?.firstResponder === overlay.scrollbackView.webView {
            window?.makeFirstResponder(terminalView)
        }

        // Explicit teardown breaks the WKWebView retain cycle so the web
        // process is freed immediately rather than leaking.
        overlay.scrollbackView.teardown()
        overlay.removeFromSuperview()
        scrollbackOverlay = nil
        currentSnapshot = nil

        // Start cooldown to prevent trackpad momentum from re-creating scrollback
        if SettingsManager.shared.settings.scrollToEnterScrollback {
            startScrollbackCooldown()
        }
    }

    /// Show an NSAlert sheet asking the user to confirm discarding notes.
    private func showDismissConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }
        let noteCount = overlay.scrollbackView.notes.count

        SheetAlert.confirm(
            in: window,
            message: "Discard scrollback notes?",
            detail: "You have \(noteCount) unsaved "
                + "note\(noteCount == 1 ? "" : "s"). "
                + "They will be lost if you exit scrollback.",
            onConfirm: { [weak self] in
                self?.dismissScrollback(force: true)
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Show an NSAlert asking to discard new note form content.
    private func showDiscardNoteFormConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you dismiss.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardForm()"
                )
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Show an NSAlert asking to discard edit changes to a note.
    private func showDiscardNoteEditConfirmation() {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard changes?",
            detail: "You have unsaved changes to this note. "
                + "They will be lost if you cancel editing.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardEdit()"
                )
            },
            onCancel: { [weak self] in
                self?.requestFocus()
            }
        )
    }

    /// Show an NSAlert asking to discard unsaved note form content
    /// before opening a new form at a different drag selection.
    private func showDragReplaceNoteConfirmation(
        startLine: Int,
        endLine: Int
    ) {
        guard let overlay = scrollbackOverlay,
              let window = window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you start a new note.",
            onConfirm: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes"
                    + ".showNoteForm(\(startLine), \(endLine))"
                )
            },
            onCancel: {
                overlay.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.focusForm()"
                )
            }
        )
    }

    /// Apply current font/theme settings to the scrollback view if present.
    /// Rebuilds the entire HTML document with the new theme/font, preserving
    /// the current scroll position. Theme changes require a full rebuild
    /// because inline <span> styles are baked from the original theme.
    private func applySettingsToScrollback() {
        guard let overlay = scrollbackOverlay else { return }
        guard let snapshot = currentSnapshot else { return }

        // Save current scroll position before rebuilding
        overlay.scrollbackView.webView.evaluateJavaScript(
            "ScrollbackManager.getVisibleLine()"
        ) { [weak self] result, _ in
            guard let self = self else { return }
            let scrollLine = result as? Int ?? 0

            let theme = TerminalColorTheme.theme(
                named: SettingsManager.shared.settings.terminalColorThemeName
            )
            let family = SettingsManager.shared.settings.terminalFontFamily
            let size = self.session.terminalFontSize

            // Compute font and cell height (same logic as Session)
            let font: NSFont
            if family == "SF Mono" {
                font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            } else {
                font = NSFont(name: family, size: size)
                    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            let ctFont = font as CTFont
            let cellHeight = ceil(
                CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont)
                    + CTFontGetLeading(ctFont)
            )

            let html = ScrollbackBufferRenderer.render(
                buffer: snapshot,
                terminal: self.terminalView.terminal,
                theme: theme,
                fontFamily: font.fontName,
                fontSize: size,
                cellHeight: cellHeight,
                cols: snapshot.cols
            )

            overlay.scrollbackView.reload(html: html, scrollToLine: scrollLine)
        }
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
