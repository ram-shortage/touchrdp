import Foundation

// MARK: - Honest connection states (PRD §8.7)

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating          // Touch ID / NLA credential exchange
    case negotiating
    case connected
    case reconnecting(attempt: Int)
    case disconnected(reason: String?)
    case failed(RDPError)

    public var isActive: Bool {
        switch self {
        case .connecting, .authenticating, .negotiating, .connected, .reconnecting: return true
        default: return false
        }
    }
}

// MARK: - Translated errors (PRD §8.8 — never show raw codes without a cause)

public enum RDPErrorCause: String, Sendable {
    case connectionFailed
    case authenticationFailed
    case certificateRejected
    case hostUnreachable
    case timeout
    case dnsFailure
    case protocolError
    case cancelled
    case mfaRequired
    case credentialsIncomplete    // username missing — edit profile before connecting
    case credentialsUnavailable   // saved password missing or unreadable — re-save needed
    case sessionTakenOver         // another client connected to the same Windows session
    case sessionEndedByServer     // remote logoff/disconnect, admin action, or idle timeout
    case unknown
}

public struct RDPError: Error, Equatable, Sendable {
    public let code: UInt32
    public let rawMessage: String
    public let cause: RDPErrorCause

    public init(code: UInt32, rawMessage: String, cause: RDPErrorCause) {
        self.code = code; self.rawMessage = rawMessage; self.cause = cause
    }

    /// FreeRDP's own sentence for this failure, ready to append to a generic message
    /// (empty when the bridge supplied none).
    private var rawDetail: String {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " (\(trimmed))"
    }

    /// Human-readable explanation for the UI.
    public var humanMessage: String {
        switch cause {
        case .authenticationFailed: return "Sign-in was rejected. Your saved password may have changed."
        case .certificateRejected:  return "The server's identity certificate was not trusted."
        case .hostUnreachable:      return "Couldn't reach the host. Check the address, port, or your VPN."
        case .dnsFailure:           return "Couldn't resolve the host name."
        case .timeout:              return "The connection timed out."
        // #32: these three are the causes that hide a specific FreeRDP reason behind a
        // generic sentence — surface FreeRDP's own text so the overlay says what actually
        // happened ("…at negotiating security settings", "…requires Network Level
        // Authentication…") instead of leaving the user to guess.
        case .connectionFailed:     return "The connection to the host failed." + rawDetail
        case .protocolError:        return "The server rejected the session setup." + rawDetail
        case .mfaRequired:          return "This account requires additional verification (MFA) to finish signing in."
        case .credentialsIncomplete:
            let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "A username and saved password are required before connecting."
                : trimmed
        // The engine/bridge supply the specific reason (empty item, missing item, stale
        // ACL…); only fall back to the generic sentence when they gave none.
        case .credentialsUnavailable:
            let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The saved password couldn't be unlocked — it may have been saved by an older build of TouchRDP. Re-save the password to continue."
                : trimmed
        case .sessionTakenOver:
            return "Another device or app connected to this Windows session, so this one was disconnected. Reconnecting here will disconnect the other one."
        case .sessionEndedByServer: return "The remote session was ended on the server." + rawDetail
        case .cancelled:            return "The connection was cancelled."
        case .unknown:              return "The connection could not be completed (code 0x\(String(code, radix: 16)))."
        }
    }

    /// A concrete next action the UI can offer (PRD §8.8).
    public var suggestedAction: String? {
        switch cause {
        case .authenticationFailed: return "Update saved password"
        case .credentialsIncomplete: return "Edit connection"
        case .credentialsUnavailable: return "Update saved password"
        case .certificateRejected:  return "Review certificate"
        case .hostUnreachable, .dnsFailure: return "Edit connection"
        case .timeout, .connectionFailed:   return "Retry"
        case .sessionTakenOver, .sessionEndedByServer: return "Reconnect"
        default: return nil
        }
    }

