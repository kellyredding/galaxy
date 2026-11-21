import Foundation

/// A refused driven-session operation, worded for the program that asked.
struct DrivenFailure: Error, Equatable {
    let message: String
    /// Set when a resume is refused because another process holds the
    /// conversation, so the driver can decide whether to stop it.
    var holderPid: Int32?

    init(message: String, holderPid: Int32? = nil) {
        self.message = message
        self.holderPid = holderPid
    }
}

typealias DrivenReply = Result<[String: Any], DrivenFailure>

/// The one-line JSON a `galaxy session` request is answered with.
enum DrivenReplyCoding {
    /// The requests `galaxy session` sends. Named exactly, because other
    /// `session.*` envelopes (`session.metrics`, `session.idle`) are
    /// notifications that expect no reply.
    static let requests: Set<String> = [
        "session.create", "session.lock", "session.release", "session.send",
        "session.clear", "session.resume", "session.stop", "session.status",
        "session.list",
    ]

    static func encode(_ reply: DrivenReply) -> Data {
        var object: [String: Any]
        switch reply {
        case .success(let fields):
            object = fields
            object["ok"] = true
        case .failure(let failure):
            object = ["ok": false, "error": failure.message]
            if let pid = failure.holderPid { object["holder_pid"] = Int(pid) }
        }
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.withoutEscapingSlashes])
        else {
            return Data(#"{"ok":false,"error":"Galaxy could not encode its reply"}"#.utf8)
        }
        return data
    }
}
