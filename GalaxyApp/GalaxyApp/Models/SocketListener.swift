import Foundation
import Network

/// Listens for event envelopes on a Unix domain socket using Network.framework.
///
/// Manages the socket lifecycle including stale socket cleanup via a companion
/// lock file. Events are decoded into `EventEnvelope` structs and forwarded
/// to the `onEvent` callback.
///
/// The listener buffers events during startup (before the event system is in
/// "live" mode). Callers should set `onEvent` before calling `start()`.
final class SocketListener {
    /// Default socket path: ~/.claude/galaxy/galaxy.sock
    static let defaultSocketPath: String = {
        if let override = ProcessInfo.processInfo.environment["GALAXY_SOCKET_PATH"] {
            return override
        }
        return NSHomeDirectory() + "/.claude/galaxy/galaxy.sock"
    }()

    /// Lock file path (companion to socket file)
    private var lockFilePath: String { socketPath + ".lock" }

    private let socketPath: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kellyredding.galaxy.socket-listener")

    /// File descriptor for the lock file — kept open for process lifetime to hold flock
    private var lockFileDescriptor: Int32 = -1

    /// Callback invoked on the main queue for each decoded event envelope
    var onEvent: ((EventEnvelope) -> Void)?

    /// Track active connections for cleanup
    private var activeConnections: [NWConnection] = []

