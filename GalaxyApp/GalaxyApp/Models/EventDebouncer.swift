import Foundation

/// Debounces events by the composite key (ledger_session_id, event, ref).
///
/// Each unique key gets its own independent 400ms debounce window with
/// replacement semantics: when a duplicate arrives during the quiet period,
/// the previous pending event is discarded and the timer resets.
///
/// All operations happen on the main queue.
final class EventDebouncer {
    /// Debounce window duration
    private let interval: TimeInterval

    /// Pending timers keyed by debounce key
    private var timers: [DebounceKey: DispatchWorkItem] = [:]

    /// Callback invoked on the main queue when a debounced event fires
    var onFire: ((EventEnvelope) -> Void)?

    init(interval: TimeInterval = 0.4) {
        self.interval = interval
    }

    /// Submit an event for debouncing. If the same key is already pending,
    /// the previous event is replaced and the timer resets.
    func submit(_ envelope: EventEnvelope) {
        let key = DebounceKey(
            ledgerSessionId: envelope.ledgerSessionId,
            event: envelope.event,
            ref: envelope.ref
        )

        // Cancel any existing timer for this key (replacement semantics)
        timers[key]?.cancel()

        // Schedule new timer
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.timers.removeValue(forKey: key)
            self.onFire?(envelope)
        }

        timers[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    /// Cancel all pending timers (used during shutdown)
    func cancelAll() {
        for (_, workItem) in timers {
            workItem.cancel()
        }
        timers.removeAll()
    }

    /// Number of pending debounced events (for testing/debugging)
    var pendingCount: Int { timers.count }
}

// MARK: - Debounce Key

private struct DebounceKey: Hashable {
    let ledgerSessionId: Int64
    let event: String
    let ref: String?
}
