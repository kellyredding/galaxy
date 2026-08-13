import SwiftUI
import AppKit
import Galactic

// MARK: - Inline Name Editor (AppKit-backed)

/// NSTextField subclass that short-circuits key view traversal.
/// When any NSTextField becomes first responder, macOS's NSAutoFillHeuristicController
/// walks previousValidKeyView and nextValidKeyView to check if the field might be a
/// password field. With the ZStack architecture keeping all session views alive, each
/// traversal walks thousands of SwiftUI-managed views (~4.5 seconds each, ~9 seconds
/// total). Returning nil stops the autofill heuristic immediately.
class InlineEditField: NSTextField {
    override var previousValidKeyView: NSView? { nil }
    override var nextValidKeyView: NSView? { nil }
}

/// NSViewRepresentable wrapping InlineEditField for inline session renaming.
/// Uses AppKit's makeFirstResponder directly (~60ms) instead of SwiftUI's
/// @FocusState, which triggers expensive view-tree reconciliation.
///
/// Three lifecycle callbacks signal end-of-editing:
///   - `onCommit`: user pressed Enter (NSResponder.insertNewline:)
///   - `onCancel`: user pressed Esc (NSResponder.cancelOperation:)
///   - `onBlur`:   field lost first responder for ANY other reason —
///                 click outside, app deactivation, programmatic focus
///                 shift, etc. Fires from controlTextDidEndEditing
///                 only when the movement reason is not Enter or Esc,
///                 so no double-fire with onCommit/onCancel.
///
/// Owners decide what blur means in their context. SessionRow maps
/// blur → commit (macOS save-on-blur). SessionMarkerRow maps blur →
/// guarded commit, suppressed while the emoji picker steals focus.
struct InlineNameEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let textColor: NSColor
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onBlur: () -> Void

    /// Optional inclusion check the mouse-down monitor consults
    /// before forcing blur on outside clicks. If the closure
    /// returns true for the click point (in the field window's
    /// coordinate space — bottom-left origin, same as
    /// `NSEvent.locationInWindow`), the click is treated as
    /// "still inside the editing surface" and the field stays
    /// first responder. Used by `SessionMarkerRow` to whitelist
    /// the emoji slot's frame so clicks on it open the picker
    /// popover instead of committing the name and tearing down
    /// edit mode behind the user's back.
    ///
    /// Defaults to nil — only the field's own frame counts as
    /// "inside" when no closure is supplied (Slice A behavior).
    var isClickInsideEditingSurface: ((CGPoint) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> InlineEditField {
        let field = InlineEditField()
        field.font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        field.textColor = textColor
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        // Focus via AppKit once SwiftUI has placed the view in the
        // window, then install a window-local mouse-down monitor so
        // clicks on non-focusable SwiftUI views (sibling session
        // rows, empty sidebar space, stopped-session view, etc.)
        // also blur the field. Without the monitor, AppKit only
        // resigns first responder when the click target itself is
        // an NSResponder — which most SwiftUI tap-gesture targets
        // are not — so save-on-blur silently doesn't fire on those
        // clicks. The monitor fills that gap by surrendering first
        // responder explicitly on outside clicks.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            context.coordinator.installMouseMonitor(for: field)
        }
        return field
    }

    func updateNSView(_ nsView: InlineEditField, context: Context) {
        // Only update text if it differs (avoid clobbering cursor position)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        nsView.textColor = textColor
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineNameEditor
        weak var field: InlineEditField?
        private var mouseMonitor: Any?

        init(_ parent: InlineNameEditor) {
            self.parent = parent
        }

        deinit {
            removeMouseMonitor()
        }

        /// Install a window-local mouse-down monitor that surrenders
        /// first responder on any click outside the field. Needed
        /// because clicks on non-focusable SwiftUI views (which is
        /// most of them) don't naturally steal first responder from
        /// NSTextField, so AppKit's blur path doesn't fire on its
        /// own. The monitor watches for left, right, and other-button
        /// mouse-down events in our window; on a click outside the
        /// field's frame, it calls makeFirstResponder(nil) which
        /// kicks the editing-end notification chain (and therefore
        /// onBlur) cleanly. The monitor is removed in
        /// controlTextDidEndEditing — once editing is over, we don't
        /// need it until the next edit cycle re-installs it.
        func installMouseMonitor(for field: InlineEditField) {
            self.field = field
            removeMouseMonitor()  // Defensive against double install.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .leftMouseDown,
                    .rightMouseDown,
                    .otherMouseDown,
                ]
            ) { [weak self] event in
                self?.handleMouseDown(event)
                return event  // Always pass through.
            }
        }

        func removeMouseMonitor() {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
        }

        private func handleMouseDown(_ event: NSEvent) {
            guard let field = field, let window = field.window
            else { return }
            // Only react to events targeting our field's window.
            // Popovers (and other secondary windows) get their own
            // event.window, so clicks there don't cause us to blur.
            guard event.window === window else { return }

            // Skip clicks inside the field — typing or
            // cursor-positioning must not blur.
            let locationInWindow = event.locationInWindow
            let fieldFrame = field.convert(field.bounds, to: nil)
            if fieldFrame.contains(locationInWindow) { return }

            // Owner-supplied additional inclusion (e.g., the
            // marker row's emoji slot). If true, treat the click
            // as "inside the editing surface" — let it pass
            // through without forcing blur.
            if parent.isClickInsideEditingSurface?(locationInWindow)
                == true {
                return
            }

            // Outside the field — surrender first responder. This
            // fires controlTextDidEndEditing with movement = .other
            // (raw 0), which our handler dispatches to onBlur.
            window.makeFirstResponder(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }

        /// Fires whenever the field stops being first responder —
        /// after Enter/Esc commands, after click-outside, after the
        /// app loses focus, etc. We dispatch to onBlur only when the
        /// cause is NOT Enter or Esc (those already ran via
        /// doCommandBy above), so the blur path covers click-outside
        /// cleanly without double-firing onCommit/onCancel.
        ///
        /// macOS sets the NSTextMovement userInfo key to indicate why
        /// editing ended. Pressing Enter sends `.return`, Esc sends
        /// `.cancel`, anything else (focus shift, app deactivate, etc)
        /// arrives as `.other` (raw 0).
        func controlTextDidEndEditing(_ obj: Notification) {
            let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
            let returnRaw = NSTextMovement.return.rawValue
            let cancelRaw = NSTextMovement.cancel.rawValue
            if movement != returnRaw && movement != cancelRaw {
                parent.onBlur()
            }
            // Editing has ended — the next edit cycle's makeNSView
            // re-installs the monitor. Cleaning up here avoids
            // dangling monitors after the field is removed from the
            // window (deinit also handles it for safety).
            removeMouseMonitor()
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool  // Need this to know when to fade indicator
    let isOnTerminalTab: Bool  // Only clear unread when viewing terminal
    /// Passed rather than read from settings: observing the settings store
    /// here would invalidate every row on any preference change, which is
    /// the cascade `SidebarPreferences` exists to avoid.
    let showUnreadIndicator: Bool
    var onStop: () -> Void   // Stop a running session
    var onClose: () -> Void  // Remove a stopped session from list

    // Drag-to-reorder support
    let isPlaceholder: Bool  // Show as gray rectangle during drag
    let rowIndex: Int
    let showDragHandle: Bool  // Only show when multiple sessions exist
    let isDragging: Bool      // Whether any drag is in progress (disables hover)

    // Status info passed from ExpandedSessionSidebar (not observed to prevent mass re-renders)
    let statusInfo: StatusLineService.SessionStatusInfo?

    // Note: `sidebarWidth` is intentionally NOT a field on
    // this row. The adaptive CWD truncation below uses
    // `ViewThatFits` to pick a tier at SwiftUI layout time
    // based on whatever horizontal space the row is given.
    // Holding `sidebarWidth` here would force a body re-eval
    // on every resize-drag mouseDragged event (~42 row evals
    // per drag tick × 20 sessions), saturating main and
    // producing the "drag → lock → snap" pattern measured
    // in the dbg log on 2026-05-09.

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isEditingName = false
    @State private var editingNameText = ""

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }
    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Adaptive Colors
    // Dark/selected: bright SwiftUI colors. Light unselected: deep saturated variants.
    // Selected rows force dark colorScheme via .environment, so use bright colors to match.

    private var useBrightColors: Bool { isDark || isSelected }

    private var cwdColor: Color {
        useBrightColors ? .yellow : Color(red: 0.75, green: 0.5, blue: 0.0)
    }
    private var branchColor: Color {
        useBrightColors ? .green : Color(red: 0.0, green: 0.55, blue: 0.15)
    }
    private var stashColor: Color {
        useBrightColors ? .red : Color(red: 0.8, green: 0.1, blue: 0.1)
    }
    private var upstreamColor: Color {
        useBrightColors ? .cyan : Color(red: 0.0, green: 0.5, blue: 0.7)
    }

    /// Persona line color — .secondary washes out in light mode
    private var personaColor: Color {
        useBrightColors ? .secondary : .primary.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Drag handle (before status dot) - only show when there's more than one item
            if showDragHandle {
                SessionRowDragHandle(
                    itemId: session.id,
                    itemIndex: rowIndex
                )
                .frame(width: 18, height: 32)  // Larger hit area, icon stays centered
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            // Status indicator (pulses opacity when session is busy)
            SessionStatusDot(session: session)
                .overlay(alignment: .topTrailing) {
                    AgentCountSuperscript(
                        count: session.runningAgentCount
                    )
                }

            // Session info with bell indicator overlay
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    // Line 1: Session name (double-click to edit)
                    if isEditingName {
                        InlineNameEditor(
                            text: $editingNameText,
                            fontSize: fontSize.caption1,
                            fontWeight: .bold,
                            textColor: isSelected ? .white : .labelColor,
                            onCommit: { commitNameEdit() },
                            onCancel: { cancelNameEdit() },
                            // Click-outside, app-deactivate, focus
                            // shift — all save the typed name, matching
                            // every native macOS save-on-blur control.
                            onBlur: { commitNameEdit() }
                        )
                        .frame(height: fontSize.caption1LineHeight)
                    } else {
                        Text(session.sidebarTitle)
                            .chromeFont(size: fontSize.caption1, weight: .bold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(isSelected ? .white : .primary)
                            .frame(height: fontSize.caption1LineHeight)
                            .onTapGesture(count: 2) {
                                beginNameEdit()
                            }
                    }

                    // Persona name (or "--" for vanilla Claude sessions)
                    Text(session.personaName ?? "--")
                        .chromeFontMono(size: fontSize.tiny, weight: .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : personaColor)
                        .frame(height: fontSize.tinyLineHeight)

                    // Line 3: CWD + git status (always occupies height).
                    // ViewThatFits picks the largest tier whose natural
                    // size fits in the proposed horizontal space; SwiftUI
                    // measures at layout time so width changes don't
                    // re-evaluate the row's body. .lineLimit(1) +
                    // .truncationMode(.tail) clips the basename tier if
                    // even that overflows.
                    line3View(info: statusInfo)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: fontSize.tinyLineHeight)
                }

                // Unread indicator - bright red dot, tight to top-left corner
                // Appears instantly, fades out over 3 seconds (declarative animation)
                UnreadIndicator()
                    .offset(x: -6, y: -2)
                    .opacity(
                        session.hasUnreadResponse && showUnreadIndicator
                            ? 1 : 0
                    )
                    .animation(
                        session.hasUnreadResponse ? nil : .easeOut(duration: 3.0),
                        value: session.hasUnreadResponse
                    )
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 7)  // Extra 1pt to account for bottom separator
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .opacity(isPlaceholder ? 0 : 1)  // Hide content when placeholder (during drag)
        .background(
            ZStack {
                if isPlaceholder {
                    Rectangle().fill(Color(NSColor.windowBackgroundColor))
                } else if isSelected {
                    // Dark base + accent overlay — produces the same deep blue
                    // in both themes that dark mode gets naturally.
                    Rectangle().fill(Color(white: 0.12))
                    Rectangle().fill(Color.accentColor.opacity(0.25))
                }

                // Visual bell pulse. Every session's row flashes, not only the
                // selected one — a bell means the agent wants attention, and
                // the row you are *not* looking at is the case that needs
                // saying. The persistent unread dot was carrying that alone,
                // while the cue that says "now" fired only where you already
                // were.
                //
                // Two washes because the backdrop differs — see
                // `Color.sessionBellFlashSelected` for why one colour cannot
                // serve both.
                if !isPlaceholder && session.visualBellActive {
                    Rectangle()
                        .fill(
                            isSelected
                                ? Color.sessionBellFlashSelected
                                : Color.sessionBellFlashUnselected
                        )
                }
            }
        )
        // Force dark colorScheme on selected row so accent background + bright
        // colors render consistently regardless of app theme.
        .environment(\.colorScheme, isSelected ? .dark : colorScheme)
        .overlay(alignment: .bottom) {
            // Subtle separator between session rows (theme-aware, drawn over background)
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
        }
        .overlay(alignment: .trailing) {
            // Hover buttons float over content on the right (disabled during drag)
            if isHovered && !isDragging {
                if session.hasExited {
                    // Stopped session: show Close button to remove from list
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(isSelected ? .white.opacity(0.8) : personaColor)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .help("Remove session")
                    .transition(.opacity)
                    .padding(.trailing, 2)
                } else {
                    // Running session: show Stop button
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(isSelected ? .white.opacity(0.8) : personaColor)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .help("Stop session")
                    .transition(.opacity)
                    .padding(.trailing, 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.08), value: session.visualBellActive)
        .onHover { hovering in
            // Ignore hover events during drag (prevents stale states on rows dragged over)
            guard !isDragging else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onChange(of: isDragging) { oldValue, newValue in
            if newValue && !isPlaceholder {
                // Drag started: clear hover on non-dragged rows
                isHovered = false
            } else if oldValue && !newValue && isPlaceholder {
                // Drag ended: this was the dragged row, mouse is likely still over it
                isHovered = true
            }
        }
        .attentionAutoClear(
            isBeingViewed: isSelected && isWindowFocused && isOnTerminalTab,
            hasAttention: session.hasUnreadResponse
        ) {
            session.hasUnreadResponse = false
        }
    }

    // MARK: - Line 3: CWD + Git Status

    /// Adaptive 3-tier CWD line wrapped in `ViewThatFits`.
    /// SwiftUI's layout system picks the largest tier whose
    /// natural size fits the proposed horizontal space:
    ///   Tier 1: full path — ~/projects/acme/acme-products
    ///   Tier 2: abbreviated — ~/p/a/acme-products
    ///   Tier 3: basename only — products
    /// Tier 3 is the fallback when even the basename is
    /// wider than the proposal; the caller's
    /// `.truncationMode(.tail)` clips from there.
    ///
    /// Critical perf property: this function builds three
    /// styled `Text` variants every body eval, but the
    /// row's body itself does NOT depend on `sidebarWidth`,
    /// so a resize drag no longer cascades into 20 row
    /// body re-evaluations per `mouseDragged` event.
    @ViewBuilder
    private func line3View(
        info: StatusLineService.SessionStatusInfo?
    ) -> some View {
        let mono = Font.system(
            size: fontSize.tiny,
            weight: .regular,
            design: .monospaced
        )
        if let cwd = session.ledgerCwd {
            let homePath = NSHomeDirectory()
            let fullPath = cwd.hasPrefix(homePath)
                ? "~" + cwd.dropFirst(homePath.count)
                : cwd
            let abbreviated = abbreviatePath(fullPath)
            let basename =
                (cwd as NSString).lastPathComponent
            ViewThatFits(in: .horizontal) {
                buildLine3Styled(
                    displayPath: fullPath, info: info
                )
                buildLine3Styled(
                    displayPath: abbreviated, info: info
                )
                buildLine3Styled(
                    displayPath: basename, info: info
                )
            }
        } else {
            Text("").font(mono)
        }
    }

    /// Build line 3's styled `Text` for a specific
    /// `displayPath` (one of the three CWD tiers). The
    /// git suffix rendering is identical across all
    /// tiers — only the leading CWD portion differs.
    private func buildLine3Styled(
        displayPath: String,
        info: StatusLineService.SessionStatusInfo?
    ) -> Text {
        let mono = Font.system(size: fontSize.tiny, weight: .regular, design: .monospaced)
        let monoBold = Font.system(size: fontSize.tiny, weight: .bold, design: .monospaced)
        let bracketColor: Color = isSelected ? .white.opacity(0.5) : .secondary

        // Render CWD with styling
        var result = Text(displayPath)
            .font(monoBold)
            .foregroundColor(cwdColor)

        // Git bracket section — only if we have a branch
        guard let branch = info?.gitBranch, !branch.isEmpty else {
            return result
        }

        let style = SettingsManager.shared.settings.gitStatusStyle

        result = result + Text("[").font(mono).foregroundColor(bracketColor)
        result = result + Text(branch).font(monoBold).foregroundColor(branchColor)

        if let info = info {
            switch style {
            case .symbolic:
                // All indicators, symbolic upstream: [branch^<>+*]
                if info.hasStashed {
                    result = result + Text("^").font(mono).foregroundColor(stashColor)
                }
                if info.behindCount > 0 && info.aheadCount > 0 {
                    result = result + Text("<>").font(monoBold).foregroundColor(upstreamColor)
                } else if info.behindCount > 0 {
                    result = result + Text("<").font(monoBold).foregroundColor(upstreamColor)
                } else if info.aheadCount > 0 {
                    result = result + Text(">").font(monoBold).foregroundColor(upstreamColor)
                }
                if info.hasStaged {
                    result = result + Text("+").font(mono).foregroundColor(branchColor)
                }
                if info.isDirty {
                    result = result + Text("*").font(mono).foregroundColor(cwdColor)
                }

            case .arrows:
                // All indicators, arrow upstream: [branch^↑1↓2+*]
                if info.hasStashed {
                    result = result + Text("^").font(mono).foregroundColor(stashColor)
                }
                if info.behindCount > 0 {
                    result = result + Text("↓\(info.behindCount)").font(monoBold).foregroundColor(upstreamColor)
                }
                if info.aheadCount > 0 {
                    result = result + Text("↑\(info.aheadCount)").font(monoBold).foregroundColor(upstreamColor)
                }
                if info.hasStaged {
                    result = result + Text("+").font(mono).foregroundColor(branchColor)
                }
                if info.isDirty {
                    result = result + Text("*").font(mono).foregroundColor(cwdColor)
                }

            case .minimal:
                // Just dirty asterisk: [branch*]
                if info.isDirty || info.hasStaged {
                    result = result + Text("*").font(mono).foregroundColor(cwdColor)
                }
            }
        }

        result = result + Text("]").font(mono).foregroundColor(bracketColor)
        return result
    }

    // MARK: - Adaptive CWD Truncation

    /// Abbreviate path: first char of each intermediate dir, keep full basename.
    /// ~/projects/acme/acme-products → ~/p/a/acme-products
    private func abbreviatePath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return path }

        var abbreviated = parts.dropLast().map { part in
            part.isEmpty ? "" : String(part.prefix(1))
        }
        abbreviated.append(String(parts.last!))

        return abbreviated.joined(separator: "/")
    }

    // MARK: - Name Editing

    private func beginNameEdit() {
        if let given = session.givenName {
            editingNameText = given
        } else {
            editingNameText = session.ledgerSuggestedName ?? ""
        }
        isEditingName = true
        // Focus is handled by InlineNameEditor.makeNSView via AppKit's
        // makeFirstResponder — no SwiftUI @FocusState involvement.
    }

    private func commitNameEdit() {
        let trimmed = editingNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Three-state: non-empty → set name, empty → explicit opt-out ("")
        // (nil means "never set" and is only the initial state)
        session.givenName = trimmed.isEmpty ? "" : trimmed
        SessionPersistence.shared.markDirty()
        isEditingName = false
        restoreTerminalFocus()
    }

    private func cancelNameEdit() {
        isEditingName = false
        restoreTerminalFocus()
    }

    /// Return focus to the terminal's preferred pane (Session
    /// or Shell, whichever was last focused) if it's visible
    /// (running, not exited). Routes through Session's
    /// pane-focus registry so scrollback state is respected
    /// inside each TerminalHostView.requestFocus().
    private func restoreTerminalFocus() {
        DispatchQueue.main.async {
            guard !session.hasExited else { return }
            session.paneRegistry.restorePreferredPaneFocus()
        }
    }
}

