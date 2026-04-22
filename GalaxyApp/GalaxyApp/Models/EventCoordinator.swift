import Foundation

/// Orchestrates the Galaxy event system: socket listener, event routing,
/// debouncing, enrichment, and session state updates.
///
/// Startup sequence (critical ordering):
/// 1. Create socket, start NWListener (events buffer in queue)
/// 2. Call `galaxy-ledger sessions --json` for current truth
/// 3. Drain buffer, merge with snapshot (latest timestamp wins)
/// 4. Mark sync complete — process events in real-time
///
/// Uses main-queue-only state to avoid actor/threading complexity.
/// The socket listener dispatches events to main queue; all state
/// mutation happens there.
final class EventCoordinator {
    /// Sync phase states
    enum Phase: String {
        case idle
        case listening    // Socket is bound, buffering events
        case syncing      // Snapshot sync in progress
        case draining     // Processing buffered events
        case live         // Real-time event processing
    }

    /// Known event names that we handle.
    ///
    /// Lifecycle events flow through the timeline pipeline
    /// (timeline.* prefix). Refresh signals (session.metrics,
    /// ledger.entry) remain as direct socket events — they
    /// are high-frequency operational signals with no
    /// historical value.
    private static let knownEvents: Set<String> = [
        // Refresh signals (direct socket, no DB)
        "session.metrics",
        "ledger.entry",
        "artifact.show",
        "snapshot.show",
        // Lifecycle events (timeline → DB → socket)
        "timeline.session:started",
        "timeline.session:resumed",
        "timeline.context:cleared",
        "timeline.context:compacted",
        "timeline.snapshot.annotation:created",
        "timeline.snapshot.annotation:updated",
        "timeline.snapshot.annotation:deleted",
        "timeline.snapshot.review:created",
        "timeline.scrollback.note:created",
        "timeline.scrollback.note:updated",
        "timeline.scrollback.note:deleted",
        "timeline.turn:initiated",
        "timeline.turn:completed",
        "timeline.turn:failed",
        "timeline.turn:continued",
        "timeline.turn:interrupted",
        "timeline.agent:started",
        "timeline.agent:stopped",
        "timeline.agent:failed",
        "timeline.agent:abandoned",
        // Artifact lifecycle (timeline → DB → socket)
        "timeline.artifact:created",
        "timeline.artifact:updated",
        "timeline.artifact:deleted",
        "timeline.artifact.annotation:created",
        "timeline.artifact.annotation:updated",
        "timeline.artifact.annotation:deleted",
        "timeline.artifact.review:created",
    ]

    /// Turn-start event that triggers startTurn().
    private static let turnStartEvent =
        "timeline.turn:initiated"

    /// Turn-end events that trigger immediate session.endTurn().
    /// These are real-time state signals, not enrichment triggers.
    private static let turnEndEvents: Set<String> = [
        "timeline.turn:completed",
        "timeline.turn:failed",
        "timeline.turn:continued",
        "timeline.turn:interrupted",
    ]

    /// Agent-start event that increments runningAgentCount.
    private static let agentStartEvent =
        "timeline.agent:started"

    /// Agent-end events that decrement runningAgentCount.
    private static let agentEndEvents: Set<String> = [
        "timeline.agent:stopped",
        "timeline.agent:failed",
        "timeline.agent:abandoned",
    ]

    /// Context-reset events from /clear and /compact slash
    /// commands. These skip the normal prompt→stop lifecycle
    /// (no turn:completed is ever published), so they serve
    /// as the turn-end signal for Galaxy-initiated turns.
    private static let contextResetEvents: Set<String> = [
        "timeline.context:cleared",
        "timeline.context:compacted",
    ]

    private(set) var phase: Phase = .idle

    private let socketListener: SocketListener
    private let debouncer: EventDebouncer
    private let enrichmentService: EnrichmentService
    private weak var sessionManager: SessionManager?

    /// Event buffer for startup (events received before sync completes)
    private var eventBuffer: [EventEnvelope] = []

