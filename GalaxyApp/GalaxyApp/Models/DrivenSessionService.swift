import Foundation

/// What a driven session's owner can do to it, plus the person's force release.
///
/// Never shows UI: every outcome is a reply, because the caller is a program
/// with nobody at Galaxy's window to answer a dialog. Every operation that
/// writes to a session requires the owner's token, and all but `lock` and
/// `release` also require the lock to be held, so an owner can never act on a
/// session the person has taken over.
@MainActor
final class DrivenSessionService {
    static let shared = DrivenSessionService()

    private var manager: SessionManager { SessionManager.shared }

    // MARK: - Creating

    func create(
        directory: String,
        persona: String?,
        name: String?,
        owner: String
    ) -> DrivenReply {
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else { return .failure(.init(message: "an owner is required")) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .failure(.init(message: "no such directory: \(directory)"))
        }

        if let persona {
            guard manager.claudePersonaPath != nil else {
                return .failure(.init(message: "claude-persona is not installed"))
            }
            let toml = NSHomeDirectory() + "/.claude-persona/personas/\(persona).toml"
            guard FileManager.default.fileExists(atPath: toml) else {
                return .failure(.init(message: "no such persona: \(persona)"))
            }
        }

        let driven = DrivenState.issue(owner: owner)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = manager.createSession(
            workingDirectory: directory,
            personaName: persona,
            givenName: (trimmedName?.isEmpty ?? true) ? nil : trimmedName,
            isVibe: true,
            driven: driven,
            activate: false
        )
        GalaxyLog.events("driven session \(session.sessionRef) created for \(owner)")
        return .success([
            "id": session.id.uuidString,
            "token": driven.token,
            "name": session.sidebarTitle,
            "owner": owner,
        ])
    }

    // MARK: - The lock

    func lock(id: String, token: String) -> DrivenReply {
        authorize(id: id, token: token, requireLock: false).flatMap { session, driven in
            guard !driven.locked else {
                return .failure(.init(message: "session is already locked"))
            }
            session.driven?.lock()
            record("lock:acquired", on: session, detail: ["owner": driven.owner])
            return .success(["id": session.id.uuidString, "locked": true])
        }
    }

    func release(id: String, token: String) -> DrivenReply {
        authorize(id: id, token: token, requireLock: true).flatMap { session, driven in
            session.driven?.release(by: .owner)
            record(
                "lock:released", on: session,
                detail: ["owner": driven.owner, "released_by": DrivenState.Releaser.owner.rawValue])
            return .success(["id": session.id.uuidString, "locked": false])
        }
    }

    /// The person's backstop, from the Ledger tab. Needs no token: it exists
    /// for the day the owner cannot be asked.
    func forceRelease(sessionID: UUID) -> DrivenReply {
        guard let session = manager.sessions.first(where: { $0.id == sessionID }),
            let driven = session.driven
        else {
            return .failure(.init(message: "session is not drivable"))
        }
        guard driven.locked else { return .failure(.init(message: "session is not locked")) }
        session.driven?.release(by: .user)
        record(
            "lock:revoked", on: session,
            detail: ["owner": driven.owner, "released_by": DrivenState.Releaser.user.rawValue])
        GalaxyLog.events("driven session \(session.sessionRef) force-released by the user")
        return .success(["id": session.id.uuidString, "locked": false])
    }

    // MARK: - Driving

    /// Input ids each session has accepted, with their content hashes, so a
    /// resend is recognised. Learned from the session's recorded inputs the
    /// first time it is sent to after launch, and kept current from there.
    private var acceptedInputs: [UUID: [String: String]] = [:]
    private var learnedInputs: Set<UUID> = []
    private var learningInputs: [UUID: Task<Void, Never>] = [:]

    /// Answers as soon as the input is accepted, not once it is recorded:
    /// recording and delivery follow, one at a time per session, and their
    /// outcome reaches the session's watchers as `session.input:sent` or
    /// `session.input:failed`.
    func send(id: String, token: String, input: Any?) async -> DrivenReply {
        let first = authorize(id: id, token: token, requireLock: true)
        guard case .success(let (session, _)) = first else { return first.map { _ in [:] } }
        let send: DrivenSend
        switch DrivenSend.parse(input) {
        case .success(let value): send = value
        case .failure(let failure): return .failure(failure)
        }

        await learnAcceptedInputs(of: session)

        // Checked again: the lock or the session may have changed while the
        // recorded inputs were read.
        let authorized = authorize(id: id, token: token, requireLock: true)
        guard case .success(let (current, driven)) = authorized, current === session else {
            return authorized.map { _ in [:] }
        }

        let reply: [String: Any] = ["id": session.id.uuidString, "input_id": send.inputID]
        switch send.decision(given: acceptedInputs[session.id] ?? [:]) {
        case .duplicate:
            return .success(reply.merging(["duplicate": true]) { $1 })
        case .conflict:
            return .failure(
                .init(message: "input id \(send.inputID) was already used for different content"))
        case .accept:
            break
        }

        let sessionID = session.id
        acceptedInputs[sessionID, default: [:]][send.inputID] = send.contentHash
        DrivenInputDelivery.shared.deliver(send, to: session, owner: driven.owner) { [weak self] eventID in
            guard eventID == nil else { return }
            self?.acceptedInputs[sessionID]?[send.inputID] = nil
            DrivenWatch.publish(
                "session.input:failed", sessionID: sessionID, detail: ["input_id": send.inputID])
        }
        return .success(reply.merging(["duplicate": false]) { $1 })
    }

