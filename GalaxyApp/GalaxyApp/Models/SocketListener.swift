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
        // Step 1: Acquire lock
        guard acquireLock() else {
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
            return false
        }

        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.restartAfterFailure()
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        return true
    }

    /// Stop the listener and clean up resources.
    func stop() {
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
    }

    /// Read data from a connection, accumulating until a complete newline-delimited
    /// JSON line is received. Crystal's publisher writes one JSON line + newline
    /// per connection, then closes.
    private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processReceivedData(data)
            }

            if isComplete || error != nil {
                connection.cancel()
            } else {
                // More data may follow — keep reading
                self?.receiveData(on: connection)
            }
        }
    }

    /// Parse received data as newline-delimited JSON and decode event envelopes.
    private func processReceivedData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let jsonData = trimmed.data(using: .utf8) else { continue }

            do {
                let envelope = try JSONDecoder().decode(EventEnvelope.self, from: jsonData)
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(envelope)
                }
            } catch {
                // Tolerant reader: can't parse → skip
            }
        }
    }

    // MARK: - Error Recovery

    private func restartAfterFailure() {
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
