import Foundation

/// #25 (remote→Mac file paste): pure parsing/math for the SERVER's clipboard file list.
/// The C bridge hands the raw FILEGROUPDESCRIPTORW blob (4-byte count + n × 592-byte
/// FILEDESCRIPTORW) to Swift untouched (only size-capped); this type turns it into
/// sanitized descriptors and provides the sequential-pull chunk math. No I/O here —
/// ValidateCore asserts these rules headlessly.
///
/// Security posture (see SECURITY.md): the blob is SERVER-CONTROLLED. Names are
/// sanitized with the same FILEDESCRIPTORW rules as the outbound offer (path
/// separators / reserved chars stripped) so a hostile server can never steer a write
/// outside the destination folder Finder hands us; the count and blob length are
/// cross-checked so a truncated or lying header is rejected, never over-read.
public enum RemoteFileClipboard {
    /// Wire size of one FILEDESCRIPTORW — same 592 the F-8 offer path uses
    /// (`FileClipboardOffer.fileDescriptorWireSize`, `_Static_assert`ed in C).
    public static let descriptorStride = FileClipboardOffer.fileDescriptorWireSize
    /// Mirror of the C bridge's 4 MiB inbound blob cap (CLIP_MAX_INBOUND_FILELIST_BYTES).
    public static let maxBlobBytes = 4 * 1024 * 1024
    /// Most descriptors a capped blob can carry: (4 MiB − 4) / 592 ≈ 7084 files.
    public static let maxFiles = (maxBlobBytes - 4) / descriptorStride

    /// FILEDESCRIPTORW.dwFlags bits we honor (winpr/shell.h).
    private static let fdAttributes: UInt32 = 0x0000_0004 // FD_ATTRIBUTES
    private static let fdFileSize: UInt32   = 0x0000_0040 // FD_FILESIZE
    /// FILE_ATTRIBUTE_DIRECTORY — folders are listed by Explorer when a folder is
    /// copied; V1 pulls FILES only (a directory descriptor is skipped, matching the
    /// outbound "no folders" rule).
    private static let attrDirectory: UInt32 = 0x0000_0010

    /// One remote file as announced by the server, ready for a local file promise.
    /// `size` is nil when the descriptor omitted FD_FILESIZE (the puller then issues a
    /// FILECONTENTS_SIZE request before pulling ranges). `listIndex` is the position in
    /// the SERVER's list — the index FILECONTENTS requests must address (it differs
    /// from our array index once directory entries are skipped).
    public struct Descriptor: Equatable, Sendable {
        public let listIndex: UInt32
        public let name: String        // sanitized: no path separators, ≤259 UTF-16 units
        public let size: UInt64?       // nil => unknown (FD_FILESIZE absent)
        public let attributes: UInt32  // raw dwFileAttributes (0 when FD_ATTRIBUTES absent)
        public init(listIndex: UInt32, name: String, size: UInt64?, attributes: UInt32) {
            self.listIndex = listIndex; self.name = name
            self.size = size; self.attributes = attributes
        }
    }

    /// Parse a FILEGROUPDESCRIPTORW blob. Returns nil when the blob is structurally
    /// invalid (too short, count of 0, count over the cap, or fewer descriptor bytes
    /// than the count promises — a truncated blob is rejected, never over-read).
    /// Directory entries are skipped (kept out of the returned list) but retain their
    /// original `listIndex` numbering for the survivors. Names are sanitized and
    /// de-duplicated case-insensitively (two "r.txt" entries would otherwise collide in
    /// the destination folder).
    public static func parse(_ blob: Data) -> [Descriptor]? {
        guard blob.count >= 4, blob.count <= maxBlobBytes else { return nil }
        let count = Int(readUInt32(blob, at: 0))
        guard count > 0, count <= maxFiles,
              blob.count >= 4 + count * descriptorStride else { return nil }

        var result: [Descriptor] = []
        result.reserveCapacity(min(count, 256))
        var seenNames = Set<String>()
        for i in 0..<count {
            let base = 4 + i * descriptorStride
            let dwFlags = readUInt32(blob, at: base)
            let attributes = (dwFlags & fdAttributes) != 0 ? readUInt32(blob, at: base + 36) : 0
            if attributes & attrDirectory != 0 { continue }   // files only (V1)
            var size: UInt64?
            if dwFlags & fdFileSize != 0 {
                let hi = readUInt32(blob, at: base + 64)
                let lo = readUInt32(blob, at: base + 68)
                size = UInt64(hi) << 32 | UInt64(lo)
            }
            // cFileName: WCHAR[260] at +72, UTF-16LE, NUL-terminated. Sanitize with the
            // same rules the outbound offer applies (hostile "..\evil" cannot escape).
            let rawName = readUTF16Name(blob, at: base + 72)
            let name = uniquified(FileClipboardOffer.sanitizedFileName(rawName),
                                  existing: &seenNames)
            result.append(Descriptor(listIndex: UInt32(i), name: name,
                                     size: size, attributes: attributes))
        }
        return result
    }

    // MARK: Chunk math (sequential RANGE pulls)

    /// Length of the RANGE request to issue at `offset` for a file of `totalSize`,
    /// capped at `chunkSize`. 0 means the transfer is complete (so a 0-byte file needs
    /// zero RANGE pulls).
    public static func chunkLength(at offset: UInt64, totalSize: UInt64,
                                   chunkSize: UInt32) -> UInt32 {
        guard offset < totalSize else { return 0 }
        return UInt32(min(UInt64(chunkSize), totalSize - offset))
    }

    // MARK: Stream ids

    /// Monotonic per-session streamId allocator for FILECONTENTS requests. Swift owns
    /// the ids (the C bridge is a stateless pass-through); responses are matched back
    /// by id in the puller's pending table.
    public struct StreamIdAllocator: Sendable {
        private var next: UInt32
        public init(startingAt first: UInt32 = 1) { next = first }
        public mutating func allocate() -> UInt32 {
            let id = next
            next &+= 1
            if next == 0 { next = 1 }   // skip 0 on wraparound (kept as "no stream")
            return id
        }
    }

    // MARK: - Internals

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return UInt32(data[s]) | UInt32(data[s + 1]) << 8
            | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
    }

    /// Decode the NUL-terminated UTF-16LE name from the fixed 260-WCHAR field.
    private static func readUTF16Name(_ data: Data, at offset: Int) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(64)
        let s = data.startIndex + offset
        for i in 0..<260 {
            let unit = UInt16(data[s + 2 * i]) | UInt16(data[s + 2 * i + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Case-insensitive de-duplication within one announcement (" 2", " 3"… before the
    /// extension) — Finder would otherwise overwrite same-named promises in one paste.
    private static func uniquified(_ name: String, existing: inout Set<String>) -> String {
        if existing.insert(name.lowercased()).inserted { return name }
        let dot = name.lastIndex(of: ".")
        let stem = dot.map { $0 == name.startIndex ? name : String(name[..<$0]) } ?? name
        let ext = dot.flatMap { $0 == name.startIndex ? nil : String(name[$0...]) } ?? ""
        var n = 2
        while true {
            let candidate = "\(stem) \(n)\(ext)"
            if existing.insert(candidate.lowercased()).inserted { return candidate }
            n += 1
        }
    }
}