    /// Reads the ids a session already accepted from its timeline, once per
    /// launch. A session with no ledger session yet has recorded nothing, so
    /// there is nothing to read until it has one; a failed read is tried again
    /// on the next send.
    private func learnAcceptedInputs(of session: Session) async {
        let sessionID = session.id
        guard !learnedInputs.contains(sessionID), let ledgerSessionId = session.ledgerSessionId
        else { return }
        if let learning = learningInputs[sessionID] {
            await learning.value
            return
        }
        let learning = Task { @MainActor in
            defer { self.learningInputs[sessionID] = nil }
            guard
                let events = try? await TimelineQueryService.shared.fetchDrivenInputs(
                    ledgerSessionId: ledgerSessionId)
            else {
                GalaxyLog.events("could not read the recorded inputs of driven session \(sessionID)")
                return
            }
            for event in events {
                guard let recorded = DrivenSend.accepted(fromRecordedDetail: event.detailData)
                else { continue }
                if self.acceptedInputs[sessionID]?[recorded.id] == nil {
                    self.acceptedInputs[sessionID, default: [:]][recorded.id] = recorded.hash
                }
            }
            self.learnedInputs.insert(sessionID)
        }
        learningInputs[sessionID] = learning
        await learning.value
    }

    /// The same reset the menu's Clear session issues, queued the way
    /// auto-clear queues it so it cannot overtake a message sent just before.
    /// The post-reset handoff follows on its own.
    func clear(id: String, token: String) -> DrivenReply {
        authorize(id: id, token: token, requireLock: true).flatMap { session, _ in
            guard session.isRunning, !session.hasExited else {
                return .failure(.init(message: "session is not running"))
            }
            session.enqueueMessage(
                "/clear", sourceLabel: "Driver clear", origin: .driver, delivery: .standalone)
            return .success(["id": session.id.uuidString])
        }
    }

    /// Answers once decided; see `SessionManager.resumeDriven`.
    func resume(id: String, token: String, stopHolder: Bool) async -> DrivenReply {
        let authorized = authorize(id: id, token: token, requireLock: true)
        guard case .success(let (session, _)) = authorized else {
            return authorized.map { _ in [:] }
        }
        return await manager.resumeDriven(session, stopHolder: stopHolder)
    }

    func stop(id: String, token: String) -> DrivenReply {
        authorize(id: id, token: token, requireLock: true).flatMap { session, _ in
            guard session.isRunning, !session.hasExited else {
                return .failure(.init(message: "session is not running"))
            }
            manager.stopSession(sessionId: session.id, initiatedBy: "driver")
            return .success(["id": session.id.uuidString])
        }
    }

    // MARK: - Reading

    func status(id: String) -> DrivenReply {
        guard let session = openSession(id) else {
            return .failure(.init(message: "no such session: \(id)"))
        }
        guard session.isDriven else { return .failure(.init(message: "session is not drivable")) }
        return .success(["session": DrivenSessionReport.live(session)])
    }

    func list(owner: String?, includeClosed: Bool) -> DrivenReply {
        var reports = manager.sessions
            .filter { session in
                guard let driven = session.driven else { return false }
                return owner.map { $0 == driven.owner } ?? true
            }
            .map(DrivenSessionReport.live)

        if includeClosed {
            reports += manager.closedSessions
                .filter { closed in
                    guard let driven = closed.session.driven else { return false }
                    return owner.map { $0 == driven.owner } ?? true
                }
                .map { DrivenSessionReport.closed($0.session) }
        }
        return .success(["sessions": reports])
    }

    // MARK: - Requests