    /// The bridge's own "we rejected the server certificate" code (rdpbridge.h
    /// `RDPB_ERROR_CERT_REJECTED`). Deliberately outside every FreeRDP error class — see
    /// the #32 note below.
    public static let bridgeCertRejectedCode: UInt32 = 0x7F0C0001

    /// The bridge's "FreeRDP asked us for a password and we had none" code (rdpbridge.h
    /// `RDPB_ERROR_NO_CREDENTIALS`): the password reached NLA empty. Without it FreeRDP
    /// runs two doomed NTLM rounds and reports the aftermath as a transport failure.
    public static let bridgeNoCredentialsCode: UInt32 = 0x7F0C0002

    /// The bridge received a non-empty secret but could not preserve it intact through
    /// FreeRDP's settings boundary. This is local credential handling, not transport.
    public static let bridgeCredentialHandoffCode: UInt32 = 0x7F0C0003

    /// The bridge rejected a connection with no username before starting its worker.
    public static let bridgeIncompleteCredentialsCode: UInt32 = 0x7F0C0004

    /// Translate a FreeRDP error code + message into a cause.
    ///
    /// #32: the table is FreeRDP 3's `ERRCONNECT_*` class (`0x0002xxxx`, freerdp/error.h)
    /// verbatim. The previous table had several of these wrong — most damagingly it read
    /// `0x0002000C` as "certificate rejected", but that is FreeRDP's
    /// `SECURITY_NEGO_CONNECT_FAILED`, raised on its own when the server rejects every
    /// security protocol offered or the link drops mid-negotiation. Nothing to do with the
    /// certificate — yet the UI said "certificate not trusted", offered a review with no
    /// certificate to show, and "Review Certificate" simply re-ran the failing connect.
    /// (It also read `AUTHENTICATION_FAILED` as a DNS failure.) A rejected certificate is
    /// now ONLY the bridge's private code, which cannot collide with anything FreeRDP emits.
    public static func from(code: UInt32, rawMessage: String) -> RDPError {
        let cause: RDPErrorCause
        switch code {
        case bridgeCertRejectedCode: cause = .certificateRejected
        case bridgeNoCredentialsCode: cause = .credentialsUnavailable
        case bridgeCredentialHandoffCode: cause = .credentialsUnavailable
        case bridgeIncompleteCredentialsCode: cause = .credentialsIncomplete
        case 0x00000000:             cause = .cancelled
        // --- FreeRDP ERRCONNECT_* (0x0002 class) ---
        case 0x00020001:             cause = .connectionFailed     // PRE_CONNECT_FAILED (config)
        case 0x00020002:             cause = .connectionFailed     // CONNECT_UNDEFINED
        case 0x00020003:             cause = .protocolError        // POST_CONNECT_FAILED
        case 0x00020004, 0x00020005: cause = .dnsFailure           // DNS_ERROR / DNS_NAME_NOT_FOUND
        case 0x00020006:             cause = .connectionFailed     // CONNECT_FAILED (TCP)
        case 0x00020007:             cause = .protocolError        // MCS_CONNECT_INITIAL_ERROR
        case 0x00020008:             cause = .connectionFailed     // TLS_CONNECT_FAILED
        case 0x00020009:             cause = .authenticationFailed // AUTHENTICATION_FAILED
        case 0x0002000A:             cause = .authenticationFailed // INSUFFICIENT_PRIVILEGES
        case 0x0002000B:             cause = .cancelled            // CONNECT_CANCELLED
        case 0x0002000C:             cause = .protocolError        // SECURITY_NEGO_CONNECT_FAILED
        case 0x0002000D:             cause = .connectionFailed     // CONNECT_TRANSPORT_FAILED
        case 0x0002000E, 0x0002000F: cause = .authenticationFailed // PASSWORD_(CERTAINLY_)EXPIRED
        case 0x00020010:             cause = .authenticationFailed // CLIENT_REVOKED
        case 0x00020011:             cause = .connectionFailed     // KDC_UNREACHABLE
        case 0x00020012:             cause = .authenticationFailed // ACCOUNT_DISABLED
        case 0x00020013:             cause = .authenticationFailed // PASSWORD_MUST_CHANGE
        case 0x00020014, 0x00020015: cause = .authenticationFailed // LOGON_FAILURE / WRONG_PASSWORD
        case 0x00020016...0x0002001A: cause = .authenticationFailed // ACCESS_DENIED … LOGON_TYPE_NOT_GRANTED
        case 0x0002001B:             cause = .credentialsUnavailable // NO_OR_MISSING_CREDENTIALS
        case 0x0002001C:             cause = .timeout              // ACTIVATION_TIMEOUT
        case 0x0002001D:             cause = .connectionFailed     // TARGET_BOOTING
        case 0x0002001E:             cause = .protocolError        // HYBRID_REQUIRED_BY_SERVER (NLA off)
        // --- FreeRDP ERRINFO_* (0x0001 class): the server ended the session and said why.
        // Only the "someone meant to end it" reasons are mapped; the rest fall through.
        case 0x00010005:             cause = .sessionTakenOver     // DISCONNECTED_BY_OTHER_CONNECTION
        case 0x00010001, 0x00010002, // RPC_INITIATED_DISCONNECT / _LOGOFF (admin)
             0x00010003, 0x00010004, // IDLE_TIMEOUT / LOGON_TIMEOUT
             0x0001000B, 0x0001000C: // RPC_INITIATED_DISCONNECT_BY_USER / LOGOFF_BY_USER
            cause = .sessionEndedByServer
        default:
            let m = rawMessage.lowercased()
            if m.contains("logon") || m.contains("credential") || m.contains("password") { cause = .authenticationFailed }
            else if m.contains("certificate") { cause = .certificateRejected }
            else if m.contains("dns") || m.contains("name") { cause = .dnsFailure }
            else if m.contains("timeout") { cause = .timeout }
            else if m.contains("connect") { cause = .connectionFailed }
            else { cause = .unknown }
        }
        return RDPError(code: code, rawMessage: rawMessage, cause: cause)
    }
}

