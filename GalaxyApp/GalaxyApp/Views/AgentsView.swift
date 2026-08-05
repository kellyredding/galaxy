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

    // Transcript → artifact resolution for the detail view.
    // Populated by resolveTranscriptArtifact() when an agent is
    // opened. Nil means "not resolved yet" or "no matching
    // artifact"; the UI degrades to plain text either way.
    @State private var transcriptArtifact:
        ArtifactSummary? = nil
    @State private var isTranscriptHovered: Bool = false

    // Abandon-confirmation state for the detail view's
    // "Mark as abandoned" affordance. Visible only while
    // the selected agent's status is "running".
    @State private var showAbandonConfirm: Bool = false
    @State private var isAbandoning: Bool = false
    @State private var abandonErrorMessage: String? = nil

    /// Order and selection. The selection is an identity rather than a row
    /// number, so re-sorting cannot slide the highlight onto another run.
    @State private var model = ListSortModel<AgentRun, SortColumn>(
        columns: AgentsView.columns,
        sortColumn: .started,
        sortAscending: true)

    enum SortColumn {
        case type, status, duration, started
    }

    /// Description is missing on purpose: it is the one column with nothing
    /// to sort by, and its header is a plain label rather than a button.
    private static let columns: [ListColumn<AgentRun, SortColumn>] = [
        .init(.type, title: "Type") {
            ListSorting.compareText($0.agentType, $1.agentType)
        },
        .init(.started, title: "Started", prefersAscending: false) {
            ListSorting.compare($0.startedAt, $1.startedAt)
        },
        .init(.duration, title: "Duration", prefersAscending: false) {
            ListSorting.compare($0.durationMs ?? 0, $1.durationMs ?? 0)
        },
        .init(.status, title: "Status") {
            ListSorting.compareText($0.status, $1.status)
        },
    ]

    private var sortedAgents: [AgentRun] { model.sorted(agents) }

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
        .listNavigation(
            from: sessionManager,
            isActive: {
                sessionManager.activeTab == .agents
                    && session.id
                        == sessionManager.activeSessionId
                    && selectedAgent == nil
            },
            onAction: { action in
                switch action {
                case .up:
                    model.move(.up, in: sortedAgents)
                case .down:
                    model.move(.down, in: sortedAgents)
                case .activate:
                    selectedAgent = model.focusedElement(
                        in: sortedAgents)
                }
            })
        .onChange(of: selectedAgent != nil) {
            updateEscapeMonitor()
        }
        // Mirror local detail state up to the session so
        // NavigationCoordinator can observe it for history
        // recording. Paired with the observer below.
        .onChange(of: selectedAgent?.agentId) { _, newValue in
            if session.selectedAgentId != newValue {
                session.selectedAgentId = newValue
            }
        }
        // React to external writes to session.selectedAgentId
        // (e.g., from NavigationCoordinator.apply during
        // back/forward). Opens or closes the detail view.
        .onChange(of: session.selectedAgentId) { _, newValue in
            guard session.id == sessionManager.activeSessionId
            else { return }
            if selectedAgent?.agentId == newValue { return }
            applyExternalAgentSelection(newValue)
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
        // Resolve transcript → artifact whenever a new agent
        // is opened. Keyed on agentId so switching between
        // agents cancels any in-flight lookup.
        .task(id: selectedAgent?.agentId) {
            await resolveTranscriptArtifact()
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
                sortableHeader(.type)
                    .frame(
                        width: 120,
                        alignment: .leading
                    )
                sortableHeader(.started)
                    .frame(
                        width: 130,
                        alignment: .leading
                    )
                sortableHeader(.duration)
                    .frame(
                        width: 80,
                        alignment: .trailing
                    )
                fixedHeader("Description")
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .padding(.leading, 8)
                sortableHeader(.status)
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
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.3")
                        .chromeFont(
                            size: fontSize.iconLarge
                        )
                        .foregroundColor(.secondary)
                    Text("No agents")
                        .chromeFont(
                            size: fontSize.title2
                        )
                        .foregroundColor(.primary)
                    Text(
                        "Sub-agent runs appear here when "
                        + "Claude delegates a task"
                    )
                    .chromeFont(size: fontSize.body)
                    .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if agents == nil {
                // Same empty state for the post-load /
                // never-populated case — mirrors the
                // Snapshots and Artifacts indexes so the
                // user never sees a blank pane while a
                // ledger session ID is still resolving or
                // a fetch hasn't returned its first batch.
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.3")
                        .chromeFont(
                            size: fontSize.iconLarge
                        )
                        .foregroundColor(.secondary)
                    Text("No agents")
                        .chromeFont(
                            size: fontSize.title2
                        )
                        .foregroundColor(.primary)
                    Text(
                        "Sub-agent runs appear here when "
                        + "Claude delegates a task"
                    )
                    .chromeFont(size: fontSize.body)
                    .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
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
                    .onChange(of: model.focusedId) {
                        if let id = model.focusedId {
                            scrollProxy.scrollTo(id)
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
            model.focusedId = agent.id
            selectedAgent = agent
        }) {
            HStack(spacing: 0) {
                Text(agent.agentType)
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .lineLimit(1)
                    .frame(
                        width: 120,
                        alignment: .leading
                    )

                Text(agent.displayStartedAt)
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .lineLimit(1)
                    .frame(
                        width: 130,
                        alignment: .leading
                    )

                Text(agent.displayDuration)
                    .chromeFontMono(
                        size: fontSize.caption2
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
                    size: fontSize.caption2
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
                            size: fontSize.caption2
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
                model.focusedId == agent.id
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
        _ column: SortColumn
    ) -> some View {
        Button(action: { model.select(column) }) {
            HStack(spacing: 2) {
                headerLabel(model.title(for: column))
                if model.sortColumn == column {
                    Image(
                        systemName: model.sortAscending
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 8))
                }
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// The one column with nothing to sort by, so nothing to press either.
    private func fixedHeader(_ title: String) -> some View {
        headerLabel(title)
            .foregroundColor(.secondary)
    }

    private func headerLabel(_ title: String) -> some View {
        Text(title)
            .chromeFont(size: fontSize.caption2)
            .fontWeight(.semibold)
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

    /// Header row for the detail view: agent type, status
    /// pill, and (when running) a "Mark as abandoned"
    /// affordance sitting flush against the pill.
    /// Extracted from `detailContent` to keep the parent
    /// ViewBuilder small enough for SwiftUI's type checker
    /// to handle.
    private func detailHeader(
        _ agent: AgentRun
    ) -> some View {
        HStack(spacing: 8) {
            Text(agent.agentType)
                .chromeFont(size: fontSize.title2)
                .fontWeight(.semibold)

            statusPill(agent)

            if agent.isRunning {
                abandonButton
            }
        }
    }

    private func statusPill(
        _ agent: AgentRun
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(agent.statusColor)
                .frame(width: 8, height: 8)
            Text(agent.statusLabel)
                .chromeFont(size: fontSize.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(agent.statusColor.opacity(0.15))
        .cornerRadius(4)
    }

    /// Cleanup affordance for stuck-running rows (e.g. the
    /// parent session crashed and never fired its
    /// end-of-session abandon sweep). The detail header
    /// only renders this when `agent.isRunning`, so it
    /// disappears once the status flips.
    ///
    /// Styling deliberately mirrors `statusPill` so the
    /// affordance reads as a sibling to the Running label
    /// — same caption font, padding, corner radius, and a
    /// neutral ghost background.
    private var abandonButton: some View {
        Button {
            showAbandonConfirm = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 9))
                Text("Mark as abandoned")
                    .chromeFont(size: fontSize.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(isAbandoning)
        .help(
            "Mark this agent's record as abandoned. Use "
            + "when the agent actually crashed or was "
            + "killed externally (e.g. kernel panic) and "
            + "will never report back. Does not stop a "
            + "live process."
        )
    }

    private func detailContent(
        _ agent: AgentRun
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            detailHeader(agent)

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
                        ListTimestamp.format(
                            completed
                        )
                    )
                }
                if let path = agent.transcriptPath {
                    if let artifact = transcriptArtifact {
                        detailLinkField(
                            "Transcript",
                            abbreviatePath(path),
                            action: {
                                openTranscriptArtifact(
                                    artifact
                                )
                            }
                        )
                    } else {
                        detailField(
                            "Transcript",
                            abbreviatePath(path)
                        )
                    }
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
        .confirmationDialog(
            "Mark agent as abandoned?",
            isPresented: $showAbandonConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark as abandoned") {
                Task { await performAbandon() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                "This only updates Galaxy's record of "
                    + "the agent. It does not stop a "
                    + "live process. Use this when the "
                    + "agent has already crashed or "
                    + "been killed."
            )
        }
        .alert(
            "Couldn't mark as abandoned",
            isPresented: Binding(
                get: { abandonErrorMessage != nil },
                set: {
                    if !$0 { abandonErrorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(abandonErrorMessage ?? "")
        }
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

    /// Link-styled variant of `detailField`. Renders the value
    /// in the accent color, underlines it on hover, and swaps
    /// the cursor to the pointing hand — same signals macOS
    /// users expect from clickable text. The action fires on
    /// click.
    private func detailLinkField(
        _ label: String,
        _ value: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .chromeFont(size: fontSize.caption)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Button(action: action) {
                Text(value)
                    .chromeFont(size: fontSize.caption)
                    .foregroundColor(.accentColor)
                    .underline(isTranscriptHovered)
            }
            .buttonStyle(.plain)
            .help("Open in Artifacts")
            .onHover { hovering in
                isTranscriptHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
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

    /// A binding added here also needs a row in `KeystrokeCatalog`, with an
    /// availability case naming its gate — nothing fails to say so, because
    /// the catalog restates these facts rather than deriving them.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor =
            NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { event in
                // Stand down while the cheat sheet claims the keyboard.
                // This one clears `selectedAgent` — silently losing the
                // row the user was on, with no visible cue that anything
                // happened.
                if KeystrokeSheetModel.isClaimingKeyboard { return event }

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
                seedAgentTitles(result)
                // Seeded at the newest run, which is the end this list
                // scrolls to.
                model.reconcileFocus(
                    in: sortedAgents, seed: .last)

            } catch {
                guard !Task.isCancelled else {
                    return
                }
                if (error as? AgentsQueryError)?
                    .isSuperseded == true
                {
                    GalaxyLog.events(
                        "AgentsView fetch superseded"
                        + " by a newer one"
                    )
                } else {
                    GalaxyLog.events(
                        "AgentsView fetch failed:"
                        + " \(error)"
                    )
                }
            }
        }
    }

    /// Abandon the currently selected agent, then refresh
    /// both the local list and the selectedAgent binding so
    /// the detail view reflects the new status (orange pill,
    /// "Abandoned" label, concrete duration) immediately.
    /// The CLI's `agent:abandoned` timeline event also flows
    /// through EventCoordinator to decrement the tab badge,
    /// but the local `agents` array is independent of that
    /// event stream and needs an explicit refresh.
    @MainActor
    private func performAbandon() async {
        guard let agent = selectedAgent,
              let lsid = session.ledgerSessionId
        else { return }

        isAbandoning = true
        defer { isAbandoning = false }

        do {
            try await AgentsQueryService.shared
                .abandonAgent(
                    ledgerSessionId: lsid,
                    agentId: agent.agentId
                )

            await refreshAfterAbandon(
                agentId: agent.agentId,
                lsid: lsid
            )
        } catch {
            abandonErrorMessage =
                error.localizedDescription
        }
    }

    /// Re-fetch the agents list after an abandon and
    /// re-bind selectedAgent so the detail view picks up
    /// the new status without waiting for the next polling
    /// fetch. Keeps writes off the polling subprocess lane
    /// — but read-back uses the polling lane, which is fine
    /// since this fetch is the most recent thing on it.
    @MainActor
    private func refreshAfterAbandon(
        agentId: String,
        lsid: Int64
    ) async {
        do {
            let all = try await AgentsQueryService
                .shared
                .fetchAgents(ledgerSessionId: lsid)
            agents = all
            if selectedAgent?.agentId == agentId,
               let fresh = all.first(where: {
                   $0.agentId == agentId
               })
            {
                selectedAgent = fresh
            }
        } catch {
            // Non-fatal — the next polling fetch (or
            // event-driven refresh) will catch up.
            GalaxyLog.events(
                "AgentsView refreshAfterAbandon "
                + "failed: \(error)"
            )
        }
    }

    /// Look up the artifact whose source_path matches the
    /// selected agent's transcript file. Called from a
    /// `.task(id:)` keyed on agentId — it auto-cancels when
    /// the user switches agents. Results seed the session's
    /// artifact title cache so NavigationCoordinator can
    /// render a real title on the first history push instead
    /// of "Artifact #N".
    @MainActor
    private func resolveTranscriptArtifact() async {
        // Reset eagerly — until we confirm a match, the
        // transcript renders as plain text.
        transcriptArtifact = nil

        guard let agent = selectedAgent,
              let path = agent.transcriptPath,
              let lsid = session.ledgerSessionId
        else { return }

        do {
            let match = try await ArtifactQueryService
                .shared
                .artifact(
                    forSourcePath: path, in: lsid
                )
            guard !Task.isCancelled,
                  selectedAgent?.agentId
                    == agent.agentId
            else { return }
            if let found = match {
                transcriptArtifact = found
                session.recordArtifactInfo(
                    number: found.number,
                    title: found.title,
                    type: found.artifactType
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            GalaxyLog.events(
                "AgentsView transcript artifact"
                + " lookup failed: \(error)"
            )
        }
    }

    /// Navigate to the artifact reader for the given
    /// artifact. Mutations to `openArtifactNumber` and
    /// `activeTab` are observed by NavigationCoordinator,
    /// which debounces them into a single history entry —
    /// Back returns the user to this agent detail page.
    private func openTranscriptArtifact(
        _ artifact: ArtifactSummary
    ) {
        session.openArtifactNumber = artifact.number
        sessionManager.activeTab = .artifacts
    }

    /// Seed the session's agent title cache so
    /// NavigationCoordinator can resolve history
    /// entry titles at push time.
    private func seedAgentTitles(
        _ list: [AgentRun]
    ) {
        for agent in list {
            session.recordAgentInfo(
                id: agent.agentId,
                type: agent.agentType,
                description: agent.description
            )
        }
    }

    /// Apply an external selection change (e.g., from
    /// NavigationCoordinator.apply during history restoration).
    /// Falls back to nil if the agent is no longer in the list.
    private func applyExternalAgentSelection(
        _ newValue: String?
    ) {
        guard let agentId = newValue else {
            selectedAgent = nil
            return
        }
        if let match = agents?.first(where: {
            $0.agentId == agentId
        }) {
            selectedAgent = match
        } else {
            // Agent not in cache — refetch and retry once.
            fetchAgents()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.3
            ) {
                if let match = agents?.first(where: {
                    $0.agentId == agentId
                }) {
                    selectedAgent = match
                } else {
                    selectedAgent = nil
                }
            }
        }
    }

    // MARK: - Keyboard Navigation

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