    /// Per-connection accumulator for partial JSON lines. A
    /// single envelope can span multiple `connection.receive`
    /// callbacks when its serialized size exceeds the kernel's
    /// per-callback chunk boundary — commonly observed with
    /// `timeline.turn:completed` envelopes that carry the full
    /// `user_message` and `assistant_response` in `detail_data`
    /// (~25 KB+ for orchestrator/task-notification turns).
    /// Bytes accumulate here until a newline arrives, at which
    /// point complete lines are extracted and parsed. Keyed by
    /// `ObjectIdentifier(connection)`. All mutations happen on
    /// `queue` (the listener's serial DispatchQueue), so no
    /// additional synchronization is needed.
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]

    /// Per-connection receive-callback counter. Reset to 0
    /// after each complete line is parsed; > 1 at parse time
    /// means the envelope was reassembled from multiple chunks
    /// (logged as `Reassembled envelope ...` to confirm the
    /// framing fix is doing its job).
    private var connectionChunks: [ObjectIdentifier: Int] = [:]

    /// Safety cap on per-connection buffer growth. The Crystal
    /// publisher always terminates with `\n`, so a buffer
    /// larger than this without a newline indicates a
    /// misbehaving sender (or memory-pressure attack); we drop
    /// the buffer and log rather than grow unbounded.
    private static let maxBufferBytes: Int = 10 * 1024 * 1024

    init(socketPath: String = SocketListener.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start listening on the Unix domain socket.
    ///
    /// 1. Acquires an exclusive flock on the companion .lock file
    /// 2. Removes any stale socket file
    /// 3. Binds NWListener to the socket path
    ///
    /// Returns false if another Galaxy.app instance owns the lock.
    @discardableResult
    func start() -> Bool {
        GalaxyLog.socket("Starting listener on \(socketPath)")

        // Step 1: Acquire lock
        guard acquireLock() else {
            GalaxyLog.socket("Lock acquisition failed — another instance owns the socket")
            return false
        }

        // Step 2: Remove stale socket file
        removeStaleSocket()

        // Step 3: Create and start NWListener
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = endpoint

        do {
            listener = try NWListener(using: params)
        } catch {
            GalaxyLog.socket("Failed to create NWListener: \(error.localizedDescription)")
            return false
        }

        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                GalaxyLog.socket("Listener entered failed state: \(error.localizedDescription)")
                self?.restartAfterFailure()
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        GalaxyLog.socket("Listener started")
        return true
    }

    /// Stop the listener and clean up resources.
    func stop() {
        GalaxyLog.socket("Listener stopping")
        // Cancel all active connections
        for connection in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()

        listener?.cancel()
        listener = nil

        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        // Release lock
        releaseLock()
    }

    // MARK: - Lock File

    /// Acquire an exclusive flock on the companion lock file.
    /// Returns true if the lock was acquired, false if another instance holds it.
    private func acquireLock() -> Bool {
        let fm = FileManager.default

        // Ensure parent directory exists
        let parentDir = (lockFilePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // Open (or create) the lock file
        lockFileDescriptor = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard lockFileDescriptor >= 0 else {
            return false
        }

        // Try non-blocking exclusive lock
        let result = flock(lockFileDescriptor, LOCK_EX | LOCK_NB)
        if result != 0 {
            // Lock held by another process
            close(lockFileDescriptor)
            lockFileDescriptor = -1
            return false
        }

        return true
    }

    /// Release the flock and close the lock file descriptor.
    private func releaseLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
        try? FileManager.default.removeItem(atPath: lockFilePath)
    }

    /// Remove a stale socket file left by a previous instance.
    private func removeStaleSocket() {
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        let key = ObjectIdentifier(connection)
        connectionBuffers[key] = Data()
        connectionChunks[key] = 0

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state {
                if let conn = connection {
                    self?.removeConnection(conn)
                }
            } else if case .failed = state {
                if let conn = connection {
                    self?.removeConnection(conn)
                }
                connection?.cancel()
            }
        }

        connection.start(queue: queue)
        receiveData(on: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        activeConnections.removeAll { $0 === connection }
        let key = ObjectIdentifier(connection)
        // Surface unconsumed bytes at close. The publisher
        // always terminates with `\n`, so partial data here
        // means truncation (publisher crash mid-write, or
        // kernel buffer drop). Loud signal that something
        // upstream is misbehaving.
        if let buffer = connectionBuffers[key], !buffer.isEmpty {
            let preview = String(
                data: buffer.prefix(200),
                encoding: .utf8
            ) ?? "<binary>"
            GalaxyLog.socket(
                "Connection closed with \(buffer.count)B"
                + " unconsumed (no terminating newline)"
                + " — preview: \(preview)"
            )
        }
        connectionBuffers.removeValue(forKey: key)
        connectionChunks.removeValue(forKey: key)
    }

    /// Read data from a connection, accumulating until a complete newline-delimited
    /// JSON line is received. Crystal's publisher writes one JSON line + newline
    /// per connection, then closes.
    private func receiveData(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processReceivedData(data, on: connection)
            }

            if isComplete || error != nil {
                connection.cancel()
            } else {
                // More data may follow — keep reading
                self?.receiveData(on: connection)
            }
        }
    }

    /// Parse received data as newline-delimited JSON and decode
    /// event envelopes. Buffers per-connection because a single
    /// envelope can arrive across multiple `connection.receive`
    /// callbacks when its serialized size exceeds the kernel's
    /// per-callback chunk boundary. Bytes accumulate in the
    /// connection's slot in `connectionBuffers` until a newline
    /// terminator arrives; complete lines are then parsed. Any
    /// trailing partial line stays in the buffer for the next
    /// callback.
    private func processReceivedData(
        _ data: Data,
        on connection: NWConnection
    ) {
        let key = ObjectIdentifier(connection)
        var buffer = connectionBuffers[key] ?? Data()
        buffer.append(data)
        connectionChunks[key, default: 0] += 1

        // Sanity cap — drop runaway buffers rather than grow
        // unbounded. Publisher always terminates with `\n`, so
        // 10 MB without one means something upstream is broken.
        if buffer.count > Self.maxBufferBytes {
            GalaxyLog.socket(
                "Buffer for connection exceeded"
                + " \(Self.maxBufferBytes)B without newline"
                + " — dropping (\(buffer.count)B accumulated)"
            )
            connectionBuffers[key] = Data()
            connectionChunks[key] = 0
            return
        }

        let newline: UInt8 = 0x0A
        var cursor = buffer.startIndex

        while let nlIdx = buffer[cursor...]
            .firstIndex(of: newline)
        {
            let lineRange = cursor..<nlIdx
            cursor = buffer.index(after: nlIdx)

            // Trim leading/trailing whitespace as before; an
            // empty line (lone `\n` or whitespace-only) is
            // skipped without resetting the chunk count.
            let lineData = buffer[lineRange]
            let trimmed = String(
                data: lineData, encoding: .utf8
            )?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8)
            else { continue }

            let chunks = connectionChunks[key] ?? 1

            do {
                let envelope = try JSONDecoder().decode(
                    EventEnvelope.self,
                    from: jsonData
                )
                if chunks > 1 {
                    // Loud, positive signal that the
                    // per-connection buffering reassembled a
                    // fragmented envelope. Confirms the fix
                    // is doing its job; not a problem.
                    GalaxyLog.socket(
                        "Reassembled envelope"
                        + " event=\(envelope.event)"
                        + " ledger_session_id="
                        + "\(envelope.ledgerSessionId)"
                        + " bytes=\(jsonData.count)"
                        + " chunks=\(chunks)"
                    )
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(envelope)
                }
            } catch {
                GalaxyLog.socket(
                    "Failed to decode envelope"
                    + " (\(jsonData.count)B,"
                    + " chunks=\(chunks)):"
                    + " \(error.localizedDescription)"
                    + " — preview: "
                    + "\(String(trimmed.prefix(200)))"
                )
            }

            // Reset chunk count after every complete line so
            // a subsequent line on the same connection starts
            // fresh. (Publisher writes one envelope per
            // connection in practice, but be defensive.)
            connectionChunks[key] = 0
        }

        // Retain any trailing partial line for the next callback.
        if cursor < buffer.endIndex {
            connectionBuffers[key] = Data(buffer[cursor...])
        } else {
            connectionBuffers[key] = Data()
        }
    }

    // MARK: - Error Recovery

    private func restartAfterFailure() {
        GalaxyLog.socket("Attempting restart after failure")
        // Small delay before restart attempt
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.removeStaleSocket()
            self.start()
        }
    }
}
