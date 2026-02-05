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

    @Environment(\.chromeFontSize) private var chromeFontSize
    @State private var isHovered = false

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

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

            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Session info with bell indicator overlay
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    // User session ID (human-readable)
                    Text(session.userSessionId)
                        .chromeFontMono(size: fontSize.caption2, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(isSelected ? .white : .primary)

                    // Directory name + git status
                    HStack(spacing: 4) {
                        Text(session.name)
                            .chromeFontMono(size: fontSize.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let info = statusInfo, !info.gitStatusDisplay.isEmpty {
                            Text(info.gitStatusDisplay)
                                .chromeFontMono(size: fontSize.caption)
                                .foregroundColor(gitStatusColor(info: info, isSelected: isSelected))
                        }
                    }
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }

                // Unread bell indicator - bright red dot, tight to top-left corner
                // Shows instantly, fades out over 3 seconds (animation applied via withAnimation when clearing)
                Circle()
                    .fill(Color(red: 1.0, green: 0.2, blue: 0.2))  // Bright, saturated red
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.red.opacity(0.6), radius: 3, x: 0, y: 0)  // Subtle glow
                    .offset(x: -10, y: -2)  // Tight to top-left corner
                    .opacity(session.hasUnreadBell ? 1 : 0)
            }
        }
        .padding(.vertical, 6)
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
                        : (isSelected ? Color.accentColor : Color.clear))

                // Visual bell pulse overlay (only for selected session, not during drag)
                if !isPlaceholder && isSelected && session.visualBellActive {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                }
            }
        )
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

    private func gitStatusColor(info: StatusLineService.SessionStatusInfo, isSelected: Bool) -> Color {
        if isSelected {
            // Use slightly different shades when selected
            if info.isDirty { return .yellow }
            if info.hasStaged { return .green }
            return .white.opacity(0.8)
        } else {
            if info.isDirty { return .orange }
            if info.hasStaged { return .green }
            return .secondary
        }
    }
}
