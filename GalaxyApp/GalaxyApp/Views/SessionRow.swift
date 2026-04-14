import SwiftUI
import AppKit

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
struct InlineNameEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let textColor: NSColor
    let onCommit: () -> Void
    let onCancel: () -> Void

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
        // Focus via AppKit once SwiftUI has placed the view in the window.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
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

        init(_ parent: InlineNameEditor) {
            self.parent = parent
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
    }
}

struct SessionRow: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool  // Need this to know when to fade indicator
    let isOnTerminalTab: Bool  // Only clear unread when viewing terminal
    var onStop: () -> Void   // Stop a running session
    var onClose: () -> Void  // Remove a stopped session from list

    // Drag-to-reorder support
    let isPlaceholder: Bool  // Show as gray rectangle during drag
    let rowIndex: Int
    let showDragHandle: Bool  // Only show when multiple sessions exist
    let isDragging: Bool      // Whether any drag is in progress (disables hover)

    // Status info passed from ExpandedSessionSidebar (not observed to prevent mass re-renders)
    let statusInfo: StatusLineService.SessionStatusInfo?

    // Sidebar width for adaptive CWD truncation
    let sidebarWidth: CGFloat

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
            // Drag handle (before status dot) - only show when multiple sessions
            if showDragHandle {
                SessionRowDragHandle(
                    sessionId: session.id,
                    sessionIndex: rowIndex
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
                            onCancel: { cancelNameEdit() }
                        )
                        .frame(height: fontSize.caption1LineHeight)
                    } else {
                        Text(session.displayName)
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

                    // Line 3: CWD + git status (always occupies height)
                    buildLine3(info: statusInfo)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: fontSize.tinyLineHeight)
                }

                // Unread indicator - bright red dot, tight to top-left corner
                // Appears instantly, fades out over 3 seconds (declarative animation)
                UnreadIndicator()
                    .offset(x: -6, y: -2)
                    .opacity(session.hasUnreadResponse ? 1 : 0)
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

                // Visual bell pulse overlay (only for selected session, not during drag)
                if !isPlaceholder && isSelected && session.visualBellActive {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
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
        .unreadIndicatorBehavior(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab
        )
    }

    // MARK: - Line 3: CWD + Git Status

    /// Build styled line 3 with color-coded segments.
    /// Uses adaptive 3-tier CWD truncation matching the statusline algorithm:
    ///   Tier 1: full path — ~/projects/kajabi/products
    ///   Tier 2: abbreviated — ~/p/k/products
    ///   Tier 3: basename only — products
    /// Git portion is never truncated. After tier 3, .truncationMode(.tail) clips.
    private func buildLine3(
        info: StatusLineService.SessionStatusInfo?
    ) -> Text {
        let mono = Font.system(size: fontSize.tiny, weight: .regular, design: .monospaced)
        let monoBold = Font.system(size: fontSize.tiny, weight: .bold, design: .monospaced)
        let bracketColor: Color = isSelected ? .white.opacity(0.5) : .secondary

        guard let cwd = session.ledgerCwd else {
            return Text("").font(mono)
        }

        // Build git suffix string for width measurement
        let gitSuffix = buildGitSuffix(info: info)

        // Available pixel width for line 3 text content
        let textBudget = availableTextWidth

        // Measure font for width calculations
        let measureFont = NSFont.monospacedSystemFont(
            ofSize: fontSize.tiny, weight: .regular
        )

        // Pick the best CWD display tier that fits
        let displayPath = adaptiveCwdDisplay(
            cwd: cwd,
            gitSuffix: gitSuffix,
            budget: textBudget,
            font: measureFont
        )

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

    /// Available pixel width for line 3 text, accounting for row layout chrome.
    private var availableTextWidth: CGFloat {
        // HStack(spacing: 6): leading(4) + trailing(8) + circle(8) + spacing(6)
        // With drag handle: + handle(18) + extra spacing(6)
        let chrome: CGFloat = showDragHandle ? 50 : 26
        return max(sidebarWidth - chrome, 0)
    }

    /// Pick the best CWD display string using 3-tier cascade.
    /// Tries full path → abbreviated → basename, always appending git suffix
    /// for width measurement. Returns only the CWD portion (git is styled separately).
    private func adaptiveCwdDisplay(
        cwd: String,
        gitSuffix: String,
        budget: CGFloat,
        font: NSFont
    ) -> String {
        let homePath = NSHomeDirectory()
        let fullPath = cwd.hasPrefix(homePath)
            ? "~" + cwd.dropFirst(homePath.count)
            : cwd

        // Tier 1: full path
        if measureWidth(fullPath + gitSuffix, font: font) <= budget {
            return fullPath
        }

        // Tier 2: abbreviated intermediates (first char), full basename
        let abbreviated = abbreviatePath(fullPath)
        if measureWidth(abbreviated + gitSuffix, font: font) <= budget {
            return abbreviated
        }

        // Tier 3 (floor): basename only — .truncationMode(.tail) clips from here
        return (cwd as NSString).lastPathComponent
    }

    /// Abbreviate path: first char of each intermediate dir, keep full basename.
    /// ~/projects/kajabi/products → ~/p/k/products
    private func abbreviatePath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return path }

        var abbreviated = parts.dropLast().map { part in
            part.isEmpty ? "" : String(part.prefix(1))
        }
        abbreviated.append(String(parts.last!))

        return abbreviated.joined(separator: "/")
    }

    /// Build the plain-text git suffix for width measurement.
    /// Mirrors the styled rendering logic but as a single string.
    private func buildGitSuffix(
        info: StatusLineService.SessionStatusInfo?
    ) -> String {
        guard let branch = info?.gitBranch, !branch.isEmpty else {
            return ""
        }

        let style = SettingsManager.shared.settings.gitStatusStyle
        var suffix = "[\(branch)"
        if let info = info {
            switch style {
            case .symbolic:
                if info.hasStashed { suffix += "^" }
                if info.behindCount > 0 && info.aheadCount > 0 { suffix += "<>" }
                else if info.behindCount > 0 { suffix += "<" }
                else if info.aheadCount > 0 { suffix += ">" }
                if info.hasStaged { suffix += "+" }
                if info.isDirty { suffix += "*" }
            case .arrows:
                if info.hasStashed { suffix += "^" }
                if info.behindCount > 0 { suffix += "↓\(info.behindCount)" }
                if info.aheadCount > 0 { suffix += "↑\(info.aheadCount)" }
                if info.hasStaged { suffix += "+" }
                if info.isDirty { suffix += "*" }
            case .minimal:
                if info.isDirty || info.hasStaged { suffix += "*" }
            }
        }
        suffix += "]"
        return suffix
    }

    /// Cached monospaced character widths keyed by font point size.
    /// Avoids repeated CoreText calls that can crash after long uptime
    /// due to stale system font caches (see: Galaxy-2026-03-04-213819.ips).
    private static var monoCharWidthCache: [CGFloat: CGFloat] = [:]

    /// Get the character width for a monospaced font at the given size.
    /// Measures once per font size and caches the result.
    private static func monoCharWidth(forSize size: CGFloat) -> CGFloat {
        if let cached = monoCharWidthCache[size] {
            return cached
        }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let width = ("M" as NSString).size(
            withAttributes: [.font: font]
        ).width
        monoCharWidthCache[size] = width
        return width
    }

    /// Measure string width using cached monospaced character width.
    /// Since the font is monospaced, width = character count × char width.
    private func measureWidth(_ string: String, font: NSFont) -> CGFloat {
        return CGFloat(string.count) * Self.monoCharWidth(forSize: font.pointSize)
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

    /// Return focus to the terminal if it's visible (running, not exited).
    /// Routes through TerminalHostView so scrollback state is respected.
    private func restoreTerminalFocus() {
        DispatchQueue.main.async {
            guard let terminalView = session.terminalView else { return }
            var view: NSView? = terminalView.superview
            while let v = view {
                if let host = v as? TerminalHostView {
                    host.requestFocus()
                    return
                }
                view = v.superview
            }
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }
}
