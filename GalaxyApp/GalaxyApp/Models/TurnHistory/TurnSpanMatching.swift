import Foundation

/// Matches a turn's start to the end that closed it, by the turn's own
/// identifier rather than by time.
///
/// Every turn event carries `turn--<uuid>`, minted once per turn, so the
/// identifier alone says which end closes which start. Time is the wrong key:
/// a turn the ledger closes as stale is stamped with the turn's start time,
/// read from a different clock than the start event's own, and can land a
/// moment before it — which, paired by time, left the turn drawn as ongoing
/// for good.
enum TurnSpanMatching {
    struct Result {
        /// Each start with the end that closed it, the end re-timed to the
        /// start's instant when it was stamped before it.
        var matched: [(start: TimelineEvent, end: TimelineEvent)] = []
        /// Starts no end closed among the events given — still running, or
        /// closed outside them.
        var unmatchedStarts: [TimelineEvent] = []
        /// Ends whose start is not among the events given.
        var unmatchedEnds: [TimelineEvent] = []
    }

    /// Pair the starts and ends sharing one turn identifier.
    ///
    /// The earliest end closes the turn. Any later end describes a turn that
    /// was already over, so it is dropped rather than returned, where it
    /// could go on to close some other turn's start.
    static func match(
        starts: [TimelineEvent],
        ends: [TimelineEvent]
    ) -> Result {
        let starts = starts.sorted(by: earlier)
        let ends = ends.sorted(by: earlier)

        var result = Result()
        guard !starts.isEmpty else {
            result.unmatchedEnds = ends
            return result
        }
        guard !ends.isEmpty else {
            result.unmatchedStarts = starts
            return result
        }

        for (start, end) in zip(starts, ends) {
            result.matched.append((start, end: atOrAfter(end, start)))
        }
        result.unmatchedStarts = Array(starts.dropFirst(ends.count))
        return result
    }

    /// Time first, row id to break a tie, so the order never depends on
    /// the order the events arrived in.
    private static func earlier(_ a: TimelineEvent, _ b: TimelineEvent) -> Bool {
        (a.occurredAt, a.id) < (b.occurredAt, b.id)
    }

    private static func atOrAfter(
        _ end: TimelineEvent,
        _ start: TimelineEvent
    ) -> TimelineEvent {
        guard end.occurredAt < start.occurredAt else { return end }
        return TimelineEvent(
            id: end.id,
            eventType: end.eventType,
            occurredAt: start.occurredAt,
            source: end.source,
            durationIdentifier: end.durationIdentifier,
            detailData: end.detailData,
            createdAt: end.createdAt,
            updatedAt: end.updatedAt
        )
    }
}
