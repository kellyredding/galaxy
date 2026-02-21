import Foundation

/// Decoded event envelope from the Galaxy Ledger Unix domain socket.
///
/// Wire format is newline-delimited JSON:
/// ```json
/// {"v":1,"event":"session.metrics","ledger_session_id":42,"session_identifiers":["abc-123"],"ts":1708444800}
/// ```
///
/// Event name is a raw String (not an enum) for extensibility — unknown events
/// are silently skipped by the router. Unknown JSON keys are silently ignored
/// (Swift Codable default).
struct EventEnvelope: Codable {
    let v: Int
    let event: String
    let ledgerSessionId: Int64
    let sessionIdentifiers: [String]
    let ts: Int64
    let ref: String?

    enum CodingKeys: String, CodingKey {
        case v
        case event
        case ledgerSessionId = "ledger_session_id"
        case sessionIdentifiers = "session_identifiers"
        case ts
        case ref
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        event = try container.decode(String.self, forKey: .event)
        ledgerSessionId = try container.decode(Int64.self, forKey: .ledgerSessionId)
        sessionIdentifiers = try container.decode([String].self, forKey: .sessionIdentifiers)
        ts = try container.decode(Int64.self, forKey: .ts)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
    }
}
