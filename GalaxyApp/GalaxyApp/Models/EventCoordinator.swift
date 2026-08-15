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
        "timeline.turn:abandoned",
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
        // A turn the ledger closed on the session's behalf, because a
        // clear, a compact or a session ending found one still open.
        // The turn is over by the time this is written, and without it a
        // session that ended mid-turn stayed in-turn until the process
        // exit cleared it by a different route.
        "timeline.turn:abandoned",
    ]

    /// Agent-start event that increments runningAgentCount.
    private static let agentStartEvent =
        "timeline.agent:started"

    /// Agent-end events. Each prompts a re-read of the count
    /// rather than adjusting it.
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

    /// Ledger sessions already reported as unmatched, so the no-match
    /// path logs once per session instead of once per event. Galaxy's
    /// socket receives events for every claude session on the machine,
    /// so most events are for sessions it does not own.
    private var loggedUnmatchedSessions: Set<Int64> = []

    // MARK: - Diagnostic monitoring
    //
    // A periodic heartbeat that produces a diagnostic-only log.
    // Read-only — it never mutates session state. It logs a
    // one-line digest of all running session turn states,
    // anchoring the log so an agent investigating a future bug
    // can scan recent state at a glance.

    /// How often the heartbeat dumps per-session turn state.
    private static let heartbeatInterval:
        TimeInterval = 60.0

    /// Heartbeat timer. Kept on `RunLoop.main` in `.common`
    /// mode so it fires regardless of UI mode.
    private var heartbeatTimer: Timer?

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

        // Scheduled before the socket guard, deliberately. A
        // lost flock disables the event system, and that is
        // precisely when a periodic re-read is the only thing
        // keeping the count honest — a backstop downstream of
        // the thing it backs up is not a backstop.
        startPeriodicMonitors()

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
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        debouncer.cancelAll()
        socketListener.stop()
        eventBuffer.removeAll()
        ledgerSessionIdCache.removeAll()
        loggedUnmatchedSessions.removeAll()
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
            // Galaxy's socket receives events for every claude session
            // on the machine (Assist Ant agents, Terminal sessions, …),
            // not just its own, so unmatched events are the expected
            // common case. Log only the first miss per ledger session —
            // at full volume this path was thousands of per-event,
            // main-thread file writes.
            if loggedUnmatchedSessions.insert(
                envelope.ledgerSessionId
            ).inserted {
                GalaxyLog.dbg(
                    "route",
                    "no app session for"
                    + " ledger_session_id=\(envelope.ledgerSessionId)"
                    + " (first miss; event=\(envelope.event),"
                    + " identifiers=\(envelope.sessionIdentifiers));"
                    + " suppressing further misses for this session"
                )
            }
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
                let refTag = envelope.ref
                    .map { " ref=\($0)" } ?? ""
                GalaxyLog.events(
                    "[\(session.sessionRef)]"
                    + " routeEvent:"
                    + " \(envelope.event)\(refTag)"
                )
                session.startTurn(
                    source: "socket:\(envelope.event)",
                    ref: envelope.ref
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
                let refTag = envelope.ref
                    .map { " ref=\($0)" } ?? ""
                GalaxyLog.events(
                    "[\(session.sessionRef)] routeEvent:"
                    + " \(envelope.event)\(refTag)"
                )
                session.endTurn(
                    source: "socket:\(envelope.event)",
                    ref: envelope.ref
                )
            }
            // Also trigger enrichment (context may have changed)
            debouncer.submit(envelope)
            return
        }

        // Agent-start event: ask the CLI what is running now.
        //
        // The event is a trigger, not data. It used to carry the
        // count itself by incrementing a set, which meant an
        // event that never arrived — a session the cache could
        // not match, a payload without an agent_id, a socket
        // that never came up — left the number permanently
        // wrong. Reading the database instead makes a missed
        // event cost accuracy only until the next read.
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
                    + " routeEvent: \(envelope.event)"
                    + " — refreshing from the CLI"
                )
                sessionManager?
                    .agentRefreshTrigger =
                    (appSessionId, Date())
            }
            debouncer.submit(envelope)
            return
        }

        // Agent-end event: same trigger, same re-read. Covers
        // stopped, failed and abandoned alike, so a row swept by
        // reconcile lands here too and the badge follows.
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
                    + " routeEvent: \(envelope.event)"
                    + " — refreshing from the CLI"
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
        // the Galaxy-side synthetic turn here (opened by the
        // optimistic startTurn in sendCommand) so the dot
        // stops pulsing and the timeline bar closes. Auto-
        // /handoff after these commands is gated separately on
        // the session:ready event from on_clear / on_compact
        // via waitForReady. Fall through to normal enrichment
        // handling below.
        if Self.contextResetEvents.contains(envelope.event) {
            if let appSessionId =
                ledgerSessionIdCache[envelope.ledgerSessionId],
               let session = sessionManager?.sessions
                   .first(where: { $0.id == appSessionId }),
               session.isInTurn
            {
                let refTag = envelope.ref
                    .map { " ref=\($0)" } ?? ""
                GalaxyLog.events(
                    "[\(session.sessionRef)] routeEvent:"
                    + " context-reset endTurn"
                    + " via \(envelope.event)\(refTag)"
                )
                session.endTurn(
                    source: "socket:\(envelope.event)",
                    ref: envelope.ref
                )
            }
        }

        // Resume event: the on_resume hook records a
        // session:resumed timeline event during SessionStart
        // processing, before Claude has fully rendered the
        // transcript and shown the prompt. The on_resume hook
        // also emits a `session:ready` direct-socket event
        // (handled below) once it completes, which is what
        // SessionManager.resumeSession listens for to fire
        // /galaxy:resume. timeline.session:resumed remains
        // a no-op here — kept as a comment marker in case
        // future logic needs to hook session-resumed.

        // Session ready: emitted by the on_resume / on_startup /
        // on_clear / on_compact hooks once they finish running.
        // ref disambiguates the lifecycle path. We act on
        // "resume", "clear", and "compact" — each gates a
        // pending /handoff or /galaxy:resume sendCommand via
        // Session.markReady and the matching waitForReady call.
        // "startup" is a no-op (on_startup fires before a fresh
        // session would have any work queued for it).
        if envelope.event == "session:ready" {
            let actionableRefs: Set<String> = [
                "resume", "clear", "compact",
            ]
            if let ref = envelope.ref,
               actionableRefs.contains(ref),
               let appSessionId =
                   ledgerSessionIdCache[
                       envelope.ledgerSessionId
                   ],
               let session = sessionManager?.sessions
                   .first(where: { $0.id == appSessionId })
            {
                GalaxyLog.events(
                    "[\(session.sessionRef)] routeEvent:"
                    + " session:ready ref=\(ref)"
                )
                session.markReady()
            }
            return
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

                // Resolve the session this request belongs to.
                let appSessionId =
                    self?.ledgerSessionIdCache[
                        envelope.ledgerSessionId
                    ]
                guard let appSessionId,
                      let session = sm.sessions.first(
                          where: { $0.id == appSessionId }
                      )
                else { return }

                // Still needed below to gate the notification, which is a
                // separate decision from the indicator.
                let isViewing = sm.isViewing(session)

                // A permission or question prompt while this session is not the
                // focused terminal means Claude wants attention.
                sm.markAttentionWanted(for: session)

                // Notification (focus-gated)
                if settings.notifyPermissionRequest, !isViewing {
                    NotificationService.shared
                        .notifyPermissionRequest(
                            sessionId: appSessionId,
                            displayName:
                                session.displayName
                        )
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

        // Artifact annotation/review events: the same review-button
        // refresh, keyed by artifact number. The events also carry a
        // row id, but the reader identifies its open artifact by
        // number and the has-pending query takes a number, so the id
        // would only have to be translated back. The value arrives as
        // an Int64 regardless of its width on the wire, so it is
        // narrowed here rather than requested as an Int32 — asking
        // for the narrower type yields nil and silently skips the
        // refresh.
        if [
            "timeline.artifact.annotation:created",
            "timeline.artifact.annotation:updated",
            "timeline.artifact.annotation:deleted",
            "timeline.artifact.review:created",
        ].contains(envelope.event),
           let rawNumber = envelope.detailValue(
               "artifact_number", as: Int64.self
           ),
           let artifactNumber = Int32(exactly: rawNumber)
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
                    sm.pendingArtifactReviewCheck
                        = artifactNumber
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
            } else {
                GalaxyLog.events("Startup sync returned no data")
            }

            // Sweep anything stranded while the app was down,
            // then take the counts that sweep reported.
            self.reconcileAndResync()

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

        // Anchor log: one-line digest of every session's
        // initial turn state. Lets a future investigator
        // grep back to the most recent `Phase → live` and
        // see what state Galaxy came up in.
        if let manager = sessionManager {
            let parts = manager.sessions.map { s in
                let inTurn = s.isInTurn ? "BUSY" : "idle"
                return "\(s.sessionRef)=\(inTurn)"
            }
            let summary = parts.isEmpty
                ? "no sessions"
                : parts.joined(separator: ", ")
            GalaxyLog.events(
                "Initial turn state:"
                + " \(manager.sessions.count) session(s):"
                + " \(summary)"
            )
        }
    }

    // MARK: - Periodic Monitors (heartbeat + reconcile)

    /// Schedule the periodic heartbeat and agent reconcile.
    /// Fires on `RunLoop.main` in `.common` mode so it
    /// continues during modal UI, scrolling, etc.
    ///
    /// The reconcile is a sibling of the heartbeat rather than
    /// a line inside it: `logHeartbeat` returns early when no
    /// session is running, and cleanup matters most in exactly
    /// that state.
    ///
    /// Idempotent — a second call replaces the timer rather
    /// than stacking one, since this now runs before the
    /// socket guard and must not double up on a restart.
    private func startPeriodicMonitors() {
        heartbeatTimer?.invalidate()

        let timer = Timer(
            timeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.logHeartbeat()
            self?.reconcileAndResync()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// Periodic per-session turn-state digest. Skips when
    /// no sessions are running so an idle Galaxy doesn't
    /// spam the log.
    private func logHeartbeat() {
        guard let manager = sessionManager else { return }
        let running = manager.sessions.filter { $0.isRunning }
        guard !running.isEmpty else { return }

        let now = Date()
        let parts = running.map { s -> String in
            if s.isInTurn {
                if let started = s.currentTurnStartedAt {
                    let secs = Int(
                        now.timeIntervalSince(started)
                    )
                    return "\(s.sessionRef)=BUSY(\(secs)s)"
                }
                return "\(s.sessionRef)=BUSY"
            }
            return "\(s.sessionRef)=idle"
        }

        GalaxyLog.dbg(
            "heartbeat",
            "\(running.count) running:"
            + " \(parts.joined(separator: ", "))"
        )
    }

    // MARK: - Agent Count Reconciliation

    /// Sweep agents whose owning process is gone, then apply
    /// the counts the sweep reported.
    ///
    /// One subprocess for every session, not one per session:
    /// reconcile resolves ownership itself and answers for the
    /// whole database, which matters at twenty-odd open
    /// sessions where a per-session read would mean twenty
    /// spawns a minute forever.
    ///
    /// The counts are read by the CLI *after* it sweeps, so
    /// there is no window in which this applies a pre-sweep
    /// number and sits wrong until the next tick.
    ///
    /// Safe to call before startup sync finishes: sessions
    /// without a resolved ledger id are simply skipped, and
    /// they will be picked up by whichever read comes next.
    private func reconcileAndResync() {
        guard let manager = sessionManager else { return }

        Task {
            do {
                let result = try await AgentsQueryService
                    .shared.reconcile()

                await MainActor.run {
                    if result.skipped {
                        GalaxyLog.events(
                            "reconcile skipped by"
                            + " GALAXY_AGENTS_SKIP_RECONCILE"
                        )
                        return
                    }

                    for session in manager.sessions {
                        guard let lsid =
                            session.ledgerSessionId
                        else { continue }

                        let fresh = result.count(for: lsid)
                        guard fresh
                            != session.runningAgentCount
                        else { continue }

                        GalaxyLog.events(
                            "[\(session.sessionRef)]"
                            + " runningAgentCount"
                            + " \(session.runningAgentCount)"
                            + " → \(fresh) via reconcile"
                        )
                        session.setRunningAgentCount(fresh)
                    }
                }
            } catch {
                GalaxyLog.events(
                    "reconcile failed: \(error)"
                )
            }
        }
    }

    // MARK: - Cache Management

    /// Clear cached mappings for a session that was closed
    func sessionClosed(_ sessionId: UUID) {
        ledgerSessionIdCache = ledgerSessionIdCache.filter { $0.value != sessionId }
        // Re-evaluate unmatched sessions on the next event, in case the
        // changed session set affects what can match.
        loggedUnmatchedSessions.removeAll()
    }
}
