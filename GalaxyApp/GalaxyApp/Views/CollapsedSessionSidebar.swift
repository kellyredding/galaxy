import SwiftUI
import AppKit

// MARK: - View Frame Reporter

/// Invisible NSViewRepresentable that reports its frame in screen coordinates.
/// More reliable than GeometryReader in LazyVStack — the NSView always knows
/// its position via the AppKit view hierarchy.
struct FrameReporter: NSViewRepresentable {
    let onFrame: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let frameInWindow = nsView.convert(nsView.bounds, to: nil)
            let screenFrame = window.convertToScreen(frameInWindow)
            onFrame(screenFrame)
        }
    }
}

// MARK: - Tooltip Window Manager

/// Manages a floating NSPanel for displaying rich tooltips.
/// Uses a borderless, non-activating panel that renders above all
/// views including AppKit-hosted NSViews (terminal).
class TooltipPanel {
    static let shared = TooltipPanel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    func show<Content: View>(
        content: Content,
        rowScreenFrame: NSRect,
        preferredSide: SidebarPosition,
        in window: NSWindow
    ) {
        hide()

        let hosting = NSHostingView(
            rootView: AnyView(content)
        )
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: hosting.fittingSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.appearance = window.effectiveAppearance
        panel.contentView = hosting

        let tooltipSize = hosting.fittingSize
        let gap: CGFloat = 4

        // Horizontal: place tooltip adjacent to the sidebar
        var originX: CGFloat
        if preferredSide == .left {
            originX = rowScreenFrame.maxX + gap
        } else {
            originX = rowScreenFrame.minX - tooltipSize.width - gap
        }

        // Vertical: align tooltip top with row top
        // rowScreenFrame.minY is the row's bottom in screen coords (NSScreen: y=0 at bottom)
        // Row top in screen coords = rowScreenFrame.maxY
        // Tooltip top = panel origin + tooltipSize.height
        // We want tooltip top = row top → origin.y = rowTop - tooltipSize.height
        var originY = rowScreenFrame.maxY - tooltipSize.height

        // Clamp to screen edges
        if let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            if originY < visibleFrame.minY {
                originY = visibleFrame.minY
            }
            if originY + tooltipSize.height > visibleFrame.maxY {
                originY = visibleFrame.maxY - tooltipSize.height
            }
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFront(nil)

        self.panel = panel
        self.hostingView = hosting
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}

// MARK: - Collapsed Session Sidebar

/// Collapsed session sidebar — compact counterpart to ExpandedSessionSidebar.
/// Shows one status dot per session. Visible when sidebar is collapsed,
/// providing at-a-glance session status without occupying full sidebar width.
struct CollapsedSessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessionManager.sessions) { session in
                    CollapsedSessionRow(
                        session: session,
                        isSelected: session.id == sessionManager.activeSessionId,
                        isWindowFocused: sessionManager.isWindowFocused,
                        isOnTerminalTab: sessionManager.activeTab == .terminal,
                        statusInfo: statusLineService.statusInfo[session.id],
                        sidebarPosition: SettingsManager.shared.settings.sidebarPosition
                    )
                    .onTapGesture {
                        sessionManager.switchTo(sessionId: session.id)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if !sessionManager.sessions.isEmpty {
                statusLineService.refreshSessions(sessionManager.sessions)
            }
        }
        .onChange(of: sessionManager.sessions.count) { _, _ in
            statusLineService.refreshSessions(sessionManager.sessions)
        }
    }
}

// MARK: - Collapsed Session Row

/// A single row in the collapsed session sidebar.
/// Shows the status dot centered in a row that matches the expanded
/// sidebar row height, plus unread bell indicator and visual bell flash.
/// On hover, shows a floating tooltip panel matching expanded row content.
struct CollapsedSessionRow: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let isWindowFocused: Bool
    let isOnTerminalTab: Bool
    let statusInfo: StatusLineService.SessionStatusInfo?
    let sidebarPosition: SidebarPosition

    @Environment(\.chromeFontSize) private var chromeFontSize
    @State private var rowScreenFrame: NSRect = .zero

    /// Match expanded SessionRow height
    private var rowHeight: CGFloat {
        let fs = ChromeFontSize(chromeFontSize)
        return 17 + fs.caption2LineHeight + 2 * fs.tinyLineHeight
    }

    var body: some View {
        ZStack {
            // Selection background
            Rectangle()
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.25)
                        : Color.clear
                )

            // Visual bell flash overlay (entire row area)
            if isSelected && session.visualBellActive {
                Rectangle()
                    .fill(Color.white.opacity(0.4))
            }

            // Status dot
            SessionStatusDot(session: session)
        }
        .frame(width: 32, height: rowHeight)
        .background(
            FrameReporter { frame in
                rowScreenFrame = frame
            }
        )
        .overlay(alignment: .topTrailing) {
            if session.hasUnreadResponse {
                UnreadIndicator()
                    .offset(x: 0, y: 6)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                showTooltip()
            } else {
                TooltipPanel.shared.hide()
            }
        }
        .onDisappear {
            TooltipPanel.shared.hide()
        }
        .animation(.easeInOut(duration: 0.08), value: session.visualBellActive)
        .unreadIndicatorBehavior(
            session: session,
            isSelected: isSelected,
            isWindowFocused: isWindowFocused,
            isOnTerminalTab: isOnTerminalTab
        )
    }

    private func showTooltip() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }

        let tooltipContent = CollapsedRowTooltip(
            session: session,
            isSelected: isSelected,
            statusInfo: statusInfo
        )

        TooltipPanel.shared.show(
            content: tooltipContent,
            rowScreenFrame: rowScreenFrame,
            preferredSide: sidebarPosition,
            in: window
        )
    }
}

