import SwiftUI
import AppKit

// MARK: - Row Frame Anchor

/// Holds a weak reference to an invisible NSView and computes its
/// screen frame on demand. Used to position floating tooltip panels
/// relative to a SwiftUI row.
///
/// The earlier push-based `FrameReporter` stored the frame in
/// SwiftUI `@State`, updated from `updateNSView`. That callback
/// only fires on SwiftUI state changes — AppKit layout changes
/// during live window resize do not trigger it, so the stored
/// frame went stale and tooltips rendered at the row's previous
/// on-screen position until some unrelated re-render (status line
/// tick, agent count change, etc.) happened to refresh it.
///
/// Querying the NSView's frame at hover time reads the live AppKit
/// layout directly, eliminating that staleness window.
final class RowFrameAnchor {
    weak var view: NSView?

    /// Frame in the host window's coordinate space (bottom-left
    /// origin — matches `NSEvent.locationInWindow`). Returns nil
    /// if the view has been removed from its window.
    /// Used by the marker emoji slot to whitelist its frame
    /// against the inline editor's mouse-down monitor.
    func currentWindowFrame() -> NSRect? {
        guard let view = view else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    func currentScreenFrame() -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}

/// Invisible NSViewRepresentable that wires its NSView into a
/// `RowFrameAnchor` so callers can query the frame on demand.
struct FrameAnchorView: NSViewRepresentable {
    let anchor: RowFrameAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
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
    private var windowObservers: [NSObjectProtocol] = []

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

        // The tooltip origin is computed once from the row's screen
        // frame and never follows window geometry changes. Hide it when
        // the user drags to resize (willStartLiveResize) or move
        // (didMove) the window so it doesn't strand at stale coords;
        // native tooltips behave the same way.
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.willStartLiveResizeNotification,
            NSWindow.didMoveNotification,
        ]
        for name in names {
            let token = center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.hide()
            }
            windowObservers.append(token)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil

        let center = NotificationCenter.default
        for token in windowObservers {
            center.removeObserver(token)
        }
        windowObservers.removeAll()
    }
}

// MARK: - Collapsed Session Sidebar