// MARK: - Equatable conformance

/// SwiftUI re-evaluates a view's body whenever its parent's
/// body re-evaluates and the new struct's stored properties
/// differ from the previous instance. Without explicit
/// Equatable conformance, that diff is structural and
/// closures (which are non-Equatable function values) cause
/// SwiftUI to assume "different" every time a parent body
/// runs — producing a body re-evaluation per row per parent
/// invalidation.
///
/// Diagnostic confirmed this for the resize-drag path:
/// 22 drag events × ~42 row body evals = ~929 row evals
/// observed in the sidebar dbg log. With this conformance
/// + `.equatable()` at the call site, SwiftUI uses our
/// `==` to short-circuit identical rows; rows only
/// re-evaluate when something they actually display
/// (`statusInfo`, `isSelected`, etc.) actually changes.
///
/// `onStop` / `onClose` are intentionally excluded from
/// the comparison — they're closures recreated on every
/// parent body eval but capture only stable values
/// (`session.id`, the `SessionManager` singleton), so the
/// stored old closure remains correct when SwiftUI keeps
/// the previous body output.
extension SessionRow: Equatable {
    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session === rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isWindowFocused == rhs.isWindowFocused
            && lhs.isOnTerminalTab == rhs.isOnTerminalTab
            && lhs.showUnreadIndicator == rhs.showUnreadIndicator
            && lhs.isPlaceholder == rhs.isPlaceholder
            && lhs.rowIndex == rhs.rowIndex
            && lhs.showDragHandle == rhs.showDragHandle
            && lhs.isDragging == rhs.isDragging
            && lhs.statusInfo == rhs.statusInfo
    }
}
