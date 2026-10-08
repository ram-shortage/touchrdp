import Foundation

// MARK: - ReconnectDecider (LIFE-4)

/// Pure, headless-testable reconnect policy. Extracted from `SessionController` so the
/// budget/flap logic can be covered by ValidateCore without an RDP host.
///
/// The core rule (LIFE-4): a link that flaps *without ever reaching `.connected`* must
/// decrement its budget down to the cap and then STOP — it does not re-earn a fresh
/// budget on every network change. Budget is only re-earned when the session actually
/// reconnected since the last reset (`connectedSinceReset`).
public struct ReconnectDecider {

    public enum Decision: Equatable {
        case retryNow(newAttempt: Int)
        case stop
    }

    public init() {}

    /// - Parameters:
    ///   - attempt: the current `reconnectAttempt` count.
    ///   - max: `maxReconnectAttempts`.
    ///   - connectedSinceReset: the session reached `.connected` since the last budget reset,
    ///     so it has earned a fresh budget (start counting from 0 again).
    ///   - cause: the failure cause, or `nil` for a plain network disconnect (retryable).
    ///   - pendingCert: a certificate review is pending — never auto-retry (LIFE-5).
    public func decide(attempt: Int,
                       max: Int,
                       connectedSinceReset: Bool,
                       cause: RDPErrorCause?,
                       pendingCert: Bool) -> Decision {
        if pendingCert { return .stop }
        if let cause, !Self.isRetryable(cause) { return .stop }
        // Re-earn a fresh budget only when actually reconnected since the last reset.
        let base = connectedSinceReset ? 0 : attempt
        guard base < max else { return .stop }
        return .retryNow(newAttempt: base + 1)
    }

    // MARK: Proactive (network-return) budget — F-24

    public enum ProactiveDecision: Equatable {
        case retry
        case stop
    }

    /// F-24: the network-recovery path has its OWN single-attempt budget per drop
    /// episode, separate from the blind-retry budget above. A genuine network-return
    /// event may fire ONE proactive attempt even when the blind budget is exhausted —
    /// but never more than one per episode. The episode flag
    /// (`proactiveUsedThisEpisode`) is cleared only when a connection fully succeeds
    /// or the user manually reconnects.
    ///
    /// Same LIFE-3/LIFE-5 rules as the blind path: never for non-retryable causes,
    /// never while a cert review is pending, and never when the per-connection policy
    /// disables auto-reconnect (`policyMaxAttempts <= 0`). The ≥5 s floor and the
    /// no-new-prompt rule are enforced by the caller (`SessionController`).
    public func decideProactive(proactiveUsedThisEpisode: Bool,
                                policyMaxAttempts: Int,
                                cause: RDPErrorCause?,
                                pendingCert: Bool) -> ProactiveDecision {
        if pendingCert { return .stop }
        if let cause, !Self.isRetryable(cause) { return .stop }
        if policyMaxAttempts <= 0 { return .stop }        // auto-reconnect disabled
        return proactiveUsedThisEpisode ? .stop : .retry
    }

    /// Auth failures, cert rejections, explicit cancels, MFA prompts, and unreadable
    /// saved credentials all need user action — never auto-retry them.
    public static func isRetryable(_ cause: RDPErrorCause) -> Bool {
        switch cause {
        case .authenticationFailed, .certificateRejected, .cancelled, .mfaRequired,
             .credentialsIncomplete, .credentialsUnavailable,
             // The server ended the session on purpose. Retrying a take-over just kicks
             // the other client off — and if it auto-reconnects too, the two loop.
             .sessionTakenOver, .sessionEndedByServer:
            return false
        default:
            return true
        }
    }

    // MARK: Backoff curve (pure, F-20)

    /// Reconnect delay for attempt `a`: exponential backoff (2^(a-1)) with a floor of
    /// `max(5, minDelaySeconds)` and a ceiling of `max(16, floor)`. With the default
    /// 5 s floor that's the original 5,5,5,8,16 curve; a per-connection policy may
    /// RAISE the floor (up to 60 s), never lower it below 5 (LIFE-3).
    public static func backoffDelaySeconds(forAttempt a: Int,
                                           minDelaySeconds: Double = 5) -> Double {
        let floor = Swift.max(5.0, minDelaySeconds)
        let ceiling = Swift.max(16.0, floor)
        return Swift.min(Swift.max(pow(2.0, Double(Swift.max(1, a) - 1)), floor), ceiling)
    }
}

// MARK: - Credential auth directive (LIFE-3)

public extension CredentialPolicy {
    /// How to obtain the biometric `LAContext` for a credential retrieval, given *why* it's
    /// being requested. Returns:
    ///   - `reuseSeconds`: the OS-clamped Touch ID reuse window, or `nil` for a throwaway
    ///     context that always prompts and is never cached.
    ///   - `forceFreshPrompt`: mint (and cache) a NEW context even if a cached one is still
    ///     valid, so this retrieval prompts but *seeds* a reusable authentication for a
    ///     subsequent automatic reconnect.
    ///
    /// Policy (signed off, SECURITY.md): `biometricEveryConnect` prompts on **every
    /// user-initiated** connect (`forceFreshPrompt`), but a single **automatic** reconnect
    /// within the OS window reuses that authentication with **no new prompt**. The secret is
    /// never cached — only the authenticated `LAContext`, OS-clamped to ≤5 min. `biometricReuse`
    /// / `savedNoBiometric` reuse within their window for both user and automatic requests.
    func authDirective(for reason: CredentialRequestReason)
        -> (reuseSeconds: Int?, forceFreshPrompt: Bool) {
        // F-27: typing the secret into a live session is the one request that is NEVER
        // covered by a reuse window, whatever the connection's policy says. Every other
        // path hands the secret to an NLA handshake against a certificate we pinned;
        // this one puts it on screen at a target the client cannot verify, so it demands
        // a fresh biometric each time (forceFresh) and seeds nothing for later
        // (reuseSeconds nil => the vault neither reuses nor caches the context).
        if case .inSessionTyping = reason { return (nil, true) }

        switch self {
        case .biometricEveryConnect:
            switch reason {
            case .userInitiated:      return (KeychainCredentialVault.maxReuseSeconds, true)
            case .automaticReconnect: return (KeychainCredentialVault.maxReuseSeconds, false)
            case .inSessionTyping:    return (nil, true)   // unreachable; kept exhaustive
            }
        case .biometricReuse(let seconds):
            return (seconds, false)
        case .savedNoBiometric:
            return (KeychainCredentialVault.maxReuseSeconds, false)
        }
    }
}

// MARK: - Persistence errors (DATA-1)

/// Surfaced by the file-backed stores so the app layer can warn instead of silently
/// losing data or dropping a save.
public enum StoreError: LocalizedError, Equatable {
    /// The on-disk file could not be decoded; the recoverable bytes were copied to
    /// `backupURL` (nil if the copy itself failed) before resetting to empty.
    case loadCorrupt(backupURL: URL?)
    /// A save failed; the associated string is a diagnostic description.
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let detail):
            return "Could not save the connection changes. Check available disk space and access to the TouchRDP Application Support folder, then retry. \(detail)"
        case .loadCorrupt(let backupURL):
            if let backupURL {
                return "The saved data could not be read. A recovery copy is at \(backupURL.path)."
            }
            return "The saved data could not be read and a recovery copy could not be created."
        }
    }
}
