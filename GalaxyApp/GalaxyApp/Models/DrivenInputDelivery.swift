import Foundation
import Galactic

/// Delivers what a driven session's owner sends: kept on the session's
/// timeline as `session.input:sent`, and handed to the agent as a short
/// pointer through the inbox. Never typed in whole, so a slash command in a
/// driver's text arrives as text the agent reads.
///
/// One delivery at a time per session, in the order sent: recording is a
/// subprocess, and two racing would let a later message's pointer reach the
/// agent first. Main queue only; the store answers there too.
final class DrivenInputDelivery {
    static let shared = DrivenInputDelivery()

    private struct Item {
        let input: DrivenInput
        let owner: String
        let completion: (Int64?) -> Void
    }

    private var queues: [UUID: [Item]] = [:]
    private var delivering: Set<UUID> = []

    /// `completion` gets the recorded event's id, or nil when it could not be
    /// recorded. A session with no ledger session yet waits for one first.
    func deliver(
        _ input: DrivenInput,
        to session: Session,
        owner: String,
        completion: @escaping (Int64?) -> Void
    ) {
        queues[session.id, default: []].append(
            Item(input: input, owner: owner, completion: completion))
        pump(session)
    }

    private func pump(_ session: Session) {
        guard !delivering.contains(session.id),
            let item = queues[session.id]?.first
        else { return }
        delivering.insert(session.id)

        session.whenLedgerSessionKnown { [weak self, weak session] ledgerSessionId in
            guard let self, let session else { return }
            self.record(item, ledgerSessionId: ledgerSessionId) { eventID in
                if let eventID {
                    session.enqueueMessage(
                        item.input.pointer(
                            owner: item.owner,
                            readCommand: ReviewStore.galaxyTimeline.readCommand(eventID)),
                        sourceLabel: "Sent by \(item.owner)",
                        origin: .driver)
                } else {
                    GalaxyLog.events(
                        "[\(session.sessionRef)] driver input from \(item.owner)"
                            + " was not recorded, so it was not delivered")
                }
                item.completion(eventID)
                self.queues[session.id]?.removeFirst()
                self.delivering.remove(session.id)
                self.pump(session)
            }
        }
    }

    private func record(
        _ item: Item, ledgerSessionId: Int64, completion: @escaping (Int64?) -> Void
    ) {
        let composed: String
        switch item.input {
        case .message(let text):
            composed = text
        case .notes(let summary, let notes):
            composed = AgentReviewComposer.compose(
                overallComment: summary ?? "",
                notes: notes.map {
                    AgentReviewComposer.ReviewNote(
                        location: nil, lineContent: $0.quote, content: $0.note)
                })
        }
        ReviewStore.galaxyTimeline.store(
            StoredReview(
                sessionID: ledgerSessionId,
                eventType: "session.input:sent",
                source: "galaxy-app/driven",
                detail: item.input.detail(composed: composed, owner: item.owner)),
            completion)
    }
}
