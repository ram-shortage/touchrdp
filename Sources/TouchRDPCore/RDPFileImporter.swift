import Foundation

// MARK: - RDPFileImporter

public enum RDPFileImporter {

    public enum ImportError: LocalizedError {
        case missingHost

        public var errorDescription: String? {
            switch self {
            case .missingHost:
                return "The .rdp file does not contain a usable host address (full address)."
            }
        }
    }

    /// Parse a Microsoft .rdp file into a Connection.
    /// Lines are formatted as: key:type:value  (type is 's' for string, 'i' for integer).
    /// Unknown keys and missing values are tolerated.
    public static func parse(_ url: URL) throws -> Connection {
        let text = try String(contentsOf: url, encoding: .utf8)
        var kvs: [String: String] = [:]

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Format: key:type:value  — split on first two colons only.
            let parts = trimmed.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let key = String(parts[0]).lowercased()
            // parts[1] is the type, parts[2] is the value (may be absent)
            let value = parts.count == 3 ? String(parts[2]) : ""
            kvs[key] = value
        }

        // Parse host and optional port from "full address" (may be "host:port").
        guard let rawAddress = kvs["full address"], !rawAddress.isEmpty else {
            throw ImportError.missingHost
        }

        var host: String
        var port: Int = 3389

        // "full address" may be "host:port" or just "host".
        if let colonRange = rawAddress.range(of: ":", options: .backwards),
           let parsedPort = Int(rawAddress[rawAddress.index(after: colonRange.lowerBound)...]) {
            host = String(rawAddress[..<colonRange.lowerBound])
            port = parsedPort
        } else {
            host = rawAddress
        }

        // Override port from dedicated "server port" key if present.
        if let serverPortStr = kvs["server port"], let serverPort = Int(serverPortStr) {
            port = serverPort
        }

        // Username and domain.
        let username = kvs["username"] ?? ""
        let domain = kvs["domain"].flatMap { $0.isEmpty ? nil : $0 }

        // Security: NLA if enablecredsspsupport != 0, else TLS.
        let security: RDPSecurity
        if let credSSP = kvs["enablecredsspsupport"], Int(credSSP) == 0 {
            security = .tls
        } else {
            security = .nla
        }

        // Gateway: only if hostname present and usage method != 0.
        var gateway: GatewaySettings? = nil
        if let gwHost = kvs["gatewayhostname"], !gwHost.isEmpty {
            let gwUsage = kvs["gatewayusagemethod"].flatMap(Int.init) ?? 1
            if gwUsage != 0 {
                gateway = GatewaySettings(hostname: gwHost)
            }
        }

        // Clipboard.
        let clipboard: Bool
        if let v = kvs["redirectclipboard"], let i = Int(v) {
            clipboard = i != 0
        } else {
            clipboard = true  // default on
        }

        // Audio: audiomode 0 = redirect (enabled), 1 = play on server, 2 = disabled.
        let audio: Bool
        if let v = kvs["audiomode"], let i = Int(v) {
            audio = i == 0
        } else {
            audio = true
        }

        // Display.
        let width = kvs["desktopwidth"].flatMap(Int.init) ?? 1280
        let height = kvs["desktopheight"].flatMap(Int.init) ?? 800
        let display = DisplaySettings(width: width, height: height)

        // Name: prefer host, fall back to filename without extension.
        let name = host.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : host

        return Connection(
            name: name,
            host: host,
            port: port,
            username: username,
            domain: domain,
            security: security,
            display: display,
            gateway: gateway,
            clipboardEnabled: clipboard,
            audioEnabled: audio
        )
    }
}