    /// One `galaxy session` request, answered in the shape the CLI reads.
    func answer(event: String, detail: [String: Any]) async -> DrivenReply {
        let id = detail["id"] as? String ?? ""
        let token = detail["token"] as? String ?? ""
        switch event {
        case "session.create":
            guard let directory = detail["directory"] as? String,
                let owner = detail["owner"] as? String
            else {
                return .failure(.init(message: "create needs a directory and an owner"))
            }
            return create(
                directory: directory,
                persona: detail["persona"] as? String,
                name: detail["name"] as? String,
                owner: owner)
        case "session.lock": return lock(id: id, token: token)
        case "session.release": return release(id: id, token: token)
        case "session.send": return await send(id: id, token: token, input: detail["input"])
        case "session.clear": return clear(id: id, token: token)
        case "session.resume":
            return await resume(
                id: id, token: token, stopHolder: detail["stop_holder"] as? Bool ?? false)
        case "session.stop": return stop(id: id, token: token)
        case "session.status": return status(id: id)
        case "session.list":
            return list(
                owner: detail["owner"] as? String,
                includeClosed: detail["include_closed"] as? Bool ?? false)
        default:
            return .failure(.init(message: "unknown request: \(event)"))
        }
    }

    // MARK: - Private

    private func openSession(_ id: String) -> Session? {
        manager.sessions.first {
            $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame
        }
    }

    private func authorize(
        id: String, token: String, requireLock: Bool
    ) -> Result<(Session, DrivenState), DrivenFailure> {
        guard let session = openSession(id) else {
            return .failure(.init(message: "no such session: \(id)"))
        }
        guard let driven = session.driven else {
            return .failure(.init(message: "session is not drivable"))
        }
        guard driven.accepts(token: token) else {
            return .failure(.init(message: "token does not match"))
        }
        if requireLock, !driven.locked {
            return .failure(.init(message: "session is not locked"))
        }
        return .success((session, driven))
    }

    /// Held until the session's first ledger event when there is no timeline
    /// to record into yet, so a lock change in that window still reaches the
    /// session's watchers. The lock taken at creation is not recorded.
    private func record(_ eventType: String, on session: Session, detail: [String: Any]) {
        session.whenLedgerSessionKnown { ledgerSessionId in
            TimelineService.record(
                ledgerSessionId: ledgerSessionId,
                eventType: eventType,
                source: "galaxy-app/driven",
                detailData: detail
            )
        }
    }
}

/// A driven session as `status` and `list` report it.
enum DrivenSessionReport {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func live(_ session: Session) -> [String: Any] {
        var report = common(
            id: session.id,
            name: session.sidebarTitle,
            driven: session.driven,
            directory: session.workingDirectory,
            persona: session.personaName,
            ledgerSessionId: session.ledgerSessionId,
            claudeSessionId: session.claudeSessionId,
            contextPercentage: session.ledgerContextPercentage
        )
        report["running"] = session.isRunning && !session.hasExited
        report["in_turn"] = session.isInTurn
        report["running_agents"] = session.runningAgentCount
        report["inbox_depth"] = session.inbox.entries.count
        report["closed"] = false
        return report
    }

    static func closed(_ state: PersistedSession) -> [String: Any] {
        let name = (state.givenName?.isEmpty == false ? state.givenName : nil)
            ?? state.ledgerSuggestedName ?? state.sessionRef
        var report = common(
            id: state.id,
            name: name,
            driven: state.driven,
            directory: state.workingDirectory,
            persona: state.personaName,
            ledgerSessionId: state.ledgerSessionId,
            claudeSessionId: state.claudeSessionId,
            contextPercentage: state.ledgerContextPercentage
        )
        report["running"] = false
        report["in_turn"] = false
        report["running_agents"] = 0
        report["inbox_depth"] = state.inboxDepth ?? 0
        report["closed"] = true
        return report
    }

    private static func common(
        id: UUID,
        name: String,
        driven: DrivenState?,
        directory: String,
        persona: String?,
        ledgerSessionId: Int64?,
        claudeSessionId: String,
        contextPercentage: Double?
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "owner": driven?.owner ?? NSNull(),
            "locked": driven?.locked ?? false,
            "last_locked_at": timestamp(driven?.lastLockedAt),
            "last_released_at": timestamp(driven?.lastReleasedAt),
            "last_released_by": driven?.lastReleasedBy?.rawValue ?? NSNull(),
            "directory": directory,
            "persona": persona ?? NSNull(),
            "ledger_session_id": ledgerSessionId.map { NSNumber(value: $0) } ?? NSNull(),
            "claude_session_id": claudeSessionId,
            "context_percentage": contextPercentage ?? NSNull(),
        ]
    }

    private static func timestamp(_ date: Date?) -> Any {
        date.map { iso8601.string(from: $0) } ?? NSNull()
    }
}
