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

    /// Known event names that we handle
    private static let knownEvents: Set<String> = [
        "session.metrics",
        "snapshot.created",
        "ledger.entry",
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
        guard phase == .idle else { return }

        // Step 1: Start listening (events buffer until sync completes)
        phase = .listening

        guard socketListener.start() else {
            phase = .idle
            return
        }

        // Step 2: Perform startup sync on background queue
        phase = .syncing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performStartupSync()
        }
    }

    /// Stop the event system. Call during applicationWillTerminate.
    func stop() {
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
        guard matchesAppSession(envelope) else { return }

        // Check if we handle this event type
        guard Self.knownEvents.contains(envelope.event) else { return }

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
    /// For now, just updates ledgerSessionId mapping. Full data model
    /// enrichment is deferred to follow-up work.
    private func applyEnrichmentData(_ response: EnrichmentService.EnrichmentResponse, sessionManager: SessionManager) {
        for sessionData in response.sessions {
            // Find matching app session
            for appSession in sessionManager.sessions {
                let claudeId = appSession.claudeSessionId
                if sessionData.sessionIdentifiers.contains(claudeId) {
                    // Update ledger session ID mapping
                    if appSession.ledgerSessionId != sessionData.ledgerSessionId {
                        appSession.ledgerSessionId = sessionData.ledgerSessionId
                    }

                    // Cache the mapping
                    ledgerSessionIdCache[sessionData.ledgerSessionId] = appSession.id
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
            sessionManager.sessions.map { $0.claudeSessionId }
        }

        guard !sessionIds.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.transitionToLive()
            }
            return
        }

        let response = enrichmentService.enrichSync(sessionIdentifiers: sessionIds)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Apply snapshot data
            if let response = response {
                self.applyEnrichmentData(response, sessionManager: sessionManager)

                // Validate process liveness for sessions that claim to be running
                self.validateProcessLiveness(sessionManager: sessionManager, enrichmentData: response)
            }

            // Step 3: Drain buffer
            self.phase = .draining

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

    // MARK: - Cache Management

    /// Clear cached mappings for a session that was closed
    func sessionClosed(_ sessionId: UUID) {
        ledgerSessionIdCache = ledgerSessionIdCache.filter { $0.value != sessionId }
    }
}
