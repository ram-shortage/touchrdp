import Foundation

// MARK: - Screenshot file naming (F-13)

/// Filename construction for session screenshots. Pure (Foundation-only) so the
/// sanitization is validated headlessly: "/" is the POSIX path separator, ":" the
/// legacy HFS one (and Finder's display separator), "\" is path-hostile on the Windows
/// side of a shared folder, and control characters have no business in a filename.
public enum ScreenshotNaming {
    /// Replace path-hostile ("/", ":", "\") and invisible (control/newline) characters
    /// with spaces, collapse whitespace runs, and trim. An empty or all-hostile name
    /// falls back to "Session" so the default filename is never blank.
    public static func sanitized(_ name: String) -> String {
        let hostile = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = name.unicodeScalars.map { hostile.contains($0) ? " " : Character($0) }
        let collapsed = String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? "Session" : collapsed
    }

    /// Default save-panel filename: "TouchRDP <name> <timestamp>.png". The timestamp
    /// format uses periods (no colons) so the whole name is path-safe as produced.
    public static func defaultFileName(connectionName: String, date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "TouchRDP \(sanitized(connectionName)) \(fmt.string(from: date)).png"
    }
}
