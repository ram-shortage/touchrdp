import Foundation

/// F-8: pure validation/sanitization logic for the Mac→Windows clipboard FILE offer
/// (cliprdr "FileGroupDescriptorW"). No filesystem access here — the engine lstats the
/// candidate files and feeds `Candidate`s; ValidateCore asserts these rules headlessly.
///
/// Security posture (see SECURITY.md): regular files only — directories are rejected
/// and symlinks are rejected WITHOUT following them (the bridge additionally opens with
/// O_NOFOLLOW); the whole offer is capped at 64 files / 256 MiB; names are reduced to
/// what a FILEDESCRIPTORW can carry (no path separators, ≤259 UTF-16 units).
public enum FileClipboardOffer {
    /// Hard cap on the number of files in one offer (mirrored by the C bridge).
    public static let maxFiles = 64
    /// Hard cap on the combined size of one offer: 256 MiB.
    public static let maxTotalBytes: UInt64 = 256 * 1024 * 1024
    /// FILEDESCRIPTORW.cFileName is WCHAR[260] INCLUDING the terminator → 259 usable
    /// UTF-16 code units.
    public static let maxNameUTF16 = 259
    /// On-wire FILEDESCRIPTORW size, verified against winpr/shell.h (FreeRDP 3.27):
    /// 4 (dwFlags) + 16 (clsid) + 8 (sizel) + 8 (pointl) + 4 (attributes)
    /// + 24 (3 × FILETIME) + 4 (sizeHigh) + 4 (sizeLow) + 520 (WCHAR[260]) = 592.
    /// The C bridge `_Static_assert`s the same value against the real struct.
    public static let fileDescriptorWireSize = 592
    /// A FILEGROUPDESCRIPTORW blob is a 4-byte count + n × 592-byte descriptors.
    public static func descriptorBlobSize(fileCount: Int) -> Int {
        4 + fileCount * fileDescriptorWireSize
    }

    /// One dropped/copied item as observed by the engine (lstat semantics: `isSymlink`
    /// describes the item itself, never its target).
    public struct Candidate: Equatable, Sendable {
        public var path: String
        public var name: String
        public var size: UInt64
        public var isRegularFile: Bool
        public var isSymlink: Bool
        public init(path: String, name: String, size: UInt64,
                    isRegularFile: Bool, isSymlink: Bool) {
            self.path = path; self.name = name; self.size = size
            self.isRegularFile = isRegularFile; self.isSymlink = isSymlink
        }
    }

    /// A file cleared for staging: sanitized name, unique (case-insensitively — Windows
    /// filenames are) within the offer.
    public struct StagedFile: Equatable, Sendable {
        public var path: String
        public var name: String
        public var size: UInt64
        public init(path: String, name: String, size: UInt64) {
            self.path = path; self.name = name; self.size = size
        }
    }

    public struct ValidationResult: Equatable, Sendable {
        /// Files to stage (empty when the offer is blocked or nothing was offerable).
        public var staged: [StagedFile]
        /// Human-readable per-file rejection notes (symlinks, folders, …).
        public var rejections: [String]
        /// Non-nil when the WHOLE offer is refused (over the count or size cap).
        public var offerBlocked: String?
        public var totalBytes: UInt64
        public init(staged: [StagedFile], rejections: [String],
                    offerBlocked: String?, totalBytes: UInt64) {
            self.staged = staged; self.rejections = rejections
            self.offerBlocked = offerBlocked; self.totalBytes = totalBytes
        }
    }

