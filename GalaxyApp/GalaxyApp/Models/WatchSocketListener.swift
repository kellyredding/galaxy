import Foundation
import Network

/// Streams a session's events to whoever subscribes, on galaxy-watch.sock.
///
/// A separate socket from galaxy.sock on purpose: that one carries every
/// hook's event, and nothing a subscriber does (reconnecting in a loop,
/// reading slowly, not reading at all) may compete with it. Each subscriber
/// sends one subscribe line and is write-only after that; one that falls too
/// far behind is disconnected rather than buffered without limit, which loses
/// it nothing, since it fills the gap from the timeline when it reconnects.
///
/// All subscriber state lives on `queue`. `publish` is called from the main
/// queue and hops there.
final class WatchSocketListener {
    static let defaultSocketPath: String = {
        if let override = ProcessInfo.processInfo.environment["GALAXY_WATCH_SOCKET_PATH"] {
            return override
        }
        return NSHomeDirectory() + "/.claude/galaxy/galaxy-watch.sock"
    }()

    private final class Subscriber {
        let connection: NWConnection
        var handshake = Data()
        /// Set once subscribed: the id as the subscriber wrote it, echoed in
        /// every line, and the session it names.
        var requestedID: String?
        var sessionID: UUID?
        var backpressure = WatchBackpressure()

        init(connection: NWConnection) { self.connection = connection }
    }

    private let socketPath: String
    private var lockFilePath: String { socketPath + ".lock" }
    private var lockFileDescriptor: Int32 = -1
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kellyredding.galaxy.watch-listener")
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]

    /// Whether a subscribe request names a session this app has open. Asked
    /// on the main queue.
    var isKnownSession: ((UUID) -> Bool)?

    init(socketPath: String = WatchSocketListener.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard acquireLock() else {
            GalaxyLog.socket("watch: another instance owns \(socketPath)")
            return false
        }
        try? FileManager.default.removeItem(atPath: socketPath)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        do {
            listener = try NWListener(using: params)
        } catch {
            GalaxyLog.socket("watch: could not create listener: \(error.localizedDescription)")
            releaseLock()
            return false
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Owner-only, like the timeline it signals about.
                chmod(self.socketPath, 0o600)
            case .failed(let error):
                GalaxyLog.socket("watch: listener failed: \(error.localizedDescription)")
                self.restartAfterFailure()
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener?.start(queue: queue)
        GalaxyLog.socket("watch: listening on \(socketPath)")
        return true
    }

    func stop() {
        queue.sync {
            for subscriber in subscribers.values { subscriber.connection.cancel() }
            subscribers.removeAll()
        }
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        releaseLock()
    }

    // MARK: - Publishing

    /// Hands one event to the subscribers of the session it belongs to.
    func publish(event: String, ref: String?, ts: Int64, sessionID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            for subscriber in self.subscribers.values where subscriber.sessionID == sessionID {
                guard let requestedID = subscriber.requestedID else { continue }
                self.send(
                    WatchLine.encode(event: event, ref: ref, ts: ts, sessionID: requestedID),
                    to: subscriber)
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard subscribers.count < WatchBackpressure.maxSubscribers else {
            GalaxyLog.socket("watch: refusing a subscriber, \(subscribers.count) already connected")
            connection.start(queue: queue)
            connection.send(
                content: framed(WatchLine.error("too many subscribers")),
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let subscriber = Subscriber(connection: connection)
        subscribers[ObjectIdentifier(connection)] = subscriber

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .cancelled, .failed:
                self?.subscribers.removeValue(forKey: ObjectIdentifier(connection))
                if case .failed = state { connection.cancel() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: subscriber)
    }

    /// Reads the subscribe line, then keeps reading only to notice the
    /// subscriber hanging up; anything else it sends is ignored.
    private func receive(on subscriber: Subscriber) {
        subscriber.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self, weak subscriber] data, _, isComplete, error in
            guard let self, let subscriber else { return }
            if let data, !data.isEmpty, subscriber.requestedID == nil {
                self.readHandshake(data, from: subscriber)
            }
            if isComplete || error != nil {
                subscriber.connection.cancel()
            } else {
                self.receive(on: subscriber)
            }
        }
    }

    private func readHandshake(_ data: Data, from subscriber: Subscriber) {
        subscriber.handshake.append(data)
        guard let newline = subscriber.handshake.firstIndex(of: 0x0A) else {
            if subscriber.handshake.count > WatchSubscribeRequest.maxBytes {
                refuse(subscriber, "subscribe line too long")
            }
            return
        }
        let line = subscriber.handshake[..<newline]
        guard let requestedID = WatchSubscribeRequest.sessionID(from: Data(line)),
            let sessionID = UUID(uuidString: requestedID)
        else {
            refuse(subscriber, #"expected {"v":1,"subscribe":"<session id>"}"#)
            return
        }
        subscriber.requestedID = requestedID

        DispatchQueue.main.async { [weak self, weak subscriber] in
            let known = self?.isKnownSession?(sessionID) ?? false
            self?.queue.async {
                guard let self, let subscriber else { return }
                guard known else {
                    self.refuse(subscriber, "no open session \(requestedID)")
                    return
                }
                subscriber.sessionID = sessionID
                self.send(WatchLine.subscribed(requestedID), to: subscriber)
            }
        }
    }

    private func refuse(_ subscriber: Subscriber, _ message: String) {
        subscriber.requestedID = subscriber.requestedID ?? ""
        let connection = subscriber.connection
        connection.send(
            content: framed(WatchLine.error(message)),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send(_ line: Data, to subscriber: Subscriber) {
        guard subscriber.backpressure.sent() else {
            GalaxyLog.socket(
                "watch: dropping a subscriber to \(subscriber.requestedID ?? "?"),"
                    + " \(WatchBackpressure.capacity) lines behind")
            subscriber.connection.cancel()
            return
        }
        subscriber.connection.send(
            content: framed(line),
            completion: .contentProcessed { [weak self, weak subscriber] _ in
                self?.queue.async { subscriber?.backpressure.delivered() }
            })
    }

    private func framed(_ line: Data) -> Data {
        var data = line
        data.append(0x0A)
        return data
    }

    // MARK: - Lock file

    private func acquireLock() -> Bool {
        let parent = (lockFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        lockFileDescriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o600)
        guard lockFileDescriptor >= 0 else { return false }
        guard flock(lockFileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFileDescriptor)
            lockFileDescriptor = -1
            return false
        }
        return true
    }

    private func releaseLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
        try? FileManager.default.removeItem(atPath: lockFilePath)
    }

    private func restartAfterFailure() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            try? FileManager.default.removeItem(atPath: self.socketPath)
            self.releaseLock()
            self.start()
        }
    }
}
