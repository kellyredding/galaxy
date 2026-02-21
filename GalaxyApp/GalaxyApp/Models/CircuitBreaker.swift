import Foundation

/// Circuit breaker to prevent runaway subprocess spawning when the CLI is broken.
///
/// States:
/// - **Closed** (normal) — calls proceed
/// - **Open** — 3 consecutive failures → stop calling for 10 seconds
/// - **Half-Open** — after timeout, try one call; success → Closed, failure → Open
final class CircuitBreaker {
    enum State: String {
        case closed
        case open
        case halfOpen
    }

    private(set) var state: State = .closed

    /// Number of consecutive failures before opening
    private let failureThreshold: Int

    /// Duration to stay open before trying half-open
    private let resetTimeout: TimeInterval

    /// Current consecutive failure count
    private var failureCount: Int = 0

    /// When the circuit opened (used to determine if resetTimeout has passed)
    private var openedAt: Date?

    init(failureThreshold: Int = 3, resetTimeout: TimeInterval = 10.0) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }

    /// Check if a call should be allowed through.
    /// Returns true if the circuit is closed or half-open (trial call).
    var shouldAllow: Bool {
        switch state {
        case .closed:
            return true
        case .open:
            // Check if reset timeout has passed → transition to half-open
            if let openedAt = openedAt, Date().timeIntervalSince(openedAt) >= resetTimeout {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            // Allow one trial call
            return true
        }
    }

    /// Record a successful call. Resets failure count and closes the circuit.
    func recordSuccess() {
        failureCount = 0
        openedAt = nil
        state = .closed
    }

    /// Record a failed call. Increments failure count and may open the circuit.
    func recordFailure() {
        failureCount += 1

        switch state {
        case .closed:
            if failureCount >= failureThreshold {
                state = .open
                openedAt = Date()
            }
        case .halfOpen:
            // Trial call failed → back to open
            state = .open
            openedAt = Date()
        case .open:
            // Already open, just update timestamp
            openedAt = Date()
        }
    }
}
