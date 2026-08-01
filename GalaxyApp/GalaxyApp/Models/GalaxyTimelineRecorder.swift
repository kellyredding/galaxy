import Foundation
import Galactic

extension TerminalTimelineRecorder {

    /// Records terminal events into this app's ledger.
    ///
    /// The one place that knows both the shared event vocabulary and this app's
    /// transport. Everything upstream of it describes what happened; only this
    /// decides where it goes, which is what lets the describing half be shared
    /// with an app that has no ledger to describe it into.
    ///
    /// The size hint picks the transport. Detail normally rides as command
    /// arguments, which have a length ceiling the operating system enforces —
    /// and the events carrying note bodies are exactly the ones that would
    /// breach it, so those go over standard input instead. The hint says the
    /// payload may be unbounded rather than naming the transport, so this stays
    /// the only code that has to know a ceiling exists at all.
    /// The two names this app gives the places terminal events come from.
    ///
    /// Load-bearing stored values, not labels: they are already written into
    /// thousands of ledger rows, and anything grouping or filtering by source
    /// sees a split dataset the day they change. They live here, beside the
    /// transport, because what this app calls its own code is this app's to say
    /// — shared code asks rather than assuming, so the emitting code can move
    /// between modules without rewriting history's idea of where it was.
    static let galaxyLedger = TerminalTimelineRecorder(
        terminalSource: "galaxy-app/views/terminal",
        scrollbackSource: "galaxy-app/views/scrollback"
    ) { event in
        if event.detailMayBeLarge {
            TimelineService.recordViaStdin(
                ledgerSessionId: event.sessionID,
                eventType: event.type,
                source: event.source,
                durationIdentifier: event.durationIdentifier,
                detailData: event.detail
            )
        } else {
            TimelineService.record(
                ledgerSessionId: event.sessionID,
                eventType: event.type,
                source: event.source,
                durationIdentifier: event.durationIdentifier,
                detailData: event.detail
            )
        }
    }
}