    /// Cache of ledger_session_id → app Session UUID mappings
    /// Once we learn a mapping, subsequent events can match on the integer directly
    private var ledgerSessionIdCache: [Int64: UUID] = [:]

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        self.socketListener = SocketListener()
        self.debouncer = EventDebouncer()
        self.enrichmentService = EnrichmentService()

        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        // Socket listener → event routing (main queue)
        socketListener.onEvent = { [weak self] envelope in
            self?.handleEvent(envelope)
        }

        // Debouncer → enrichment
        debouncer.onFire = { [weak self] envelope in
            self?.triggerEnrichment(for: envelope)
        }
    }

    // MARK: - Lifecycle

    /// Start the event system. Call during applicationDidFinishLaunching.
    func start() {
        guard phase == .idle else {
            GalaxyLog.events("start() called but phase=\(phase.rawValue), ignoring")
            return
        }

        GalaxyLog.events("Starting event system")

        // Step 1: Start listening (events buffer until sync completes)
        phase = .listening
        GalaxyLog.events("Phase → listening")

        guard socketListener.start() else {
            GalaxyLog.events("Socket listener failed to start — event system disabled")
            phase = .idle
            return
        }

        // Step 2: Perform startup sync on background queue
        phase = .syncing
        GalaxyLog.events("Phase → syncing")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performStartupSync()
        }
    }

    /// Stop the event system. Call during applicationWillTerminate.
    func stop() {
        GalaxyLog.events("Stopping event system")
        debouncer.cancelAll()
        socketListener.stop()
        eventBuffer.removeAll()
        ledgerSessionIdCache.removeAll()
        phase = .idle
    }

    // MARK: - Event Routing

    /// Handle an incoming event envelope. Called on the main queue.
    private func handleEvent(_ envelope: EventEnvelope) {
        // Route based on current phase
        switch phase {
        case .listening, .syncing:
            // Buffer events until sync completes
            eventBuffer.append(envelope)
        case .draining, .live:
            // Process immediately
            routeEvent(envelope)
        case .idle:
            break
        }
    }

    /// Route a single event to the appropriate handler.
    private func routeEvent(_ envelope: EventEnvelope) {
        // Check if this event is for a session we know about
        guard matchesAppSession(envelope) else {
            GalaxyLog.events(
                "routeEvent: no match for event=\(envelope.event)"
                + " ledger_session_id=\(envelope.ledgerSessionId)"
                + " identifiers=\(envelope.sessionIdentifiers)"
            )
            return
        }

        // Turn-start event: enter turn immediately
        if envelope.event == Self.turnStartEvent {
            if let appSessionId =
                ledgerSessionIdCache[
                    envelope.ledgerSessionId
                ],
               let session = sessionManager?.sessions
                   .first(where: { $0.id == appSessionId })
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)]"
                    + " routeEvent:"
                    + " \(envelope.event)"
                )
                session.startTurn(
                    source:
                        "socket:\(envelope.event)"
                )
            }
            // No enrichment needed for turn start
            return
        }

        // Turn-end events: transition session to idle immediately
        // (no debouncing — this is a real-time state signal).
        if Self.turnEndEvents.contains(envelope.event) {
            if let appSessionId =
                ledgerSessionIdCache[envelope.ledgerSessionId],
               let session = sessionManager?.sessions
                   .first(where: { $0.id == appSessionId })
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)] routeEvent:"
                    + " \(envelope.event)"
                )
                session.endTurn(
                    source: "socket:\(envelope.event)"
                )
            }
            // Also trigger enrichment (context may have changed)
            debouncer.submit(envelope)
            return
        }

        // Agent-start event: increment running count
        // and notify AgentsView to refresh its list.
        // Socket events own the count; the CLI fetch
        // only refreshes the list (no count correction).
        if envelope.event == Self.agentStartEvent {
            if let appSessionId =
                ledgerSessionIdCache[
                    envelope.ledgerSessionId
                ],
               let session = sessionManager?.sessions
                   .first(where: {
                       $0.id == appSessionId
                   })
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)]"
                    + " routeEvent:"
                    + " agent count +1"
                    + " via \(envelope.event)"
                )
                session.runningAgentCount += 1
                sessionManager?
                    .agentRefreshTrigger =
                    (appSessionId, Date())
            }
            debouncer.submit(envelope)
            return
        }

        // Agent-end events: decrement running count
        // and notify AgentsView to refresh its list.
        // Socket events own the count; the CLI fetch
        // only refreshes the list (no count correction).
        if Self.agentEndEvents.contains(
            envelope.event
        ) {
            if let appSessionId =
                ledgerSessionIdCache[
                    envelope.ledgerSessionId
                ],
               let session = sessionManager?.sessions
                   .first(where: {
                       $0.id == appSessionId
                   })
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)]"
                    + " routeEvent:"
                    + " agent count -1"
                    + " via \(envelope.event)"
                )
                session.runningAgentCount = max(
                    0,
                    session.runningAgentCount - 1
                )
                sessionManager?
                    .agentRefreshTrigger =
                    (appSessionId, Date())
            }
            debouncer.submit(envelope)
            return
        }

        // Context-reset events: /clear and /compact are slash
        // commands that skip the normal prompt→stop lifecycle,
        // so no turn:completed event is ever published. End
        // the Galaxy-side turn here so afterNextIdle actions
        // (e.g. queued /handoff) can fire. Fall through to
        // normal enrichment handling below.
        if Self.contextResetEvents.contains(envelope.event) {
            if let appSessionId =
                ledgerSessionIdCache[envelope.ledgerSessionId],
               let session = sessionManager?.sessions
                   .first(where: { $0.id == appSessionId }),
               session.isInTurn
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)] routeEvent:"
                    + " context-reset endTurn"
                    + " via \(envelope.event)"
                )
                session.endTurn(
                    source:
                        "socket:\(envelope.event)"
                )
            }
        }

        // Resume event: the on_resume hook records a
        // session:resumed timeline event during SessionStart
        // processing, before Claude has fully rendered the
        // transcript and shown the prompt. Poll the terminal
        // buffer for the resume marker (the hook's output
        // line), then send /galaxy:resume once it appears.
        if envelope.event == "timeline.session:resumed" {
            if let appSessionId =
                ledgerSessionIdCache[envelope.ledgerSessionId],
               let session = sessionManager?.sessions
                   .first(where: { $0.id == appSessionId }),
               session.isRunning && !session.hasExited
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)] routeEvent:"
                    + " waiting for resume marker"
                    + " via \(envelope.event)"
                )
                session.waitForResumeMarker {
                    GalaxyLog.events(
                        "[\(session.sessionRef)]"
                        + " resume marker found,"
                        + " sending /galaxy:resume"
                    )
                    session.sendCommand(
                        "/galaxy:resume"
                    )
                }
            }
        }

        // Permission request: play sound + optional notification
        if envelope.event == "permission_request" {
            DispatchQueue.main.async { [weak self] in
                guard let sm = self?.sessionManager
                else { return }
                let settings =
                    SettingsManager.shared.settings

                // Play sound (always, regardless of focus)
                SettingsManager.shared.playSound(
                    settings.permissionRequestSound
                )

                // Notification (focus-gated)
                let appSessionId =
                    self?.ledgerSessionIdCache[
                        envelope.ledgerSessionId
                    ]
                if settings.notifyPermissionRequest,
                   let appSessionId,
                   let session = sm.sessions.first(
                       where: { $0.id == appSessionId }
                   )
                {
                    let isViewing =
                        appSessionId
                            == sm.activeSessionId
                        && sm.activeTab == .terminal
                        && sm.isWindowFocused
                    if !isViewing {
                        NotificationService.shared
                            .notifyPermissionRequest(
                                sessionId: appSessionId,
                                displayName:
                                    session.displayName
                            )
                    }
                }
            }
            return
        }

        // Check if we handle this event type
        guard Self.knownEvents.contains(envelope.event) else { return }

        // Snapshot show: switch tab + open the snapshot
        // in the reader. If the event's session is
        // active, apply immediately. Otherwise queue
        // via SessionManager — when the user later
        // switches to that session, the tab + reader
        // come up "ready."
        if envelope.event == "snapshot.show",
           let number = envelope.detailValue(
               "snapshot_number", as: Int64.self
           )
        {
            let snapNumber = Int32(number)
            DispatchQueue.main.async { [weak self] in
                guard let sm = self?.sessionManager
                else { return }
                let appSessionId =
                    self?.ledgerSessionIdCache[
                        envelope.ledgerSessionId
                    ]
                guard let appSessionId else { return }

                if appSessionId == sm.activeSessionId {
                    sm.activeTab = .snapshots
                    sm.pendingSnapshotNumber = snapNumber
                } else {
                    sm.queueSnapshotShow(
                        sessionId: appSessionId,
                        number: snapNumber
                    )
                }
            }
            return
        }

        // Artifact show: switch tab + open the artifact
        // in the reader. Parallel to snapshot.show above
        // — active-session path applies immediately,
        // non-active-session path queues via
        // SessionManager for delivery on next switch.
        if envelope.event == "artifact.show",
           let number = envelope.detailValue(
               "artifact_number", as: Int64.self
           )
        {
            let artNumber = Int32(number)
            DispatchQueue.main.async { [weak self] in
                guard let sm = self?.sessionManager
                else { return }
                let appSessionId =
                    self?.ledgerSessionIdCache[
                        envelope.ledgerSessionId
                    ]
                guard let appSessionId else { return }

                if appSessionId == sm.activeSessionId {
                    sm.activeTab = .artifacts
                    sm.pendingArtifactShow = artNumber
                } else {
                    sm.queueArtifactShow(
                        sessionId: appSessionId,
                        number: artNumber
                    )
                }
            }
            return
        }

        // Annotation/review events: notify SessionManager
        // for button refresh. The snapshot_id comes from the
        // timeline event's detail_data.
        if [
            "timeline.snapshot.annotation:created",
            "timeline.snapshot.annotation:updated",
            "timeline.snapshot.annotation:deleted",
            "timeline.snapshot.review:created",
        ].contains(envelope.event),
           let snapshotId = envelope.detailValue(
               "snapshot_id", as: Int64.self
           )
        {
            DispatchQueue.main.async { [weak self] in
                guard let sm = self?.sessionManager
                else { return }
                if let appSessionId =
                    self?.ledgerSessionIdCache[
                        envelope.ledgerSessionId
                    ],
                   appSessionId
                       == sm.activeSessionId
                {
                    sm.pendingReviewCheck = snapshotId
                }
            }
        }

        // All known events go through debouncer → enrichment
        debouncer.submit(envelope)
    }

    // MARK: - Session Matching

    /// Check if an event matches any session in our app.
    /// Also caches the ledger_session_id mapping for future fast lookups.
    private func matchesAppSession(_ envelope: EventEnvelope) -> Bool {
        guard let sessionManager = sessionManager else { return false }

        // Fast path: check cached ledger_session_id mapping
        if ledgerSessionIdCache[envelope.ledgerSessionId] != nil {
            return true
        }

        // Slow path: match on session_identifiers array
        for session in sessionManager.sessions {
            let claudeId = session.claudeSessionId
            if envelope.sessionIdentifiers.contains(claudeId) {
                // Cache the mapping for fast future lookups
                ledgerSessionIdCache[envelope.ledgerSessionId] = session.id
                // Also store on the session itself
                session.ledgerSessionId = envelope.ledgerSessionId
                GalaxyLog.events("Matched session \(claudeId) → ledger_session_id=\(envelope.ledgerSessionId), cached")
                return true
            }
        }

        return false
    }

    // MARK: - Enrichment

    /// Trigger an enrichment call after debounce fires.
    private func triggerEnrichment(for envelope: EventEnvelope) {
        guard sessionManager != nil else { return }

        // Collect session identifiers for the enrichment call
        // Use all identifiers from the event (ledger already resolved them)
        let identifiers = envelope.sessionIdentifiers

        enrichmentService.enrich(sessionIdentifiers: identifiers) { [weak self] response in
            guard let self = self, let sessionManager = self.sessionManager, let response = response else {
                return
            }

            self.applyEnrichmentData(response, sessionManager: sessionManager)
        }
    }

    /// Apply enrichment data to app sessions.
    /// Updates all ledger-tracked properties on matching Sessions.
    private func applyEnrichmentData(
        _ response: EnrichmentService.EnrichmentResponse,
        sessionManager: SessionManager
    ) {
        for sessionData in response.sessions {
            // Find matching app session
            for appSession in sessionManager.sessions {
                let claudeId = appSession.claudeSessionId
                if sessionData.sessionIdentifiers.contains(claudeId) {
                    // Don't let two app sessions claim the
                    // same ledger session. Polluted identifier
                    // lists (from orphan consolidation or PID
                    // recycling) can cause a ledger session's
                    // identifiers to match multiple app
                    // sessions. Without this guard, enrichment
                    // cycles could converge both sessions to
                    // the same claudeSessionId/ledgerSessionId.
                    let alreadyClaimed =
                        sessionManager.sessions.contains {
                            $0.id != appSession.id
                            && $0.ledgerSessionId
                                == sessionData.ledgerSessionId
                        }
                    if alreadyClaimed { continue }

                    // Cache the mapping
                    ledgerSessionIdCache[sessionData.ledgerSessionId] = appSession.id

                    // Apply all enrichment fields
                    appSession.ledgerSessionId = sessionData.ledgerSessionId
                    appSession.ledgerSessionIdentifiers = sessionData.sessionIdentifiers
                    appSession.ledgerCurrentSessionIdentifier = sessionData.currentSessionIdentifier

                    // Guard @Published property — only assign when value changed
                    if appSession.ledgerSuggestedName != sessionData.suggestedName {
                        appSession.ledgerSuggestedName = sessionData.suggestedName
                    }

                    appSession.ledgerClaudePids = sessionData.claudePids
                    appSession.ledgerCurrentClaudePid = sessionData.currentClaudePid

                    // Guard @Published property — only assign when value changed
                    if appSession.ledgerCwd != sessionData.cwd {
                        appSession.ledgerCwd = sessionData.cwd
                    }

                    appSession.ledgerProjectDir = sessionData.projectDir
                    appSession.ledgerGitBranch = sessionData.gitBranch
                    appSession.ledgerModelId = sessionData.modelId
                    appSession.ledgerModelDisplayName = sessionData.modelDisplayName
                    appSession.ledgerClaudeVersion = sessionData.claudeVersion
                    appSession.ledgerContextPercentage = sessionData.contextPercentage

                    // High Context Warning notification + enrichment-based reset
                    let notifSettings = SettingsManager.shared.settings
                    if let pct = sessionData.contextPercentage {
                        let intPct = Int(pct)
                        let threshold = notifSettings.notifyHighContextThreshold

                        if intPct < threshold {
                            // Context dropped below threshold — reset so warning
                            // can fire again on the next crossing. Handles clear,
                            // compact, auto-clear, and natural reduction.
                            NotificationService.shared.resetHighContextWarning(
                                for: appSession.id
                            )
                        } else if notifSettings.notifyHighContext {
                            // Above threshold — send notification if not suppressed
                            let isViewingSession = appSession.id
                                    == sessionManager.activeSessionId
                                && sessionManager.activeTab == .terminal
                                && sessionManager.isWindowFocused
                            if !isViewingSession {
                                NotificationService.shared.notifyHighContext(
                                    sessionId: appSession.id,
                                    displayName: appSession.displayName,
                                    contextPct: intPct
                                )
                            }
                        }
                    }

                    appSession.ledgerTokensUsed = sessionData.tokensUsed
                    appSession.ledgerTokensMax = sessionData.tokensMax
                    appSession.ledgerCostUsd = sessionData.costUsd
                    appSession.ledgerLinesAdded = sessionData.linesAdded
                    appSession.ledgerLinesRemoved = sessionData.linesRemoved
                    appSession.ledgerStartedAt = sessionData.startedAt
                    appSession.ledgerUpdatedAt = sessionData.updatedAt
                    appSession.ledgerSuggestedNameData = sessionData.suggestedNameData

                    // Keep claudeSessionId current with the ledger's
                    // latest session identifier (tracks /clear and resumes)
                    if let current = sessionData.currentSessionIdentifier,
                       appSession.claudeSessionId != current {
                        GalaxyLog.events(
                            "Updating claudeSessionId: "
                            + "\(appSession.claudeSessionId) → \(current)"
                        )
                        appSession.claudeSessionId = current
                    }

                    // Refresh git status for this session only
                    StatusLineService.shared.refreshSession(appSession)

                    // Persist updated enrichment data
                    SessionPersistence.shared.markDirty()

                    // Bump version counter so LedgerView re-renders
                    // with the latest enrichment data
                    appSession.ledgerVersion += 1

                    break
                }
            }
        }
    }

    // MARK: - Startup Sync

    /// Perform the startup snapshot sync. Called on a background queue.
    private func performStartupSync() {
        guard let sessionManager = sessionManager else {
            DispatchQueue.main.async { [weak self] in
                self?.transitionToLive()
            }
            return
        }

        // Collect all known session identifiers from the app
        let sessionIds: [String] = DispatchQueue.main.sync {
            // Pre-populate ledgerSessionIdCache from persisted
            // values so the fast path works immediately for
            // events that arrive before enrichment completes.
            // Without this, the slow path can match the wrong
            // session when identifiers overlap across sessions.
            for session in sessionManager.sessions {
                if let lsid = session.ledgerSessionId {
                    self.ledgerSessionIdCache[lsid]
                        = session.id
                }
            }
            return sessionManager.sessions
                .map { $0.claudeSessionId }
        }

        guard !sessionIds.isEmpty else {
            GalaxyLog.events("No app sessions to sync — skipping startup enrichment")
            DispatchQueue.main.async { [weak self] in
                self?.transitionToLive()
            }
            return
        }

        GalaxyLog.events("Startup sync — querying \(sessionIds.count) session(s)")
        let response = enrichmentService.enrichSync(sessionIdentifiers: sessionIds)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Apply snapshot data
            if let response = response {
                GalaxyLog.events("Startup sync complete — \(response.sessions.count) session(s) enriched")
                self.applyEnrichmentData(response, sessionManager: sessionManager)

                // Validate process liveness for sessions that claim to be running
                self.validateProcessLiveness(sessionManager: sessionManager, enrichmentData: response)
            } else {
                GalaxyLog.events("Startup sync returned no data")
            }

            // Seed running agent counts from CLI
            self.seedRunningAgentCounts(
                sessionManager: sessionManager
            )

            // Step 3: Drain buffer
            self.phase = .draining
            GalaxyLog.events("Phase → draining (\(self.eventBuffer.count) buffered events)")

            for envelope in self.eventBuffer {
                self.routeEvent(envelope)
            }
            self.eventBuffer.removeAll()

            // Step 4: Go live
            self.transitionToLive()
        }
    }

    /// Transition to live mode — real-time event processing
    private func transitionToLive() {
        phase = .live
        GalaxyLog.events("Phase → live — real-time event processing active")
    }

    /// Validate that sessions claiming to be running actually have live processes.
    /// Called after startup sync to catch sessions whose process died while app was stopped.
    private func validateProcessLiveness(sessionManager: SessionManager, enrichmentData: EnrichmentService.EnrichmentResponse) {
        for sessionData in enrichmentData.sessions {
            guard let pids = sessionData.claudePids else { continue }

            for pid in pids {
                _ = kill(pid_t(pid), 0) == 0
            }
        }
    }

    // MARK: - Agent Count Seeding

    /// Seed running agent counts from the CLI during
    /// startup sync. Called on the main queue after
    /// enrichment completes.
    private func seedRunningAgentCounts(
        sessionManager: SessionManager
    ) {
        for session in sessionManager.sessions {
            guard let lsid = session.ledgerSessionId
            else { continue }

            // Fire-and-forget async query per session
            Task {
                do {
                    let count =
                        try await AgentsQueryService
                        .shared
                        .fetchRunningCount(
                            ledgerSessionId: lsid
                        )
                    await MainActor.run {
                        if session.runningAgentCount
                            != count
                        {
                            session.runningAgentCount
                                = count
                            GalaxyLog.events(
                                "[\(session.sessionRef)]"
                                + " seeded"
                                + " runningAgentCount"
                                + " = \(count)"
                            )
                        }
                    }
                } catch {
                    GalaxyLog.events(
                        "Agent count seed failed"
                        + " for session"
                        + " \(session.sessionRef):"
                        + " \(error)"
                    )
                }
            }
        }
    }

    // MARK: - Cache Management

    /// Clear cached mappings for a session that was closed
    func sessionClosed(_ sessionId: UUID) {
        ledgerSessionIdCache = ledgerSessionIdCache.filter { $0.value != sessionId }
    }
}
