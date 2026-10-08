import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TouchRDPCore

/// Trust a server certificate in advance, from the connection editor: import the
/// certificate file, or paste its SHA-256 fingerprint. Either way the result is a pin
/// for the connection's host:port, exactly as if the user had approved the certificate
/// in the review sheet — so the first connection goes straight through, and a different
/// certificate is still stopped as a change.
struct TrustCertificateSheet: View {
    let hostLabel: String
    /// What's pinned for this host now, so replacing it is called out.
    let current: PinnedCertRecord?
    let onTrust: (ImportedCertificate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fingerprintText = ""
    /// The certificate read from a file, while the field still holds its fingerprint.
    @State private var imported: ImportedCertificate?
    @State private var fileError: String?

    private var parsed: Result<String, CertificateFingerprint.ParseError> {
        Result { try CertificateFingerprint.normalize(fingerprintText) }
            .mapError { $0 as? CertificateFingerprint.ParseError ?? .notHex }
    }

    /// The certificate to pin, if the field currently holds a valid fingerprint. File
    /// details are kept only while they still describe that fingerprint.
    private var candidate: ImportedCertificate? {
        guard case .success(let fingerprint) = parsed else { return nil }
        if let imported, imported.fingerprintSHA256 == fingerprint { return imported }
        return ImportedCertificate(fingerprintSHA256: fingerprint, commonName: "", subject: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust a Server Certificate")
                .font(.title3.bold())
            Text("Import the certificate for **\(hostLabel)**, or paste its SHA-256 fingerprint. TouchRDP will trust it without asking on the first connection. If the server ever presents a different certificate, you'll be asked to review it.")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Choose Certificate File…", action: chooseFile)
                Text(".cer, .crt, .pem or .der")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fileError {
                Text(fileError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SHA-256 fingerprint")
                    .font(.callout)
                TextField("AB:CD:EF:…", text: $fingerprintText, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("SHA-256 fingerprint of the server certificate")
                status
            }

            if let current, let candidate, current.fingerprintSHA256 != candidate.fingerprintSHA256 {
                Label("This replaces the certificate currently approved for \(hostLabel).",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Trust Certificate") {
                    guard let candidate else { return }
                    onTrust(candidate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(candidate == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private var status: some View {
        let trimmed = fingerprintText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch parsed {
        case .success(let fingerprint):
            if let imported, imported.fingerprintSHA256 == fingerprint {
                Label(certificateDescription(imported), systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Valid SHA-256 fingerprint", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failure(let error):
            if !trimmed.isEmpty {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func certificateDescription(_ cert: ImportedCertificate) -> String {
        let name = cert.commonName.isEmpty ? cert.subject : cert.commonName
        return name.isEmpty ? "Read from the certificate file" : "Certificate for \(name)"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.x509Certificate]
            + ["cer", "crt", "pem", "der"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Import"
        panel.message = "Choose the server's certificate file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let cert = try ImportedCertificate.parse(data)
            imported = cert
            fingerprintText = cert.fingerprintSHA256.uppercased()
            fileError = nil
        } catch {
            imported = nil
            fileError = (error as? LocalizedError)?.errorDescription
                ?? "The file couldn't be read (\(error.localizedDescription))."
        }
    }
}
