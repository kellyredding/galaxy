import CryptoKit
import Foundation

/// One `galaxy session send`: the id the sender chose for it, what it carries,
/// and a fingerprint of that content, so a resend of the same input can be
/// told apart from a different input reusing the id.
struct DrivenSend: Equatable {
    let inputID: String
    let input: DrivenInput
    let contentHash: String

    enum Decision: Equatable {
        case accept
        /// Already accepted with the same content: answer it, do nothing.
        case duplicate
        /// Already accepted with different content: always a sender's bug.
        case conflict
    }

    private static let idCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")

    static func isValidID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { idCharacters.contains($0) }
    }

    /// The same rules as the CLI's `InputFile`, `id` included.
    static func parse(_ value: Any?) -> Result<DrivenSend, DrivenFailure> {
        guard var object = value as? [String: Any] else {
            return .failure(.init(message: "input must be an object"))
        }
        guard let rawID = object.removeValue(forKey: "id") else {
            return .failure(.init(message: "input.id: missing"))
        }
        guard let id = rawID as? String, isValidID(id) else {
            return .failure(
                .init(message: "input.id must be 1-128 characters of A-Z a-z 0-9 . _ : -"))
        }
        return DrivenInput.parse(object).map {
            DrivenSend(inputID: id, input: $0, contentHash: contentHash(of: object))
        }
    }

    /// SHA-256 of the content with sorted keys, so the same content hashes the
    /// same however its keys were ordered. Compared only with hashes Galaxy
    /// computed itself.
    static func contentHash(of content: [String: Any]) -> String {
        let data =
            (try? JSONSerialization.data(
                withJSONObject: content, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What to do with this send, given the ids already accepted for the
    /// session and their content hashes.
    func decision(given accepted: [String: String]) -> Decision {
        guard let hash = accepted[inputID] else { return .accept }
        return hash == contentHash ? .duplicate : .conflict
    }

    /// What `session.input:sent` keeps: the input's own detail plus the id and
    /// hash a later resend is checked against.
    func detail(composed: String, owner: String) -> [String: Any] {
        var detail = input.detail(composed: composed, owner: owner)
        detail["input_id"] = inputID
        detail["content_hash"] = contentHash
        return detail
    }

    /// The id and hash a recorded `session.input:sent` detail carries, or nil
    /// for one recorded without them.
    static func accepted(fromRecordedDetail json: String?) -> (id: String, hash: String)? {
        guard let data = json?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["input_id"] as? String,
            let hash = object["content_hash"] as? String
        else { return nil }
        return (id, hash)
    }
}

/// What a driver hands `galaxy session send`: plain text, or notes answering
/// quoted text. The CLI validates the file strictly; this re-checks the shape,
/// because the socket accepts a request from anything that can open it.
enum DrivenInput: Equatable {
    struct Note: Equatable {
        let quote: String
        let note: String
    }

    case message(String)
    case notes(summary: String?, notes: [Note])

    /// The same rules as the CLI's `InputFile`, for the content once
    /// `DrivenSend` has taken the id out: unknown keys and blank strings are
    /// refused, so a request that skipped the CLI cannot get something past it.
    static func parse(_ value: Any?) -> Result<DrivenInput, DrivenFailure> {
        guard let object = value as? [String: Any] else {
            return .failure(.init(message: "input must be an object"))
        }
        if let unknown = Set(object.keys).subtracting(["message", "summary", "notes"]).sorted().first {
            return .failure(.init(message: "input.\(unknown): unknown key"))
        }
        if let message = object["message"] {
            guard object["notes"] == nil, object["summary"] == nil else {
                return .failure(.init(message: "input takes message or notes, not both"))
            }
            guard let text = nonBlank(message) else {
                return .failure(.init(message: "input.message must be a non-empty string"))
            }
            return .success(.message(text))
        }
        guard let rawNotes = object["notes"] as? [Any], !rawNotes.isEmpty else {
            return .failure(.init(message: "input needs a message or a non-empty notes array"))
        }
        var notes: [Note] = []
        for (index, raw) in rawNotes.enumerated() {
            guard let entry = raw as? [String: Any] else {
                return .failure(.init(message: "input.notes[\(index)] must be an object"))
            }
            if let unknown = Set(entry.keys).subtracting(["quote", "note"]).sorted().first {
                return .failure(.init(message: "input.notes[\(index)].\(unknown): unknown key"))
            }
            guard let quote = nonBlank(entry["quote"]), let note = nonBlank(entry["note"]) else {
                return .failure(
                    .init(message: "input.notes[\(index)] needs a non-empty quote and note"))
            }
            notes.append(Note(quote: quote, note: note))
        }
        let summary: String?
        if let raw = object["summary"] {
            guard let text = nonBlank(raw) else {
                return .failure(.init(message: "input.summary must be a non-empty string"))
            }
            summary = text
        } else {
            summary = nil
        }
        return .success(.notes(summary: summary, notes: notes))
    }

    /// The string itself, untrimmed, when it has any non-whitespace in it.
    private static func nonBlank(_ value: Any?) -> String? {
        guard let text = value as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    var noteCount: Int? {
        if case .notes(_, let notes) = self { return notes.count }
        return nil
    }

    /// What `session.input:sent` keeps: the composed text `galaxy-timeline
    /// message` prints, and the parts it was composed from.
    func detail(composed: String, owner: String) -> [String: Any] {
        var detail: [String: Any] = ["message": composed, "owner": owner]
        if case .notes(let summary, let notes) = self {
            detail["note_count"] = notes.count
            detail["notes"] = notes.map { ["quote": $0.quote, "note": $0.note] }
            if let summary { detail["summary"] = summary }
        }
        return detail
    }

    /// The short prompt the session receives in place of the text itself,
    /// which Claude Code can silently cut from the middle of long input.
    func pointer(owner: String, readCommand: String) -> String {
        switch noteCount {
        case nil:
            return "\(owner) sent you a message. Read it with `\(readCommand)`."
        case 1:
            return "\(owner) sent you 1 note. Read it with `\(readCommand)`, "
                + "then quote the note before you respond to it."
        case let count?:
            return "\(owner) sent you \(count) notes. Read them with `\(readCommand)`, "
                + "then quote each note before you respond to it."
        }
    }
}
