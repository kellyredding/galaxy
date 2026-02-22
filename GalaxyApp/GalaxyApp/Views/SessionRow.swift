import SwiftUI
import AppKit

struct SessionRow: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool  // Need this to know when to fade indicator
    var onStop: () -> Void   // Stop a running session
    var onClose: () -> Void  // Remove a stopped session from list

    // Drag-to-reorder support
    let isPlaceholder: Bool  // Show as gray rectangle during drag
    let rowIndex: Int
    let showDragHandle: Bool  // Only show when multiple sessions exist
    let isDragging: Bool      // Whether any drag is in progress (disables hover)

    // Status info passed from SessionSidebar (not observed to prevent mass re-renders)
    let statusInfo: StatusLineService.SessionStatusInfo?

    // Sidebar width for adaptive CWD truncation
    let sidebarWidth: CGFloat

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isPulsePhase = false
    @State private var isEditingName = false
    @State private var editingNameText = ""
    @FocusState private var isNameFieldFocused: Bool

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }
    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Adaptive Colors

    /// CWD path + dirty indicator color
    private var cwdColor: Color {
        isDark ? .yellow : Color(red: 0.55, green: 0.35, blue: 0.0)
    }

    /// Branch name + staged indicator color
    private var branchColor: Color {
        isDark ? .green : Color(red: 0.0, green: 0.45, blue: 0.0)
    }

    /// Stash indicator color
    private var stashColor: Color {
        isDark ? .red : Color(red: 0.7, green: 0.0, blue: 0.0)
    }

    /// Ahead/behind indicator color
    private var upstreamColor: Color {
        isDark ? .cyan : Color(red: 0.0, green: 0.35, blue: 0.5)
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
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .opacity(isPulsePhase ? 0.3 : 1.0)

            // Session info with bell indicator overlay
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    // Line 1: Session name (double-click to edit)
                    if isEditingName {
                        TextField("", text: $editingNameText)
                            .chromeFontMono(size: fontSize.caption2, weight: .medium)
                            .textFieldStyle(.plain)
                            .focused($isNameFieldFocused)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(isSelected && isDark ? .white : .primary)
                            .frame(height: fontSize.caption2LineHeight)
                            .onSubmit {
                                commitNameEdit()
                            }
                            .onExitCommand {
                                cancelNameEdit()
                            }
                    } else {
                        Text(session.displayName)
                            .chromeFontMono(size: fontSize.caption2, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(isSelected && isDark ? .white : .primary)
                            .frame(height: fontSize.caption2LineHeight)
                            .onTapGesture(count: 2) {
                                beginNameEdit()
                            }
                    }

                    // Persona name (or "--" for vanilla Claude sessions)
                    Text(session.personaName ?? "--")
                        .chromeFontMono(size: fontSize.tiny, weight: .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(isSelected && isDark ? .white.opacity(0.8) : .secondary)
                        .frame(height: fontSize.tinyLineHeight)

                    // Line 3: CWD + git status (always occupies height)
                    buildLine3(info: statusInfo)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: fontSize.tinyLineHeight)
                }

                // Unread bell indicator - bright red dot, tight to top-left corner
                // Shows instantly, fades out over 3 seconds (animation applied via withAnimation when clearing)
                Circle()
                    .fill(Color(red: 1.0, green: 0.2, blue: 0.2))  // Bright, saturated red
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.red.opacity(0.6), radius: 3, x: 0, y: 0)  // Subtle glow
                    .offset(x: -6, y: -2)  // Right edge overlaps first letter of session name
                    .opacity(session.hasUnreadBell ? 1 : 0)
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
                // Base background: panel background during drag (placeholder), selection color otherwise
                Rectangle()
                    .fill(isPlaceholder
                        ? Color(NSColor.windowBackgroundColor)
                        : (isSelected ? Color.accentColor.opacity(0.25) : Color.clear))

                // Visual bell pulse overlay (only for selected session, not during drag)
                if !isPlaceholder && isSelected && session.visualBellActive {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                }
            }
        )
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
                            .foregroundColor(.white.opacity(0.85))
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
                            .foregroundColor(.white.opacity(0.85))
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
        .onChange(of: isSelected) { _, newValue in
            // When session becomes selected and window is focused, clear the indicator (with fade)
            if newValue && isWindowFocused && session.hasUnreadBell {
                withAnimation(.easeOut(duration: 3.0)) {
                    session.hasUnreadBell = false
                }
            }
        }
        .onChange(of: isWindowFocused) { _, newValue in
            // When window becomes focused and this session is selected, clear the indicator (with fade)
            if newValue && isSelected && session.hasUnreadBell {
                withAnimation(.easeOut(duration: 3.0)) {
                    session.hasUnreadBell = false
                }
            }
        }
        .onChange(of: session.hasUnreadBell) { _, newValue in
            // When bell indicator appears and session is already selected + focused, start fade
            // Small delay lets the indicator render at full opacity before fading
            if newValue && isSelected && isWindowFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeOut(duration: 3.0)) {
                        session.hasUnreadBell = false
                    }
                }
            }
        }
        .onChange(of: session.isBusy) { _, newValue in
            if newValue {
                // Start continuous pulse: smooth fade between full and dim opacity
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isPulsePhase = true
                }
            } else {
                // Stop pulsing: smoothly return to full opacity
                withAnimation(.easeInOut(duration: 0.3)) {
                    isPulsePhase = false
                }
            }
        }
    }

    private var statusColor: Color {
        if session.hasExited {
            return .red  // Stopped sessions
        } else if session.isRunning {
            return .green
        } else {
            return .yellow
        }
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
        let bracketColor: Color = isSelected && isDark ? .white.opacity(0.5) : .secondary

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

    /// Measure string width using NSString size calculation.
    private func measureWidth(_ string: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (string as NSString).size(withAttributes: attributes).width
    }

    // MARK: - Name Editing

    private func beginNameEdit() {
        editingNameText = session.givenName ?? ""
        isEditingName = true
        // Focus after next layout pass so the TextField exists
        DispatchQueue.main.async {
            isNameFieldFocused = true
        }
    }

    private func commitNameEdit() {
        let trimmed = editingNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        session.givenName = trimmed.isEmpty ? nil : trimmed
        SessionPersistence.shared.markDirty()
        isEditingName = false
        isNameFieldFocused = false
        restoreTerminalFocus()
    }

    private func cancelNameEdit() {
        isEditingName = false
        isNameFieldFocused = false
        restoreTerminalFocus()
    }

    /// Return focus to the terminal if it's visible (running, not exited).
    /// If the session is stopped, the terminal isn't in the view hierarchy
    /// so window will be nil — natural no-op.
    private func restoreTerminalFocus() {
        DispatchQueue.main.async {
            session.terminalView.window?.makeFirstResponder(session.terminalView)
        }
    }
}