/// Collapsed session sidebar — compact counterpart to ExpandedSessionSidebar.
/// Shows one status dot per session and a centered horizontal line per
/// marker. Visible when sidebar is collapsed, providing at-a-glance
/// session status (and section structure via marker lines) without
/// occupying full sidebar width.
struct CollapsedSessionSidebar: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var statusLineService = StatusLineService.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessionManager.sidebarItems) { item in
                    rowView(for: item)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // Status-line refresh is intentionally NOT
        // triggered from this view. Both sidebars now
        // stay alive simultaneously (opacity-gated), so
        // `ExpandedSessionSidebar.onAppear` and its
        // `onChange(of: sidebarItems.count)` cover the
        // full lifecycle for both rendering modes.
        // Calling `refreshSessions` from here too would
        // just duplicate the background-queue work and
        // overwrite the first call's result.
    }

    /// Dispatch a SidebarItem to the appropriate collapsed row.
    /// Sessions are tappable and have rich hover tooltips; markers
    /// render as a thin centered line and show a name-only tooltip.
    @ViewBuilder
    private func rowView(for item: SidebarItem) -> some View {
        switch item {
        case .session(let session):
            CollapsedSessionRow(
                session: session,
                isSelected: session.id == sessionManager.activeSessionId,
                isWindowFocused: sessionManager.isWindowFocused,
                isOnTerminalTab: sessionManager.activeTab == .terminal,
                statusInfo: statusLineService.statusInfo[session.id],
                sidebarPosition: SettingsManager.shared.settings.sidebarPosition
            )
            // Opt into Equatable short-circuit, same as
            // SessionRow in the expanded sidebar — see the
            // `extension CollapsedSessionRow: Equatable`
            // block at the bottom of this file.
            .equatable()
            .onTapGesture {
                sessionManager.switchTo(sessionId: session.id)
            }

        case .marker(let marker):
            CollapsedMarkerRow(
                marker: marker,
                sidebarPosition: SettingsManager.shared.settings.sidebarPosition
            )
            .equatable()
            // Markers are not selectable — no tap gesture.
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
    @State private var frameAnchor = RowFrameAnchor()

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
                .overlay(alignment: .topTrailing) {
                    AgentCountSuperscript(
                        count: session.runningAgentCount
                    )
                }
        }
        .frame(width: 32, height: rowHeight)
        .background(FrameAnchorView(anchor: frameAnchor))
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
        guard
            let window = NSApp.mainWindow ?? NSApp.keyWindow,
            let rowScreenFrame = frameAnchor.currentScreenFrame()
        else { return }

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

// MARK: - Collapsed Marker Row

/// Compact counterpart to SessionMarkerRow. Renders just a thin
/// horizontal line at vertical center with the same `.primary`
/// color the expanded marker uses (white in dark mode, black in
/// light mode). On hover, shows a floating tooltip with the
/// marker's name (if non-empty) — same hover-tooltip mechanism
/// sessions use, so the two row kinds feel consistent in the
/// collapsed view.
///
/// Markers are not selectable, so no tap gesture and no selection
/// background. The hover-X delete affordance is intentionally
/// omitted from the collapsed view — users expand the sidebar to
/// remove markers.
struct CollapsedMarkerRow: View {
    @ObservedObject var marker: SessionMarker
    let sidebarPosition: SidebarPosition

    @Environment(\.chromeFontSize) private var chromeFontSize
    @State private var frameAnchor = RowFrameAnchor()

    /// Match the collapsed session row height so markers align
    /// vertically with adjacent session dots.
    private var rowHeight: CGFloat {
        let fs = ChromeFontSize(chromeFontSize)
        return 17 + fs.caption2LineHeight + 2 * fs.tinyLineHeight
    }

    /// Horizontal inset on each side of the line so it doesn't
    /// kiss the sidebar edges.
    private static let lineInset: CGFloat = 4

    var body: some View {
        ZStack {
            if !marker.emoji.isEmpty {
                // Emoji replaces the line entirely when set —
                // the emoji *is* the section identifier in
                // collapsed mode. Same size as the expanded
                // marker row and the hover tooltip so the glyph
                // reads identically across all three surfaces.
                Text(marker.emoji)
                    .font(
                        .system(size: SessionMarkerRow.emojiGlyphSize)
                    )
            } else {
                // Default: centered horizontal line, matching
                // the expanded marker's `.primary` color.
                Rectangle()
                    .fill(Color.primary)
                    .frame(height: 1)
                    .padding(.horizontal, Self.lineInset)
            }
        }
        .frame(width: 32, height: rowHeight)
        .background(FrameAnchorView(anchor: frameAnchor))
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
    }

    private func showTooltip() {
        // Skip the tooltip when neither name nor emoji is set —
        // nothing meaningful to show. Emoji-only markers still
        // get a tooltip (the emoji IS the identifier).
        guard !marker.name.isEmpty || !marker.emoji.isEmpty
        else { return }
        guard
            let window = NSApp.mainWindow ?? NSApp.keyWindow,
            let rowScreenFrame = frameAnchor.currentScreenFrame()
        else { return }

        let tooltipContent = CollapsedMarkerTooltip(
            marker: marker,
            rowHeight: rowHeight
        )

        TooltipPanel.shared.show(
            content: tooltipContent,
            rowScreenFrame: rowScreenFrame,
            preferredSide: sidebarPosition,
            in: window
        )
    }
}

// MARK: - Collapsed Marker Tooltip

/// Tooltip panel content shown on hover over a collapsed marker
/// row. Mirrors the expanded marker's layout — flanking horizontal
/// lines with a centered bold name — so the tooltip reads as the
/// "expanded view" of the hovered row. Width is at least
/// `minWidth` (the user's expanded sidebar width) but grows to fit
/// long names; height is fixed to the collapsed row height so the
/// tooltip lines up with the hovered row visually.
struct CollapsedMarkerTooltip: View {
    @ObservedObject var marker: SessionMarker

    /// Match the collapsed row height that triggered this tooltip,
    /// so the tooltip aligns top-to-bottom with the row.
    let rowHeight: CGFloat

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }
    private var isDark: Bool { colorScheme == .dark }

    private var strokeColor: Color {
        isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.2)
    }

    /// Same color scheme the expanded marker uses — both lines
    /// and name are `.primary` so the marker reads as one
    /// decorative element.
    private var lineColor: Color { .primary }

    /// Horizontal padding inside the panel — same proportions as
    /// the existing CollapsedRowTooltip so the two tooltips feel
    /// like siblings.
    private static let horizontalPadding: CGFloat = 8

    /// Static minimum tooltip width. Intentionally on the thinner
    /// side — wide enough to show flanking lines around typical
    /// kanban-style names ("DONE", "IN REVIEW", "BACKLOG") without
    /// approaching the user's full expanded sidebar width.
    /// Tooltip still grows beyond this for unusually long names.
    private static let staticMinWidth: CGFloat = 160

    /// Minimum width for each flanking horizontal line. Ensures
    /// the lines stay clearly visible (the marker's section-header
    /// silhouette) even when the name is long enough to push the
    /// tooltip past `staticMinWidth`. Without this floor, a long
    /// name would starve the lines to ~0pt.
    private static let flankLineMinWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(lineColor)
                .frame(height: 1)
                .frame(
                    minWidth: Self.flankLineMinWidth,
                    maxWidth: .infinity
                )

            // Emoji prefix + name in a tight cluster — flanking
            // lines fill remaining space on either side of it.
            // Emoji is rendered at the canonical marker emoji
            // size (defined on SessionMarkerRow) so the same
            // glyph reads identically across all three marker
            // surfaces — expanded row, collapsed row, and this
            // tooltip.
            HStack(spacing: 4) {
                if !marker.emoji.isEmpty {
                    Text(marker.emoji)
                        .font(
                            .system(size: SessionMarkerRow.emojiGlyphSize)
                        )
                }
                if !marker.name.isEmpty {
                    Text(marker.name)
                        .chromeFont(
                            size: fontSize.caption1, weight: .bold
                        )
                        .lineLimit(1)
                        .foregroundColor(lineColor)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(lineColor)
                .frame(height: 1)
                .frame(
                    minWidth: Self.flankLineMinWidth,
                    maxWidth: .infinity
                )
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(minWidth: Self.staticMinWidth)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(strokeColor, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Equatable conformance for short-circuited diffs

/// See the matching comment on `SessionRow`'s extension.
/// `CollapsedSessionRow` and `CollapsedMarkerRow` both
/// re-evaluate on every parent body run by default,
/// because their parent (`CollapsedSessionSidebar`)
/// re-evaluates whenever ContentView's body re-evaluates
/// — which happens on every drag event, even when the
/// row's own inputs haven't changed. The explicit `==`
/// + `.equatable()` at the call site lets SwiftUI
/// short-circuit those redundant body re-evals.
extension CollapsedSessionRow: Equatable {
    static func == (
        lhs: CollapsedSessionRow,
        rhs: CollapsedSessionRow
    ) -> Bool {
        lhs.session === rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isWindowFocused == rhs.isWindowFocused
            && lhs.isOnTerminalTab == rhs.isOnTerminalTab
            && lhs.statusInfo == rhs.statusInfo
            && lhs.sidebarPosition == rhs.sidebarPosition
    }
}

extension CollapsedMarkerRow: Equatable {
    static func == (
        lhs: CollapsedMarkerRow,
        rhs: CollapsedMarkerRow
    ) -> Bool {
        lhs.marker === rhs.marker
            && lhs.sidebarPosition == rhs.sidebarPosition
    }
}
