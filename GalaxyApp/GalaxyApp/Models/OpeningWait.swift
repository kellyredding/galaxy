import Foundation

/// Whether a launch opens with a turn that must end before anything else is
/// typed in: a persona's opening message, or Galaxy's own `/galaxy:resume`.
///
/// MEASURED (Claude Code 2.1.330): `session:ready` arrived 214–237 ms before a
/// persona's opening turn began, every time, so readiness alone cannot tell a
/// quiet start from one about to open. Only the launch knows which it is.
struct OpeningWait: Equatable {
    enum Expectation: Equatable {
        /// The persona lookup has not answered yet.
        case unknown
        case expected
        case none
    }

    private(set) var expectation: Expectation
    private(set) var firstTurnEnded = false
    /// The timeline row of the turn end that finished the opening, when the
    /// launch had one and the end carried a row.
    private(set) var openingEventID: Int64?
    private(set) var releasedByHand = false

    /// Plain `claude`, a persona with no opening message, or a resume that
    /// sends nothing.
    static let quiet = OpeningWait(expectation: .none)
    /// A fresh persona launch whose opening is still being looked up.
    static let pendingLookup = OpeningWait(expectation: .unknown)

    var isAwaiting: Bool {
        switch expectation {
        case .unknown: return true
        case .expected: return !firstTurnEnded
        case .none: return false
        }
    }

    mutating func resolve(expectsOpening: Bool) {
        guard expectation == .unknown else { return }
        expectation = expectsOpening ? .expected : .none
        if !expectsOpening { openingEventID = nil }
    }

    /// A resume that sends `/galaxy:resume` opens with that turn.
    mutating func expectTurn() {
        expectation = .expected
        firstTurnEnded = false
        openingEventID = nil
    }

    /// Only the first turn to end after launch counts. If it ends before the
    /// lookup answers, the answer decides whether it was the opening.
    mutating func turnEnded(eventID: Int64?) {
        guard !firstTurnEnded else { return }
        firstTurnEnded = true
        openingEventID = expectation == .none ? nil : eventID
    }

    /// Mark Session Ready: a person decided the opening is not coming.
    mutating func release() {
        guard isAwaiting else { return }
        expectation = .none
        openingEventID = nil
        releasedByHand = true
    }

    /// From `claude-persona show <persona> --json`: whether a fresh launch
    /// submits an opening message, or nil when the reply can't be read.
    static func expectsOpening(personaJSON: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: personaJSON) as? [String: Any],
            object["name"] is String,
            object.keys.contains("initial_message")
        else { return nil }
        return object["initial_message"] is String
    }

    /// `session:input-ready`: recorded for driven sessions the first time
    /// after each launch that the session can take a prompt.
    static let inputReadyEventType = "session:input-ready"

    var inputReadyDetail: [String: Any] {
        var detail: [String: Any] = ["opening_event_id": openingEventID.map { $0 as Any } ?? NSNull()]
        if releasedByHand { detail["released_by_hand"] = true }
        return detail
    }
}
