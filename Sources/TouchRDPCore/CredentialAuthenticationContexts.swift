import Foundation
import LocalAuthentication

/// Only successful, app-initiated authentications can be reused. Device-unlock
/// reuse is disabled even on new contexts: a fresh LAContext alone does not force
/// a prompt when touchIDAuthenticationAllowableReuseDuration is nonzero.
final class CredentialAuthenticationContexts {
    struct Request {
        let context: LAContext
        let connectionID: UUID
        let token: UUID
        let reuseSeconds: Int
        let authenticatedAt: Date?
    }

    private let lock = NSLock()
    private let now: () -> Date
    private var cached: [UUID: Request] = [:]
    private var tokens: [UUID: UUID] = [:]

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func begin(for id: UUID, reuseSeconds: Int?, forceFresh: Bool) -> Request {
        let seconds = min(max(reuseSeconds ?? 0, 0),
                          KeychainCredentialVault.maxReuseSeconds)
        lock.lock(); defer { lock.unlock() }
        if !forceFresh, seconds > 0, let request = cached[id],
           let authenticatedAt = request.authenticatedAt,
           now().timeIntervalSince(authenticatedAt) < Double(min(seconds, request.reuseSeconds)) {
            return request
        }
        cached[id] = nil
        let token = UUID()
        tokens[id] = token
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        return Request(context: context, connectionID: id, token: token,
                       reuseSeconds: seconds, authenticatedAt: nil)
    }

    /// Called only after the complete credential flow succeeds. Reusing a context
    /// never extends its original lifetime. A credential edit or newer request
    /// invalidates the token, so an older in-flight read cannot repopulate the cache.
    func complete(_ request: Request) {
        lock.lock(); defer { lock.unlock() }
        guard tokens[request.connectionID] == request.token,
              request.reuseSeconds > 0, request.authenticatedAt == nil else { return }
        cached[request.connectionID] = Request(
            context: request.context, connectionID: request.connectionID,
            token: request.token, reuseSeconds: request.reuseSeconds, authenticatedAt: now())
    }

    func evict(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cached[id] = nil
        tokens[id] = nil
    }

    func evictAll() {
        lock.lock(); defer { lock.unlock() }
        cached.removeAll()
        tokens.removeAll()
    }
}