// MARK: - Collapsed Row Tooltip

/// Rich tooltip content shown in a floating panel on hover.
/// Renders the same 3-line content as an expanded SessionRow:
/// session name, persona, CWD + git status.
struct CollapsedRowTooltip: View {
    @ObservedObject var session: Session
    let isSelected: Bool
    let statusInfo: StatusLineService.SessionStatusInfo?

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }
    private var isDark: Bool { colorScheme == .dark }

    // Theme-adaptive colors matching SessionRow's unselected state
    private var nameColor: Color { .primary }
    private var personaColor: Color { isDark ? .secondary : .primary.opacity(0.7) }
    private var cwdColor: Color {
        isDark ? .yellow : Color(red: 0.75, green: 0.5, blue: 0.0)
    }
    private var branchColor: Color {
        isDark ? .green : Color(red: 0.0, green: 0.55, blue: 0.15)
    }
    private var stashColor: Color {
        isDark ? .red : Color(red: 0.8, green: 0.1, blue: 0.1)
    }
    private var upstreamColor: Color {
        isDark ? .cyan : Color(red: 0.0, green: 0.5, blue: 0.7)
    }
    private var bracketColor: Color { .secondary }
    private var strokeColor: Color {
        isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Line 1: Session name
            Text(session.displayName)
                .chromeFont(size: fontSize.caption1, weight: .bold)
                .lineLimit(1)
                .foregroundColor(nameColor)
                .frame(height: fontSize.caption1LineHeight)

            // Line 2: Persona name
            Text(session.personaName ?? "--")
                .chromeFontMono(size: fontSize.tiny, weight: .regular)
                .lineLimit(1)
                .foregroundColor(personaColor)
                .frame(height: fontSize.tinyLineHeight)

            // Line 3: CWD + git status
            buildCwdLine()
                .lineLimit(1)
                .frame(height: fontSize.tinyLineHeight)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(strokeColor, lineWidth: 0.5)
                )
        )
        .fixedSize()
    }

    // MARK: - CWD + Git Status Line

    private func buildCwdLine() -> Text {
        let mono = Font.system(
            size: fontSize.tiny, weight: .regular, design: .monospaced
        )
        let monoBold = Font.system(
            size: fontSize.tiny, weight: .bold, design: .monospaced
        )
        let bColor: Color = bracketColor

        guard let cwd = session.ledgerCwd else {
            return Text("").font(mono)
        }

        let displayPath = abbreviatedPath(cwd)
        var result = Text(displayPath)
            .font(monoBold)
            .foregroundColor(cwdColor)

        guard let branch = statusInfo?.gitBranch, !branch.isEmpty else {
            return result
        }

        let style = SettingsManager.shared.settings.gitStatusStyle

        result = result + Text("[").font(mono).foregroundColor(bColor)
        result = result + Text(branch).font(monoBold).foregroundColor(branchColor)

        if let info = statusInfo {
            switch style {
            case .symbolic:
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
                if info.hasStashed {
                    result = result + Text("^").font(mono).foregroundColor(stashColor)
                }
                if info.behindCount > 0 {
                    result = result + Text("↓\(info.behindCount)")
                        .font(monoBold).foregroundColor(upstreamColor)
                }
                if info.aheadCount > 0 {
                    result = result + Text("↑\(info.aheadCount)")
                        .font(monoBold).foregroundColor(upstreamColor)
                }
                if info.hasStaged {
                    result = result + Text("+").font(mono).foregroundColor(branchColor)
                }
                if info.isDirty {
                    result = result + Text("*").font(mono).foregroundColor(cwdColor)
                }

            case .minimal:
                if info.isDirty || info.hasStaged {
                    result = result + Text("*").font(mono).foregroundColor(cwdColor)
                }
            }
        }

        result = result + Text("]").font(mono).foregroundColor(bColor)
        return result
    }

    private func abbreviatedPath(_ cwd: String) -> String {
        let homePath = NSHomeDirectory()
        if cwd.hasPrefix(homePath) {
            return "~" + cwd.dropFirst(homePath.count)
        }
        return cwd
    }
}
