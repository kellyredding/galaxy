import Foundation
import Security

/// What makes a session drivable by a program outside Galaxy.
///
/// Set once, when `galaxy session new` creates the session, and never removed:
/// a session either was created to be driven or it was not. Only the owner's
/// token can lock or release it; the person at the keyboard can only force a
/// release, which is recorded as theirs.
struct DrivenState: Codable, Equatable {
    enum Releaser: String, Codable {
        case owner
        case user
    }

    let owner: String
    let token: String
    var locked: Bool
    var lastLockedAt: Date?
    var lastReleasedAt: Date?
    var lastReleasedBy: Releaser?

    /// A new owner's state: locked from the moment it exists.
    static func issue(owner: String, at now: Date = Date()) -> DrivenState {
        DrivenState(
            owner: owner,
            token: DrivenToken.generate(),
            locked: true,
            lastLockedAt: now,
            lastReleasedAt: nil,
            lastReleasedBy: nil
        )
    }

    func accepts(token candidate: String) -> Bool {
        DrivenToken.matches(candidate, token)
    }

    mutating func lock(at now: Date = Date()) {
        locked = true
        lastLockedAt = now
    }

    mutating func release(by releaser: Releaser, at now: Date = Date()) {
        locked = false
        lastReleasedAt = now
        lastReleasedBy = releaser
    }

    /// "Driven by Atlas lead · locked since 2:14 PM", or "… released by you at
    /// 3:02 PM": the lock icon's tooltip.
    func summary(time: (Date) -> String) -> String {
        let state: String
        if locked {
            state = lastLockedAt.map { "locked since \(time($0))" } ?? "locked"
        } else {
            let by = lastReleasedBy == .user ? " by you" : ""
            state = lastReleasedAt.map { "released\(by) at \(time($0))" } ?? "released\(by)"
        }
        return "Driven by \(owner) · \(state)"
    }
}

enum DrivenToken {
    /// 32 random bytes, hex-encoded.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant time in the length of the expected token, so a caller probing
    /// tokens learns nothing from how quickly a wrong one is refused.
    static func matches(_ candidate: String, _ expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<b.count {
            let left = index < a.count ? a[index] : 0
            difference |= left ^ b[index]
        }
        return difference == 0
    }
}
