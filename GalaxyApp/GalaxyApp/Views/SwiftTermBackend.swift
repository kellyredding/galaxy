import AppKit
import SwiftTerm

/// Resolve a Galaxy font-family setting to a concrete `NSFont`
/// at the given point size. SF Mono resolves via the system
/// monospaced API (`.medium` weight matches Terminal.app's
/// rendering more closely than `.regular`, which Apple maps
/// to an unexpectedly light weight for SF Mono). Everything
/// else resolves via `NSFont(name:size:)` with a monospaced
/// fallback, so an invalid family name yields a usable
/// terminal font instead of a system default proportional
/// font. Free function rather than a backend method so
/// pane-side consumers (Session, ShellTerminalPane) can apply
/// per-pane font-size overrides without naming a concrete
/// backend type.
internal func resolveTerminalFont(
    family: String, size: CGFloat
) -> NSFont {
    if family == "SF Mono" {
        return NSFont.monospacedSystemFont(
            ofSize: size, weight: .medium
        )
    }
    return NSFont(name: family, size: size)
        ?? NSFont.monospacedSystemFont(
            ofSize: size, weight: .regular
        )
}

/// `TerminalBackend` implementation backed by Galaxy's
/// `GalaxySwiftTermView` — a `LocalProcessTerminalView`
/// subclass that intercepts scroll events, suppresses the
/// default bell NSBeep, and exposes focus-event quenching.
///
/// The Shell pane reaches the SwiftTerm engine through this
/// backend. The Session pane currently constructs
/// `GalaxySwiftTermView` directly via `Session.swift`; that
/// path will migrate to a `TerminalBackend` reference in a
/// follow-up slice of the terminal-backend unification work.
final class SwiftTermBackend: NSObject, TerminalBackend,
    LocalProcessTerminalViewDelegate {

    private let terminalView: GalaxySwiftTermView

    var view: NSView { terminalView }
    var onProcessTerminated: ((Int32) -> Void)?

    /// Set once we've notified our owner that the child
    /// exited. Either SwiftTerm's natural delegate path or
    /// our explicit-terminate failsafe will reach
    /// `fireProcessTerminatedOnce`; whichever wins, the
    /// other becomes a no-op.
    private var hasFiredProcessTerminated = false

    var onScrollUp: ((NSEvent) -> Bool)? {
        get { terminalView.onScrollUp }
        set { terminalView.onScrollUp = newValue }
    }

    /// Forward to the subclass's stored property — mirror
    /// of `onScrollUp`. Lets `TerminalHostView` wire its
    /// snap-to-bottom hook through the backend without
    /// reaching past the protocol.
    var onScrollDown: (() -> Void)? {
        get { terminalView.onScrollDown }
        set { terminalView.onScrollDown = newValue }
    }

    func snapViewportToBottomIfWithin(rows: Int) -> Bool {
        terminalView.snapViewportToBottomIfWithin(rows: rows)
    }

    var hasScrollbackContent: Bool {
        terminalView.terminal.displayBuffer.yBase > 0
    }

    var viewportRow: Int {
        terminalView.terminal.displayBuffer.yDisp
    }

    func clearSelection() {
        terminalView.selection.selectNone()
    }

    var font: NSFont { terminalView.font }

    var cellHeight: CGFloat {
        // SwiftTerm computes cellDimension lazily on first
        // layout — it's effectively never nil after the
        // surface has been shown. Force-unwrap matches the
        // existing chrome read site that this method
        // replaces; if the assumption ever breaks we'll see
        // it here, in one place, instead of scattered.
        terminalView.cellDimension!.height
    }

    func redraw() {
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    func snapViewportToBottom() {
        let buf = terminalView.terminal.displayBuffer
        terminalView.terminal.userScrolling = false
        buf.yDisp = buf.yBase
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    /// Forward to the subclass's stored property so
    /// `bell(source:)` can fire it directly without a
    /// backend back-reference. Mirrors `onScrollUp`.
    var onBell: (() -> Void)? {
        get { terminalView.onBell }
        set { terminalView.onBell = newValue }
    }

    init(frame: NSRect) {
        self.terminalView = GalaxySwiftTermView(frame: frame)
        super.init()
        // Conform to LPTV directly — process-lifecycle
        // callbacks land on `processTerminated(source:exitCode:)`
        // below.
        self.terminalView.processDelegate = self
    }

    // MARK: - Process

    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String,
        currentDirectory: String
    ) {
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    /// Terminate the running subprocess.
    ///
    /// SwiftTerm's `LocalProcessTerminalView.terminate()`
    /// sends `kill(shellPid, SIGTERM)` directly and ignores
    /// the signal argument — there's no path through it for
    /// SIGKILL or anything else. We accept the argument for
    /// protocol conformance and, when the caller actually
    /// asks for something other than SIGTERM, send the kill
    /// ourselves via the captured `shellPid` (forkpty path
    /// only — the Subprocess path leaves `shellPid` at 0
    /// and relies on its own cancellation chain).
    ///
    /// SwiftTerm's exit-detection — `DispatchSourceProcess`
    /// on the forkpty path, the `await Subprocess.run`
    /// continuation on the Subprocess path — does not
    /// reliably fire after an explicit `terminate()`. The
    /// downstream chain (`onProcessTerminated` →
    /// `ShellTerminalPane` → `SplitState.closeShell`) hangs
    /// on the missed callback, so the shell pane stays
    /// visible after Cmd+W even though the kill went
    /// through. We schedule a guaranteed delegate fire
    /// after a short grace period; SwiftTerm's natural path
    /// dedupes via `fireProcessTerminatedOnce` if it wins
    /// the race.
    func terminateProcess(signal: Int32) {
        let pid = terminalView.process.shellPid
        NSLog(
            "SwiftTermBackend: terminateProcess signal=%d "
            + "shellPid=%d",
            signal, pid
        )
        terminalView.terminate()
        if pid > 0 && signal != SIGTERM {
            // SwiftTerm only ever sends SIGTERM; honor any
            // other requested signal directly. SIGKILL in
            // particular is what unblocks shells that ignore
            // SIGTERM (interactive zsh with plugins, etc.).
            kill(pid, signal)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.3
        ) { [weak self] in
            self?.fireProcessTerminatedOnce(exitCode: 0)
        }
    }

    // MARK: - IO

    func send(bytes: [UInt8]) {
        terminalView.send(bytes)
    }

    func send(text: String, asPaste: Bool) {
        if asPaste, terminalView.terminal.bracketedPasteMode {
            terminalView.send(
                Array(EscapeSequences.bracketedPasteStart)
            )
            terminalView.send(txt: text)
            terminalView.send(
                Array(EscapeSequences.bracketedPasteEnd)
            )
        } else {
            terminalView.send(txt: text)
        }
    }

    // MARK: - Buffer / appearance

    func changeHistorySize(_ lines: Int) {
        terminalView.terminal.changeHistorySize(lines)
    }

    func installColors(_ palette: [TerminalPaletteColor]) {
        let swiftTermPalette = palette.map {
            SwiftTerm.Color(
                red: $0.red, green: $0.green, blue: $0.blue
            )
        }
        terminalView.installColors(swiftTermPalette)
    }

    func setForegroundColor(_ color: NSColor) {
        terminalView.nativeForegroundColor = color
    }

    func setBackgroundColor(_ color: NSColor) {
        terminalView.nativeBackgroundColor = color
    }

    func setBoldForegroundColor(_ color: NSColor) {
        terminalView.galaxyBoldForegroundColor = color
    }

    func applySettings(_ settings: AppSettings) {
        // Theme.
        let theme = TerminalColorTheme.theme(
            named: settings.terminalColorThemeName
        )
        setForegroundColor(theme.foregroundColor)
        setBackgroundColor(theme.backgroundColorValue)
        setBoldForegroundColor(theme.boldForegroundColor)
        installColors(theme.terminalPalette)

        // Font (uses the global default size; per-pane size
        // overrides are applied separately by the consumer
        // that owns the override — Session via
        // `applyPerSessionFontSize`, ShellTerminalPane via
        // `applyPerPaneFontSize`).
        setFont(
            resolveTerminalFont(
                family: settings.terminalFontFamily,
                size: settings.defaultTerminalFontSize
            )
        )

        // Scrollback.
        changeHistorySize(settings.terminalScrollbackLines)

        // NOTE: cursor styling is intentionally NOT applied
        // here. `shellCursorStyle` / `shellCursorBlink` are
        // Shell-only — the Shell pane subscribes to those via
        // its own deduplication wrapper. The Session pane
        // keeps SwiftTerm's caret hidden (Claude Code self-
        // renders the cursor), so applying cursor settings on
        // every Session-pane settings change would be churn at
        // best, and risks the cursor-style delegate hook
        // re-touching caret view state we want to stay hidden.
    }

    var suppressFocusEvents: Bool {
        get { terminalView.suppressFocusEvents }
        set { terminalView.suppressFocusEvents = newValue }
    }

    func feed(text: String) {
        terminalView.feed(text: text)
    }

    func setFont(_ font: NSFont) {
        terminalView.font = font
    }

    func applyCursor(
        style: ShellCursorStyle, blink: Bool
    ) {
        // Collapse Galaxy's two orthogonal toggles into
        // SwiftTerm's 6-case `CursorStyle` enum. Setting
        // via `terminal.setCursorStyle` fires the delegate
        // hook which updates `MacCaretView`'s shape and
        // toggles the blink animation off the CALayer
        // opacity keypath.
        let mapped: SwiftTerm.CursorStyle = {
            switch (style, blink) {
            case (.block, true):        return .blinkBlock
            case (.block, false):       return .steadyBlock
            case (.underline, true):    return .blinkUnderline
            case (.underline, false):   return .steadyUnderline
            case (.verticalBar, true):  return .blinkBar
            case (.verticalBar, false): return .steadyBar
            }
        }()
        terminalView.terminal.setCursorStyle(mapped)
    }

    func captureScrollbackSnapshot() -> ScrollbackSnapshot? {
        // SwiftTerm's `snapshotBuffer(_:)` is non-optional —
        // it deep-copies whatever buffer is handed in. The
        // protocol return type stays optional so future
        // backends (or pane-teardown races) can still bow
        // out cleanly.
        let buffer = terminalView.terminal.snapshotBuffer(
            terminalView.terminal.buffer
        )
        return SwiftTermScrollbackSnapshot(
            buffer: buffer,
            terminal: terminalView.terminal
        )
    }

    // MARK: - Focus

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        fireProcessTerminatedOnce(exitCode: exitCode ?? 0)
    }

    /// Idempotent delegate fire. Either SwiftTerm's natural
    /// `processTerminated` delegate or the
    /// `terminateProcess` failsafe reaches here; the second
    /// caller is a no-op.
    private func fireProcessTerminatedOnce(
        exitCode: Int32
    ) {
        guard !hasFiredProcessTerminated else { return }
        hasFiredProcessTerminated = true
        onProcessTerminated?(exitCode)
    }

    func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {
        // No-op — SwiftTerm reflows internally.
    }

    func setTerminalTitle(
        source: LocalProcessTerminalView,
        title: String
    ) {
        // No-op — Shell pane doesn't display a title.
    }

    func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {
        // No-op — Shell pane doesn't track cwd.
    }
}

/// `ScrollbackSnapshot` impl over a SwiftTerm `Buffer +
/// Terminal` pair. Captures both at construction so the
/// underlying state is frozen — even if the live terminal
/// moves on, the snapshot keeps rendering the same captured
/// buffer.
///
/// `Terminal` is captured because the renderer needs
/// `terminal.getCharacter(for:)` for extended grapheme
/// lookup (CharData.code values >= maxRune). The terminal
/// reference is kept private so chrome consumers can't reach
/// back into SwiftTerm internals through it.
final class SwiftTermScrollbackSnapshot: ScrollbackSnapshot {
    private let buffer: Buffer
    private let terminal: Terminal

    let cols: Int
    let yDisp: Int

    init(buffer: Buffer, terminal: Terminal) {
        self.buffer = buffer
        self.terminal = terminal
        self.cols = buffer.cols
        self.yDisp = buffer.yDisp
    }

    func render(
        theme: TerminalColorTheme,
        fontFamily: String,
        fontSize: CGFloat,
        cellHeight: CGFloat
    ) -> String {
        ScrollbackBufferRenderer.render(
            buffer: buffer,
            terminal: terminal,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            cellHeight: cellHeight,
            cols: cols
        )
    }
}
