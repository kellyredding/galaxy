import SwiftUI
import Combine

struct RestoreSessionView: View {
    let onDismiss: () -> Void

    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var selectedId: UUID? = nil
    @State private var searchText: String = ""
    @State private var searchFocusTrigger: Int = 0
    private let searchSubject = PassthroughSubject<String, Never>()
    @State private var debouncedSearch: String = ""
    @State private var debounceCancel: AnyCancellable? = nil
    @State private var scrollProxy: ScrollViewProxy? = nil

    /// Closed sessions filtered by the debounced search query.
    private var filteredSessions: [PersistedClosedSession] {
        guard !debouncedSearch.isEmpty else {
            return sessionManager.closedSessions
        }
        let query = debouncedSearch.lowercased()
        return sessionManager.closedSessions.filter { closed in
            let s = closed.session
            let name = displayName(for: s).lowercased()
            let persona = (s.personaName ?? "").lowercased()
            let dir = abbreviatedPath(s.workingDirectory).lowercased()
            let time = relativeTime(closed.closedAt).lowercased()
            return name.contains(query)
                || persona.contains(query)
                || dir.contains(query)
                || time.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Table or empty state
            if sessionManager.closedSessions.isEmpty {
                emptyState
            } else if filteredSessions.isEmpty {
                noMatchesState
            } else {
                tableContent
            }

            Divider()

            // Button row
            buttonRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 500, idealWidth: 640, minHeight: 300, idealHeight: 420)
        .onAppear {
            // Select the first (most recently closed) session
            selectedId = sessionManager.closedSessions.first?.session.id

            // Focus the search field so the user can start typing immediately
            searchFocusTrigger += 1

            // Set up debounce pipeline
            debounceCancel = searchSubject
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .removeDuplicates()
                .sink { query in
                    debouncedSearch = query
                    // Re-select first match after filter changes
                    if let first = filteredSessions.first {
                        selectedId = first.session.id
                    } else {
                        selectedId = nil
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreSessionNavigateUp)) { _ in
            moveSelection(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreSessionNavigateDown)) { _ in
            moveSelection(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreSessionConfirm)) { _ in
            restoreSelected()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            SafeSearchField(
                text: $searchText,
                placeholder: "Filter sessions...",
                fontSize: 12,
                focusTrigger: searchFocusTrigger,
                isActive: true,
                onTextChange: { searchSubject.send($0) },
                onSubmit: { restoreSelected() }
            )
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    debouncedSearch = ""
                    selectedId = sessionManager.closedSessions.first?.session.id
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.controlBackgroundColor))
        )
    }

    // MARK: - Table Content

    private var tableContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Header
                tableHeader
                    .padding(.horizontal, 16)

                // Rows
                LazyVStack(spacing: 0) {
                    ForEach(filteredSessions, id: \.session.id) { closed in
                        tableRow(closed)
                            .id(closed.session.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedId = closed.session.id
                            }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    selectedId = closed.session.id
                                    restoreSelected()
                                }
                            )
                    }
                }
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Persona")
                .frame(width: 80, alignment: .leading)
            Text("Directory")
                .frame(width: 160, alignment: .leading)
            Text("Closed")
                .frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.vertical, 4)
    }

    private func tableRow(_ closed: PersistedClosedSession) -> some View {
        let s = closed.session
        let isSelected = selectedId == s.id
        let dirExists = FileManager.default.fileExists(atPath: s.workingDirectory)

        return HStack(spacing: 0) {
            Text(displayName(for: s))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(s.personaName ?? "—")
                .lineLimit(1)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: 3) {
                if !dirExists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 9))
                        .help("Directory no longer exists")
                }
                Text(abbreviatedPath(s.workingDirectory))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            .frame(width: 160, alignment: .leading)
            Text(relativeTime(closed.closedAt))
                .lineLimit(1)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No recently closed sessions")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No sessions match \"\(debouncedSearch)\"")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Button Row

    private var buttonRow: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Restore") {
                restoreSelected()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedId == nil || filteredSessions.isEmpty)
        }
    }

    // MARK: - Actions

    private func restoreSelected() {
        guard let id = selectedId,
              let closed = filteredSessions.first(where: { $0.session.id == id })
        else { return }
        sessionManager.restoreSession(closedSession: closed)
        onDismiss()
    }

    private func moveSelection(by offset: Int) {
        let sessions = filteredSessions
        guard !sessions.isEmpty else { return }

        let currentIndex = sessions.firstIndex(where: { $0.session.id == selectedId }) ?? 0
        let newIndex = min(max(currentIndex + offset, 0), sessions.count - 1)
        let newId = sessions[newIndex].session.id
        selectedId = newId
        scrollProxy?.scrollTo(newId, anchor: .center)
    }

    // MARK: - Helpers

    /// Display name for a persisted session — mirrors Session.displayName logic.
    private func displayName(for s: PersistedSession) -> String {
        if let name = s.givenName, !name.isEmpty {
            return "\(name) (\(s.sessionRef))"
        }
        if let suggested = s.ledgerSuggestedName, !suggested.isEmpty {
            return "\(suggested) (\(s.sessionRef))"
        }
        return s.sessionRef
    }

    /// Abbreviate a path by replacing the home directory with ~.
    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Format a date as fuzzy relative time.
    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
