import SwiftUI

/// Container that keeps an AgentsView alive per session
/// using a ZStack. Opacity + allowsHitTesting toggle
/// visibility without destroying state.
struct AgentsContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) {
                session in
                AgentsView(session: session)
                    .opacity(
                        session.id
                            == sessionManager
                            .activeSessionId
                            ? 1 : 0
                    )
                    .allowsHitTesting(
                        session.id
                            == sessionManager
                            .activeSessionId
                    )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }
}

/// Displays a session's agent runs as an index table.
/// Clicking a row opens a detail view.
struct AgentsView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize)
    private var chromeFontSize
    @Environment(\.colorScheme)
    private var colorScheme

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    // JIT data state
    @State private var agents: [AgentRun]? = nil
    @State private var isLoading: Bool = false
    @State private var fetchTask: Task<Void, Never>?

    // Detail state
    @State private var selectedAgent: AgentRun? = nil
    @State private var isBackHovered: Bool = false
    @State private var escapeMonitor: Any? = nil

    // Focus state for keyboard navigation
    @State private var focusedIndex: Int? = nil

    // Sort state
    @State private var sortColumn: SortColumn = .started
    @State private var sortAscending: Bool = true

    enum SortColumn {
        case type, status, duration, started
    }

    private var sortedAgents: [AgentRun] {
        guard let agents = agents else { return [] }
        return agents.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .type:
                result =
                    a.agentType
                    .localizedCaseInsensitiveCompare(
                        b.agentType
                    ) == .orderedAscending
            case .status:
                result =
                    a.status
                    .localizedCaseInsensitiveCompare(
                        b.status
                    ) == .orderedAscending
            case .duration:
                result =
                    (a.durationMs ?? 0)
                    < (b.durationMs ?? 0)
            case .started:
                result = a.startedAt < b.startedAt
            }
            return sortAscending ? result : !result
        }
    }

    var body: some View {
        Group {
            if selectedAgent != nil {
                detailView
            } else {
                indexView
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(Color(.textBackgroundColor))
        .onAppear { fetchAgents() }
        .onChange(of: session.ledgerSessionId) {
            fetchAgents()
        }
        .onReceive(
            sessionManager.$agentRefreshTrigger
        ) { trigger in
            guard let (sessionId, _) = trigger,
                  sessionId == session.id
            else { return }
            fetchAgents()
        }
        .onChange(of: sessionManager.listNavAction) {
            guard sessionManager.activeTab == .agents,
                  session.id
                      == sessionManager.activeSessionId,
                  selectedAgent == nil
            else { return }
            handleListNavAction()
        }
        .onChange(of: selectedAgent != nil) {
            updateEscapeMonitor()
        }
        .onChange(of: sessionManager.activeTab) {
            updateEscapeMonitor()
            if sessionManager.activeTab == .agents,
               session.id
                   == sessionManager.activeSessionId
            {
                fetchAgents()
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            updateEscapeMonitor()
        }
        .onDisappear {
            removeEscapeMonitor()
        }
    }

    // MARK: - Index View

    private var indexView: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                sortableHeader("Type", .type)
                    .frame(
                        width: 120,
                        alignment: .leading
                    )
                sortableHeader("Started", .started)
                    .frame(
                        width: 130,
                        alignment: .leading
                    )
                sortableHeader("Duration", .duration)
                    .frame(
                        width: 80,
                        alignment: .trailing
                    )
                sortableHeader("Description", nil)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .padding(.leading, 8)
                sortableHeader("Status", .status)
                    .frame(
                        width: 90,
                        alignment: .trailing
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.05)
            )

            Divider()

            if isLoading && agents == nil {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            } else if let agents = agents,
                      agents.isEmpty
            {
                Spacer()
                Text("No agents")
                    .chromeFont(
                        size: fontSize.body
                    )
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(
                                    sortedAgents
                                        .enumerated()
                                ),
                                id: \.element.id
                            ) { index, agent in
                                agentRow(
                                    agent,
                                    index: index
                                )
                                .id(agent.id)
                            }
                        }
                    }
                    .onAppear {
                        scrollToBottom(scrollProxy)
                    }
                    .onChange(of: agents?.count) {
                        scrollToBottom(scrollProxy)
                    }
                    .onChange(of: focusedIndex) {
                        if let idx = focusedIndex,
                           idx < sortedAgents.count
                        {
                            scrollProxy.scrollTo(
                                sortedAgents[idx].id
                            )
                        }
                    }
                }
            }
        }
    }

    private func agentRow(
        _ agent: AgentRun,
        index: Int
    ) -> some View {
        Button(action: {
            focusedIndex = index
            selectedAgent = agent
        }) {
            HStack(spacing: 0) {
                Text(agent.agentType)
                    .chromeFont(
                        size: fontSize.caption
                    )
                    .lineLimit(1)
                    .frame(
                        width: 120,
                        alignment: .leading
                    )

                Text(agent.displayStartedAt)
                    .chromeFont(
                        size: fontSize.caption
                    )
                    .lineLimit(1)
                    .frame(
                        width: 130,
                        alignment: .leading
                    )

                Text(agent.displayDuration)
                    .chromeFontMono(
                        size: fontSize.caption
                    )
                    .frame(
                        width: 80,
                        alignment: .trailing
                    )

                Text(
                    agent.description
                        ?? agent.agentId
                )
                .chromeFont(
                    size: fontSize.caption
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .padding(.leading, 8)

                HStack(spacing: 4) {
                    Circle()
                        .fill(agent.statusColor)
                        .frame(width: 6, height: 6)
                    Text(agent.statusLabel)
                        .chromeFont(
                            size: fontSize.caption
                        )
                }
                .frame(
                    width: 90,
                    alignment: .trailing
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                focusedIndex == index
                    ? Color.accentColor.opacity(0.15)
                    : (index % 2 == 0
                        ? Color.clear
                        : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sortableHeader(
        _ title: String,
        _ column: SortColumn?
    ) -> some View {
        Button(action: {
            guard let column = column else { return }
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        }) {
            HStack(spacing: 2) {
                Text(title)
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .fontWeight(.semibold)
                if let column = column,
                   sortColumn == column
                {
                    Image(
                        systemName: sortAscending
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 8))
                }
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(column == nil)
    }

    // MARK: - Detail View

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back button
            HStack {
                Button(action: { selectedAgent = nil }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text("All Agents")
                            .chromeFont(
                                size: fontSize.caption
                            )
                    }
                    .foregroundColor(
                        isBackHovered
                            ? .primary : .secondary
                    )
                }
                .buttonStyle(.plain)
                .onHover { isBackHovered = $0 }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            Divider()

            if let agent = selectedAgent {
                ScrollView {
                    detailContent(agent)
                        .padding(16)
                }
            }
        }
    }

    private func detailContent(
        _ agent: AgentRun
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: type + status
            HStack(spacing: 8) {
                Text(agent.agentType)
                    .chromeFont(
                        size: fontSize.title2
                    )
                    .fontWeight(.semibold)

                HStack(spacing: 4) {
                    Circle()
                        .fill(agent.statusColor)
                        .frame(width: 8, height: 8)
                    Text(agent.statusLabel)
                        .chromeFont(
                            size: fontSize.caption
                        )
                }
                .padding(
                    .horizontal, 8
                )
                .padding(.vertical, 3)
                .background(
                    agent.statusColor.opacity(0.15)
                )
                .cornerRadius(4)
            }

            // Metadata grid
            VStack(
                alignment: .leading, spacing: 6
            ) {
                if let desc = agent.description {
                    detailField(
                        "Description", desc
                    )
                }
                detailField(
                    "Agent ID", agent.agentId
                )
                detailField(
                    "Duration",
                    agent.displayDuration
                )
                detailField(
                    "Started",
                    agent.displayStartedAt
                )
                if let completed = agent.completedAt {
                    detailField(
                        "Completed",
                        AgentRun.formatTimestamp(
                            completed
                        )
                    )
                }
                if let path = agent.transcriptPath {
                    detailField(
                        "Transcript",
                        abbreviatePath(path)
                    )
                }
            }

            // Prompt
            if let prompt = agent.prompt,
               !prompt.isEmpty
            {
                detailSection("Prompt") {
                    Text(prompt)
                        .chromeFontMono(
                            size: fontSize.caption
                        )
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(8)
                        .background(
                            Color.primary
                                .opacity(0.05)
                        )
                        .cornerRadius(4)
                }
            }

            // Last message
            if let msg = agent.lastMessage,
               !msg.isEmpty
            {
                detailSection("Response") {
                    Text(msg)
                        .chromeFontMono(
                            size: fontSize.caption
                        )
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(8)
                        .background(
                            Color.primary
                                .opacity(0.05)
                        )
                        .cornerRadius(4)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private func detailField(
        _ label: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .chromeFont(size: fontSize.caption)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .chromeFont(size: fontSize.caption)
                .textSelection(.enabled)
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .chromeFont(size: fontSize.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func abbreviatePath(
        _ path: String
    ) -> String {
        let home = FileManager.default
            .homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~"
                + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Scroll

    private func scrollToBottom(
        _ proxy: ScrollViewProxy
    ) {
        if let lastId = sortedAgents.last?.id {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
    }

    // MARK: - Escape Key (AppKit monitor)

    private func updateEscapeMonitor() {
        let shouldBeInstalled =
            selectedAgent != nil
            && session.id
                == sessionManager.activeSessionId
            && sessionManager.activeTab == .agents
        if shouldBeInstalled {
            installEscapeMonitor()
        } else {
            removeEscapeMonitor()
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor =
            NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { event in
                // 53 = Escape
                if event.keyCode == 53 {
                    guard self.session.id
                        == self.sessionManager
                            .activeSessionId,
                        self.sessionManager.activeTab
                            == .agents
                    else { return event }

                    DispatchQueue.main.async {
                        self.selectedAgent = nil
                    }
                    return nil  // Consume
                }
                return event
            }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: - Data Fetching

    private func fetchAgents() {
        guard let lsid = session.ledgerSessionId
        else { return }

        fetchTask?.cancel()
        fetchTask = Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let result =
                    try await AgentsQueryService
                    .shared
                    .fetchAgents(
                        ledgerSessionId: lsid
                    )
                guard !Task.isCancelled else {
                    return
                }
                agents = result
                if focusedIndex == nil,
                   !result.isEmpty
                {
                    focusedIndex =
                        result.count - 1
                }

            } catch {
                guard !Task.isCancelled else {
                    return
                }
                GalaxyLog.events(
                    "AgentsView fetch failed:"
                    + " \(error)"
                )
            }
        }
    }

    // MARK: - Keyboard Navigation

    private func handleListNavAction() {
        guard let action =
            sessionManager.listNavAction
        else { return }

        defer {
            sessionManager.listNavAction = nil
        }

        let count = sortedAgents.count
        guard count > 0 else { return }

        switch action {
        case .up:
            if let idx = focusedIndex {
                focusedIndex = max(0, idx - 1)
            } else {
                focusedIndex = count - 1
            }
        case .down:
            if let idx = focusedIndex {
                focusedIndex = min(
                    count - 1, idx + 1
                )
            } else {
                focusedIndex = 0
            }
        case .activate:
            if let idx = focusedIndex,
               idx < count
            {
                selectedAgent = sortedAgents[idx]
            }
        }
    }
}

// MARK: - Agent Running Badge

/// Small green badge showing running agent count.
/// Observes session.runningAgentCount.
struct AgentRunningBadge: View {
    @ObservedObject var session: Session

    var body: some View {
        if session.runningAgentCount > 0 {
            Text("\(session.runningAgentCount)")
                .font(
                    .system(
                        size: 12,
                        weight: .bold,
                        design: .monospaced
                    )
                )
                .foregroundColor(.green)
        }
    }
}
