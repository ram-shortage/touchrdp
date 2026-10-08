import Foundation
import TouchRDPCore

/// Fast TCP pre-flight for the connect flow: verifies the endpoint we are about to
/// dial actually answers BEFORE credentials are requested. Without it, a network
/// outage surfaces as whatever fails first afterwards — typically a vault/password
/// error — which blames the wrong thing and costs a pointless Touch ID prompt.
///
/// Deliberately implemented on BSD sockets (getaddrinfo + non-blocking connect), NOT
/// Network.framework: endpoint-security content filters (e.g. Cortex XDR, present on
/// this project's dev Mac) silently black-hole NWConnection flows from ad-hoc-signed
/// binaries while BSD sockets pass — and BSD sockets are what FreeRDP itself dials
/// with, so this probe's verdict matches what the real connect would experience.
/// It sends no RDP bytes; the server just sees an immediately-closed TCP connection.
enum ReachabilityProbe {

    enum Failure {
        case dns(String)
        case unreachable(String)
        case timedOut

        /// Translate into the session's error vocabulary (PRD §8.8 causes).
        func asRDPError(host: String, port: Int) -> RDPError {
            switch self {
            case .dns(let detail):
                return RDPError(code: 0, rawMessage: "DNS: \(detail)", cause: .dnsFailure)
            case .unreachable(let detail):
                return RDPError(code: 0, rawMessage: "\(host):\(port) unreachable: \(detail)",
                                cause: .hostUnreachable)
            case .timedOut:
                return RDPError(code: 0, rawMessage: "\(host):\(port) did not answer",
                                cause: .hostUnreachable)
            }
        }
    }

    /// Returns nil when the endpoint completed a TCP handshake within the timeout,
    /// otherwise the classified failure. Never throws and never prompts.
    ///
    /// The blocking work (getaddrinfo can stall on broken DNS) runs on a background
    /// thread raced against a deadline, so the caller is never held past
    /// `timeoutSeconds` (+ small scheduling slack) even if the resolver hangs.
    static func probe(host: String, port: Int, timeoutSeconds: Double = 5) async -> Failure? {
        guard !host.isEmpty, port > 0, port <= 65535 else {
            return .unreachable("invalid endpoint")
        }

        // One-shot resume guard: the worker and the deadline race.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true; return true
            }
        }
        let once = Once()

        return await withCheckedContinuation { (cont: CheckedContinuation<Failure?, Never>) in
            @Sendable func finish(_ result: Failure?) {
                guard once.claim() else { return }
                cont.resume(returning: result)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(blockingProbe(host: host, port: port, timeoutSeconds: timeoutSeconds))
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + timeoutSeconds + 1) { finish(.timedOut) }
        }
    }

    /// Resolve, then try each candidate address with the remaining time budget.
    private static func blockingProbe(host: String, port: Int,
                                      timeoutSeconds: Double) -> Failure? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let gaiStatus = getaddrinfo(host, String(port), &hints, &res)
        guard gaiStatus == 0, let first = res else {
            if let res { freeaddrinfo(res) }
            return .dns(String(cString: gai_strerror(gaiStatus)))
        }
        defer { freeaddrinfo(first) }

        var lastError = "no addresses"
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            defer { info = ai.pointee.ai_next }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }

            switch connectOnce(ai: ai.pointee, timeout: remaining) {
            case .success:
                return nil
            case .failure(let detail):
                lastError = detail
            case .timedOut:
                lastError = "timed out"
            }
        }
        return lastError == "timed out" ? .timedOut : .unreachable(lastError)
    }

    private enum AttemptResult {
        case success
        case failure(String)
        case timedOut
    }

    /// Non-blocking connect to one resolved address, waited on with poll(2).
    private static func connectOnce(ai: addrinfo, timeout: TimeInterval) -> AttemptResult {
        let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
        guard fd >= 0 else { return .failure("socket: \(errnoString())") }
        defer { close(fd) }

        // No SIGPIPE from the probe socket, ever.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let rc = connect(fd, ai.ai_addr, ai.ai_addrlen)
        if rc == 0 { return .success }
        guard errno == EINPROGRESS else { return .failure(errnoString()) }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRC = poll(&pfd, 1, Int32(max(1, timeout * 1000)))
        if pollRC == 0 { return .timedOut }
        guard pollRC > 0 else { return .failure("poll: \(errnoString())") }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else { return .failure(errnoString(soError)) }
        return .success
    }

    private static func errnoString(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}
