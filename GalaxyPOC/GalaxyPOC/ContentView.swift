import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var settingsManager: SettingsManager

    // Track width during drag (nil when not dragging, uses settings value)
    @State private var draggingWidth: CGFloat? = nil

    private let toolbarHeight: CGFloat = 28

    private var isSidebarVisible: Bool {
        sessionManager.isSidebarVisible
    }

    private var sidebarWidth: CGFloat {
        // Use live dragging width if actively dragging, otherwise use persisted setting
        draggingWidth ?? settingsManager.settings.sidebarWidth
    }

    /// The currently active session (for terminal font control)
    private var activeSession: Session? {
        guard let activeId = sessionManager.activeSessionId else { return nil }
        return sessionManager.sessions.first { $0.id == activeId }
    }

    private var sidebarOnLeft: Bool {
        settingsManager.settings.sidebarPosition == .left
    }

    var body: some View {
        VStack(spacing: 0) {
            // Control bar
            controlBar

            // Main content area
            HStack(spacing: 0) {
                if sidebarOnLeft {
                    sidebarSection
                    resizeHandle
                    detailSection
                } else {
                    detailSection
                    resizeHandle
                    sidebarSection
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            if sidebarOnLeft {
                sidebarToggleButton
                Spacer()
            } else {
                Spacer()
                sidebarToggleButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: toolbarHeight)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var sidebarToggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                sessionManager.isSidebarVisible.toggle()
            }
        }) {
            Image(systemName: sidebarOnLeft ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 14))
                .foregroundColor(isSidebarVisible ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(isSidebarVisible ? "Hide Sessions" : "Show Sessions")
    }

    @ViewBuilder
    private var sidebarSection: some View {
        if isSidebarVisible {
            SessionSidebar()
                .frame(width: sidebarWidth)
                .transaction { t in
                    // Disable animations during drag for smooth tracking
                    if draggingWidth != nil {
                        t.animation = nil
                    }
                }
                .transition(.move(edge: sidebarOnLeft ? .leading : .trailing))
        }
    }

    @ViewBuilder
    private var resizeHandle: some View {
        if isSidebarVisible {
            // Visual separator line with invisible drag handle overlay
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)
                .overlay(
                    SidebarResizeHandle(
                        currentWidth: sidebarWidth,
                        sidebarOnLeft: sidebarOnLeft,
                        onWidthChange: { newWidth in
                            draggingWidth = newWidth
                        },
                        onDragEnd: { finalWidth in
                            settingsManager.settings.sidebarWidth = finalWidth
                            draggingWidth = nil
                        }
                    )
                    .frame(width: 9)  // Wider hit area
                )
                .zIndex(100)  // Ensure resize handle is above terminal view
        }
    }

    private var detailSection: some View {
        Group {
            if sessionManager.sessions.isEmpty {
                EmptyStateView()
            } else {
                TerminalContainerView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Background color matching terminal emulator (black in dark, white in light)
    private var terminalBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    /// Text color for contrast against terminal background
    private var terminalForeground: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .chromeFont(size: fontSize.iconLarge)
                .foregroundColor(.secondary)

            Text("No Sessions")
                .chromeFont(size: fontSize.title2)
                .foregroundColor(terminalForeground)

            Text("Run `galaxy` from any directory to start a session")
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)

            Text("cd ~/projects/my-app && galaxy")
                .chromeFontMono(size: fontSize.body)
                .padding(8)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
    }
}

struct TerminalContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                SessionContentView(
                    session: session,
                    isActive: session.id == sessionManager.activeSessionId,
                    onResume: { sessionManager.resumeSession(sessionId: session.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wrapper view that observes individual session state changes
struct SessionContentView: View {
    @ObservedObject var session: Session
    let isActive: Bool
    let onResume: () -> Void

    var body: some View {
        Group {
            if session.hasExited {
                // Show stopped session UI
                StoppedSessionView(session: session, onResume: onResume)
            } else {
                // Show terminal
                FocusableTerminalView(
                    session: session,
                    isActive: isActive
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
    }
}

// MARK: - Sidebar Resize Handle (AppKit-based for smooth dragging)

/// NSViewRepresentable wrapper for smooth mouse-tracked sidebar resizing.
/// Uses AppKit's direct mouse events instead of SwiftUI's DragGesture for better performance.
struct SidebarResizeHandle: NSViewRepresentable {
    let currentWidth: CGFloat
    let sidebarOnLeft: Bool
    let onWidthChange: (CGFloat) -> Void
    let onDragEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.sidebarOnLeft = sidebarOnLeft
        view.onWidthChange = onWidthChange
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.currentWidth = currentWidth
        nsView.sidebarOnLeft = sidebarOnLeft
        nsView.onWidthChange = onWidthChange
        nsView.onDragEnd = onDragEnd
    }
}

/// AppKit NSView that handles mouse events directly for smooth resize dragging.
/// This view is transparent - SwiftUI handles the visual separator line.
class ResizeHandleNSView: NSView {
    var currentWidth: CGFloat = 220
    var sidebarOnLeft: Bool = true
    var onWidthChange: ((CGFloat) -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?

    private var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Transparent - no visual, just mouse handling
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.pop()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartX = NSEvent.mouseLocation.x
        dragStartWidth = currentWidth
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentX = NSEvent.mouseLocation.x
        let delta = currentX - dragStartX

        // When sidebar is on left, dragging right increases width
        // When sidebar is on right, dragging left increases width
        let newWidth: CGFloat
        if sidebarOnLeft {
            newWidth = dragStartWidth + delta
        } else {
            newWidth = dragStartWidth - delta
        }

        // Clamp to allowed range
        let clamped = min(max(newWidth, AppSettings.sidebarWidthRange.lowerBound),
                          AppSettings.sidebarWidthRange.upperBound)
        onWidthChange?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()

        // Calculate final width
        let currentX = NSEvent.mouseLocation.x
        let delta = currentX - dragStartX
        let newWidth: CGFloat
        if sidebarOnLeft {
            newWidth = dragStartWidth + delta
        } else {
            newWidth = dragStartWidth - delta
        }
        let clamped = min(max(newWidth, AppSettings.sidebarWidthRange.lowerBound),
                          AppSettings.sidebarWidthRange.upperBound)
        onDragEnd?(clamped)
    }
}
