import Foundation
import CryptoKit
import Security

// MARK: - Pre-trusting a server certificate
//
// The trust store compares fingerprints as strings, in the exact form FreeRDP produces:
// the SHA-256 of the certificate's DER bytes as lowercase hex pairs joined by colons
// ("ab:cd:…", 95 characters). Everything that pins a certificate the user supplied —
// a pasted fingerprint or an imported certificate file — goes through this file so it
// lands in that same form and matches what the server later presents.

public enum CertificateFingerprint {

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case notHex
        /// 40 hex digits: a SHA-1 thumbprint, which is what Windows shows by default.
        case looksLikeSHA1
        case wrongLength(digits: Int)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the certificate's SHA-256 fingerprint."
            case .notHex:
                return "A fingerprint can only contain the digits 0–9 and letters A–F (colons and spaces are fine)."
            case .looksLikeSHA1:
                return "That's a SHA-1 thumbprint, which is what Windows shows by default. TouchRDP needs the SHA-256 fingerprint, or you can import the certificate file instead."
            case .wrongLength(let digits):
                return "A SHA-256 fingerprint has 64 hex digits; this one has \(digits)."
            }
        }
    }

    /// Turn a fingerprint typed or pasted in any common layout into the canonical form.
    /// Accepts upper or lower case, separated by colons, spaces or dashes, or not at
    /// all, and tolerates a label in front (`SHA256 Fingerprint=AB:CD…`, as printed by
    /// `openssl x509 -fingerprint -sha256`).
    public static func normalize(_ text: String) throws -> String {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let eq = body.lastIndex(of: "=") { body = body[body.index(after: eq)...] }
        let separators: Set<Character> = [":", "-", " ", "\t", "\n", "\r"]
        let digits = body.filter { !separators.contains($0) }.lowercased()
        guard !digits.isEmpty else { throw ParseError.empty }
        guard digits.allSatisfy(\.isHexDigit) else { throw ParseError.notHex }
        if digits.count == 40 { throw ParseError.looksLikeSHA1 }
        guard digits.count == 64 else { throw ParseError.wrongLength(digits: digits.count) }
        return colonSeparated(Array(digits))
    }

    /// The canonical SHA-256 fingerprint of a DER-encoded certificate.
    public static func sha256(ofDER der: Data) -> String {
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return colonSeparated(Array(hex))
    }

    private static func colonSeparated(_ hexDigits: [Character]) -> String {
        stride(from: 0, to: hexDigits.count, by: 2)
            .map { String(hexDigits[$0..<$0 + 2]) }
            .joined(separator: ":")
    }
}

/// A certificate read from a file the user chose, ready to pin.
public struct ImportedCertificate: Equatable, Sendable {
    public let fingerprintSHA256: String
    public let commonName: String
    /// A short human-readable summary of the subject (macOS's own summary string).
    public let subject: String

    public init(fingerprintSHA256: String, commonName: String, subject: String) {
        self.fingerprintSHA256 = fingerprintSHA256
        self.commonName = commonName
        self.subject = subject
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case tooLarge
        case notACertificate

        public var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "That file is too large to be a certificate."
            case .notACertificate:
                return "That file isn't a certificate TouchRDP can read. Export the server's certificate as a .cer file, either “DER encoded binary” or “Base-64 encoded”."
            }
        }
    }

    /// A single X.509 certificate is a few KiB; refuse anything absurd before parsing.
    static let maxFileBytes = 1 << 20

    /// Read a PEM (Base-64, `-----BEGIN CERTIFICATE-----`) or DER (binary) certificate.
    /// When a PEM file holds a chain, the FIRST certificate is used: that is the
    /// server's own certificate in every standard export.
    public static func parse(_ data: Data) throws -> ImportedCertificate {
        guard data.count <= maxFileBytes else { throw ImportError.tooLarge }
        let der = pemBody(data) ?? data
        guard !der.isEmpty,
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw ImportError.notACertificate
        }
        var cn: CFString?
        SecCertificateCopyCommonName(cert, &cn)
        let summary = SecCertificateCopySubjectSummary(cert) as String?
        // Hash the bytes macOS actually parsed, so trailing junk after the DER
        // structure in a sloppy export can't change the fingerprint.
        let canonicalDER = SecCertificateCopyData(cert) as Data
        return ImportedCertificate(
            fingerprintSHA256: CertificateFingerprint.sha256(ofDER: canonicalDER),
            commonName: (cn as String?) ?? "",
            subject: summary ?? "")
    }

    /// The DER bytes of the first PEM certificate block, or nil if this isn't PEM.
    private static func pemBody(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex)
        else { return nil }
        let base64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(base64)) ?? Data()
    }
}
