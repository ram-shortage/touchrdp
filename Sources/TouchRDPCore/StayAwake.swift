import Foundation

/// F-26 "Stay awake" — pure logic for the bounded remote-lock deferral.
///
/// The feature injects a benign no-op keystroke (F15) so the remote session's idle
/// timer never elapses, deferring the screensaver/lock — bounded by a re-arming cap so
/// an abandoned session still locks. The on/off state is a per-SESSION runtime control
/// (always off on a new connection, never persisted); only the cap duration is a
/// persisted per-connection setting (`Connection.stayAwakeCapSeconds`).
///
/// This type holds the constants, the cap clamp, and the tick decision — kept pure so
/// ValidateCore can assert the truth table without a session.
public enum StayAwake {
    /// Cap bounds: 1 minute to 1 hour. The cap is what keeps the feature from being an
    /// indefinite lock-policy bypass, so it can never be configured away.
    public static let capRange: ClosedRange<Double> = 60...3600
    /// Default cap: 5 minutes.
    public static let defaultCapSeconds: Double = 300
    /// Keep-alive injection interval. Also the minimum REAL-input idle time before a
    /// tick may fire, so a synthetic keystroke is never spliced into live typing.
    public static let tickIntervalSeconds: Double = 45

    public static func clampCap(_ seconds: Double) -> Double {
        min(max(seconds, capRange.lowerBound), capRange.upperBound)
    }

    /// Whether a keep-alive tick may inject right now. True ONLY when the feature is
    /// armed with time remaining, the session is connected, and the user has been idle
    /// (no REAL input) for at least the tick interval. Any false leg is a security
    /// invariant: never inject when disarmed, expired, disconnected, or mid-typing.
    public static func shouldInjectKeepAlive(armed: Bool,
                                             remainingSeconds: Double,
                                             connected: Bool,
                                             secondsSinceRealInput: Double,
                                             tickIntervalSeconds: Double = StayAwake.tickIntervalSeconds) -> Bool {
        armed
            && remainingSeconds > 0
            && connected
            && secondsSinceRealInput >= tickIntervalSeconds
    }
}