    /// Apply the F-8 rules: per-file eligibility (regular files only, no symlink
    /// following), name sanitization + de-duplication, then the whole-offer caps
    /// (>64 files or >256 MiB refuses the ENTIRE offer — no silent partial transfer).
    public static func validate(_ candidates: [Candidate]) -> ValidationResult {
        var staged: [StagedFile] = []
        var rejections: [String] = []
        var seen = Set<String>()
        var total: UInt64 = 0

        for c in candidates {
            if c.isSymlink {
                rejections.append("“\(c.name)” skipped — symbolic links aren’t offered.")
                continue
            }
            if !c.isRegularFile {
                rejections.append("“\(c.name)” skipped — only regular files can be offered (no folders).")
                continue
            }
            let name = uniquified(sanitizedFileName(c.name), existing: &seen)
            staged.append(StagedFile(path: c.path, name: name, size: c.size))
            total &+= c.size
        }

        if staged.count > maxFiles {
            return ValidationResult(
                staged: [], rejections: rejections,
                offerBlocked: "Too many files — an offer is capped at \(maxFiles) files.",
                totalBytes: 0)
        }
        if total > maxTotalBytes {
            return ValidationResult(
                staged: [], rejections: rejections,
                offerBlocked: "Offer too large — capped at 256 MB total.",
                totalBytes: 0)
        }
        return ValidationResult(staged: staged, rejections: rejections,
                                offerBlocked: nil, totalBytes: total)
    }

    /// Reduce a filename to what FILEDESCRIPTORW allows: path separators (`/ \ :`) and
    /// the remaining Windows-reserved characters (`* ? " < > |`) plus control chars
    /// become spaces (then whitespace collapses); the result is truncated to 259 UTF-16
    /// units preserving a short extension where feasible; a hostile/empty name falls
    /// back to "file".
    public static func sanitizedFileName(_ raw: String) -> String {
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\", "/", ":", "*", "?", "\"", "<", ">", "|":
                cleaned.append(" ")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    cleaned.append(" ")
                } else {
                    cleaned.unicodeScalars.append(scalar)
                }
            }
        }
        var name = cleaned.split(separator: " ").joined(separator: " ")
        // Bare dot-names are meaningless/hazardous as Windows file names.
        while name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty { name = "file" }
        return truncatedName(name, limit: maxNameUTF16)
    }

    // MARK: - Internals (reached through the public API in ValidateCore)

    /// Split "stem.ext" keeping only a SHORT real extension (≤ 16 UTF-16 units incl.
    /// the dot, exactly one dot, non-empty stem); otherwise the whole name is the stem.
    private static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let ext = String(name[dot...])                // includes the "."
        guard ext.utf16.count > 1, ext.utf16.count <= 16,
              !ext.dropFirst().contains(".") else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    /// Longest prefix of `s` that fits in `limit` UTF-16 code units. Iterates grapheme
    /// clusters, so it can never split a surrogate pair (or a combining sequence).
    private static func utf16Prefix(_ s: String, limit: Int) -> String {
        guard s.utf16.count > limit else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf16.count
            if used + n > limit { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// Truncate to `limit` UTF-16 units, keeping the extension when there is room.
    private static func truncatedName(_ name: String, limit: Int) -> String {
        guard name.utf16.count > limit else { return name }
        let (stem, ext) = splitExtension(name)
        guard !ext.isEmpty, ext.utf16.count < limit else {
            let cut = utf16Prefix(name, limit: limit)
            return cut.isEmpty ? "file" : cut
        }
        let cutStem = utf16Prefix(stem, limit: limit - ext.utf16.count)
        return (cutStem.isEmpty ? "f" : cutStem) + ext
    }

    /// Ensure the name is unique (case-insensitively) within the offer, inserting a
    /// " 2", " 3"… counter before the extension and re-budgeting the 259-unit cap.
    private static func uniquified(_ name: String, existing: inout Set<String>) -> String {
        if existing.insert(name.lowercased()).inserted { return name }
        let (stem, ext) = splitExtension(name)
        var n = 2
        while true {
            let suffix = " \(n)"
            let budget = max(1, maxNameUTF16 - ext.utf16.count - suffix.utf16.count)
            let candidate = utf16Prefix(stem.isEmpty ? "file" : stem, limit: budget) + suffix + ext
            if existing.insert(candidate.lowercased()).inserted { return candidate }
            n += 1
        }
    }
}
