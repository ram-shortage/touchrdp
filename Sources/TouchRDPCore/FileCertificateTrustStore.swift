import Foundation
import os

// MARK: - FileCertificateTrustStore

public final class FileCertificateTrustStore: CertificateTrustStore, @unchecked Sendable {

    /// "host:port" -> pinned record (fingerprint is the trust anchor; subject/issuer/
    /// pinnedAt are F-11 context for the change diff). Read from the RDP thread
    /// (`evaluate`/`pinnedRecord`) while mutated on the main actor (`pin`/`remove`/
    /// `load`) — every access goes through `pinsLock` (CONC-1). File I/O is always
    /// performed on a snapshot OUTSIDE the lock.
    private var pins: [String: PinnedCertRecord] = [:]
    private let pinsLock = NSLock()
    private let storeURL: URL
    private static let logger = Logger(subsystem: "com.touchrdp.app", category: "TrustStore")

    /// Last load/save problem, for the app layer to surface (DATA-1). Written on the
    /// main actor only (load + save via pin/remove).
    public private(set) var lastError: StoreError?

    // DATA-2: versioned envelope with legacy fallbacks. v2 (F-11) stores full
    // PinnedCertRecord values; v1 stored bare "key -> fingerprint" strings; pre-
    // versioning was a bare dictionary. All three load (older pins simply have no
    // subject/issuer context); saves always write v2.
    private struct TrustFile: Codable {
        var version: Int
        var pins: [String: PinnedCertRecord]
    }
    private struct TrustFileV1: Codable {
        var version: Int
        var pins: [String: String]
    }
    private static let currentVersion = 2

    public convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        self.init(directory: appSupport.appendingPathComponent("TouchRDP", isDirectory: true))
    }

    /// Test seam (DATA-1): store under an arbitrary directory so ValidateCore can exercise
    /// corrupt/legacy/envelope loads in a temp dir.
    public init(directory: URL) {
        storeURL = directory.appendingPathComponent("trust.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - CertificateTrustStore

    public func evaluate(_ info: CertInfo) -> TrustState {
        let key = makeKey(host: info.host, port: info.port)
        pinsLock.lock()
        let stored = pins[key]
        pinsLock.unlock()
        guard let stored else { return .unknown }
        return stored.fingerprintSHA256 == info.fingerprintSHA256
            ? .trusted
            : .changed(previousFingerprint: stored.fingerprintSHA256)
    }

    public func pin(_ info: CertInfo) {
        let key = makeKey(host: info.host, port: info.port)
        // F-11: capture the descriptive context alongside the fingerprint so a future
        // "certificate changed" review can show an old→new diff. Empty strings from the
        // callback are stored as nil (nothing to diff against).
        let record = PinnedCertRecord(
            fingerprintSHA256: info.fingerprintSHA256,
            subject: info.subject.isEmpty ? nil : info.subject,
            issuer: info.issuer.isEmpty ? nil : info.issuer,
            commonName: info.commonName.isEmpty ? nil : info.commonName,
            pinnedAt: Date())
        pinsLock.lock()
        pins[key] = record
        let snapshot = pins
        pinsLock.unlock()
        save(snapshot)
    }

    /// F-11: the pinned record for a host, for the review sheet's old→new comparison.
    /// Never part of the trust decision (that's `evaluate`). RDP-thread-safe.
    public func pinnedRecord(host: String, port: Int) -> PinnedCertRecord? {
        pinsLock.lock(); defer { pinsLock.unlock() }
        return pins[makeKey(host: host, port: port)]
    }

    public func remove(host: String, port: Int) {
        pinsLock.lock()
        pins.removeValue(forKey: makeKey(host: host, port: port))
        let snapshot = pins
        pinsLock.unlock()
        save(snapshot)
    }

    // MARK: - Helpers

    private func makeKey(host: String, port: Int) -> String { "\(host):\(port)" }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            // Unreadable (permissions/IO) — treat as empty; not a decode-corruption.
            return
        }
        // 1) Current (v2) envelope: full pin records.
        if let file = try? JSONDecoder().decode(TrustFile.self, from: data) {
            pinsLock.lock(); pins = file.pins; pinsLock.unlock()
            if file.version != Self.currentVersion { save(file.pins) }  // upgrade in place
            return
        }
        // 2) v1 envelope ("key -> fingerprint" strings) — migrate to records (no
        //    subject/issuer context; the fields are optional) + rewrite as v2.
        if let v1 = try? JSONDecoder().decode(TrustFileV1.self, from: data) {
            let migrated = v1.pins.mapValues { PinnedCertRecord(fingerprintSHA256: $0) }
            pinsLock.lock(); pins = migrated; pinsLock.unlock()
            save(migrated)
            return
        }
        // 3) Legacy bare dictionary (pre-versioning) — migrate + rewrite as an envelope.
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            let migrated = legacy.mapValues { PinnedCertRecord(fingerprintSHA256: $0) }
            pinsLock.lock(); pins = migrated; pinsLock.unlock()
            save(migrated)
            return
        }
        // 4) Corrupt — back up the recoverable bytes before resetting.
        let backup = backUpCorruptFile(data)
        pinsLock.lock(); pins = [:]; pinsLock.unlock()
        lastError = .loadCorrupt(backupURL: backup)
        Self.logger.error("trust store corrupt; backed up to \(backup?.lastPathComponent ?? "<none>", privacy: .public)")
    }

    private func save(_ snapshot: [String: PinnedCertRecord]) {
        do {
            let file = TrustFile(version: Self.currentVersion, pins: snapshot)
            let data = try JSONEncoder().encode(file)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            lastError = .saveFailed("\(error)")
            Self.logger.error("trust store save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copy the recoverable bytes to a timestamped sidecar so a corrupt file is never
    /// silently overwritten by the next `save()`.
    private func backUpCorruptFile(_ data: Data) -> URL? {
        let ts = Int(Date().timeIntervalSince1970)
        let backupURL = storeURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(ts)")
            .appendingPathExtension("json")
        do {
            try data.write(to: backupURL, options: .atomic)
            return backupURL
        } catch {
            return nil
        }
    }
}