// MARK: - Certificate info + TOFU trust (PRD §9.5)

public struct CertInfo: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let commonName: String
    public let subject: String
    public let issuer: String
    public let fingerprintSHA256: String
    public let hostMismatch: Bool
    public let changed: Bool
    public init(host: String, port: Int, commonName: String, subject: String, issuer: String,
                fingerprintSHA256: String, hostMismatch: Bool, changed: Bool) {
        self.host = host; self.port = port; self.commonName = commonName
        self.subject = subject; self.issuer = issuer
        self.fingerprintSHA256 = fingerprintSHA256
        self.hostMismatch = hostMismatch; self.changed = changed
    }
}

public enum TrustState: Equatable, Sendable {
    case trusted                       // fingerprint matches a pinned value
    case unknown                       // first time seeing this host (TOFU)
    case changed(previousFingerprint: String) // differs from pinned — warn loudly
}

/// F-11: one pinned certificate as persisted by the trust store. The FINGERPRINT is the
/// trust anchor (exactly as before); `subject`/`issuer`/`commonName`/`pinnedAt` are
/// descriptive context captured at pin time so a later "certificate changed" review can
/// show an old→new diff. All context fields are optional: pins written before F-11
/// recorded only the fingerprint and must keep loading (decodeIfPresent).
public struct PinnedCertRecord: Codable, Equatable, Sendable {
    public var fingerprintSHA256: String
    public var subject: String?
    public var issuer: String?
    public var commonName: String?
    public var pinnedAt: Date?

    public init(fingerprintSHA256: String, subject: String? = nil, issuer: String? = nil,
                commonName: String? = nil, pinnedAt: Date? = nil) {
        self.fingerprintSHA256 = fingerprintSHA256
        self.subject = subject; self.issuer = issuer
        self.commonName = commonName; self.pinnedAt = pinnedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprintSHA256 = try c.decode(String.self, forKey: .fingerprintSHA256)
        subject = try c.decodeIfPresent(String.self, forKey: .subject)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer)
        commonName = try c.decodeIfPresent(String.self, forKey: .commonName)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
    }
}
