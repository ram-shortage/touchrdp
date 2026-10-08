import Foundation
import CoreGraphics

/// #22 — pure multi-monitor layout math, shared by the app layer and ValidateCore.
///
/// One source of truth for BOTH directions of the spanned-session geometry:
/// - `makeMonitors` builds the `MonitorDef` array declared to the host (moved here
///   verbatim from `ContentView.multiMonitorLayout` so the mapping below is consistent
///   by construction). `MonitorDef[i]` corresponds to screen frame `i` of the SAME
///   snapshot, and — because the bridge passes x/y through unchanged and the remote
///   framebuffer is the bounding box of the declared layout — each `MonitorDef` rect IS
///   that display's pixel rect within the spanned framebuffer (top-left origin,
///   normalized to a non-negative minimum at (0,0)).
/// - `viewports` turns that array back into per-display crop records for the
///   per-display window presentation. Total/deterministic: a count mismatch (displays
///   changed between connect and present) yields an explicit fallback, never a crash
///   or a misassigned window.
public enum MonitorLayout {

    // MARK: Monitor declaration (connect time)

    /// Build a remote multi-monitor layout from local screen frames (points, AppKit
    /// bottom-left origin — pass `NSScreen.screens.map(\.frame)` in order). macOS puts
    /// the primary at (0,0); RDP wants top-left pixel space, so Y is flipped against the
    /// union top and the whole layout normalized to a non-negative origin. A single
    /// uniform `scale` (the primary display's backing scale, or 1 with Retina off) keeps
    /// every monitor in one pixel space — mixed-DPI arrangements are approximate.
    /// Returns [] for fewer than two screens (caller uses the single-monitor path).
    public static func makeMonitors(screenFramesPoints: [CGRect], scale: CGFloat) -> [MonitorDef] {
        guard screenFramesPoints.count > 1, scale > 0 else { return [] }
        let primaryIndex = screenFramesPoints.firstIndex(where: { $0.origin == .zero }) ?? 0
        let unionTop = screenFramesPoints.map { $0.maxY }.max() ?? 0
        func evenInt(_ v: CGFloat) -> Int { let i = Int(v.rounded()); return i - (i % 2) }

        // Raw top-left points before normalization.
        let raw = screenFramesPoints.enumerated().map { i, f -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, primary: Bool) in
            (f.minX, unionTop - f.maxY, f.width, f.height, i == primaryIndex)
        }
        let minX = raw.map { $0.x }.min() ?? 0
        let minY = raw.map { $0.y }.min() ?? 0
        let sf = min(max(Int((scale * 100).rounded()), 100), 500)
        return raw.map { r in
            MonitorDef(x: evenInt((r.x - minX) * scale),
                       y: evenInt((r.y - minY) * scale),
                       width: evenInt(r.w * scale),
                       height: evenInt(r.h * scale),
                       isPrimary: r.primary,
                       scaleFactor: sf)
        }
    }

    /// The spanned framebuffer size implied by a monitor layout (the union bounding
    /// box — matches `SessionController.makeConfig`'s width/height derivation).
    public static func spannedFrameSize(of monitors: [MonitorDef]) -> CGSize {
        CGSize(width: CGFloat(monitors.map { $0.x + $0.width }.max() ?? 0),
               height: CGFloat(monitors.map { $0.y + $0.height }.max() ?? 0))
    }

    // MARK: Per-display viewports (present time)

    /// One display's slice of the spanned session: which local screen shows it and the
    /// remote-pixel rect to crop out of the spanned framebuffer.
    public struct Viewport: Equatable, Sendable {
        /// Index into the screen list (same order as the connect-time snapshot).
        public let screenIndex: Int
        /// Crop within the spanned framebuffer, in remote pixels, top-left origin.
        public let remotePixelRect: CGRect
        /// The main remote monitor's viewport — hosts the primary (toolbar) window.
        public let isPrimary: Bool
    }

    public enum ViewportResult: Equatable {
        case perDisplay([Viewport])
        /// The presentation can't be split safely — show the spanned single canvas.
        case fallback(reason: String)
    }

    /// Map the connect-time monitor layout onto the current screen list. `monitors`
    /// and the screens were derived from the same `NSScreen.screens` snapshot at
    /// connect (index-aligned), so any count drift means displays changed — fall back
    /// to the proven single-window presentation instead of guessing an assignment.
    public static func viewports(monitors: [MonitorDef], screenCount: Int) -> ViewportResult {
        guard monitors.count > 1 else {
            return .fallback(reason: "the session spans fewer than two monitors")
        }
        guard monitors.count == screenCount else {
            return .fallback(reason: "the display arrangement changed (\(monitors.count) monitors at connect, \(screenCount) screens now)")
        }
        guard monitors.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.x >= 0 && $0.y >= 0 }) else {
            return .fallback(reason: "the monitor layout is degenerate")
        }
        let viewports = monitors.enumerated().map { i, m in
            Viewport(screenIndex: i,
                     remotePixelRect: CGRect(x: CGFloat(m.x), y: CGFloat(m.y),
                                             width: CGFloat(m.width), height: CGFloat(m.height)),
                     isPrimary: m.isPrimary)
        }
        return .perDisplay(viewports)
    }

    // MARK: Crop + input math (used by RDPNSView; pure so ValidateCore asserts it)

    /// CALayer `contentsRect` (normalized [0,1]) that crops `viewport` out of a frame of
    /// `frameSize` pixels, expressed in TOP-LEFT-origin unit space (i.e. for a layer
    /// whose contents are flipped — AppKit's flipped, layer-backed canvas). Use
    /// `verticallyFlippedUnitRect` for a bottom-left-origin layer. Clamped to [0,1].
    public static func contentsRect(viewport: CGRect, frameSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let r = CGRect(x: viewport.minX / frameSize.width,
                       y: viewport.minY / frameSize.height,
                       width: viewport.width / frameSize.width,
                       height: viewport.height / frameSize.height)
        // Clamp into the unit square (defensively; inputs are same-source so this is
        // normally the identity).
        let clamped = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clamped.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : clamped
    }

    /// Convert a unit-space rect between top-left and bottom-left origin conventions
    /// (its own inverse).
    public static func verticallyFlippedUnitRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Map a view point (top-left-origin points, aspect-fit letterboxed) to a remote
    /// pixel inside `viewport`: aspect-fit the viewport into `viewSize`, translate the
    /// point into viewport-relative pixels, then offset by the viewport's origin in the
    /// spanned frame. The result is clamped INTO the viewport, so input from one
    /// display's window can never land on another display's monitor.
    public static func remotePixel(viewPoint: CGPoint, viewSize: CGSize,
                                   viewport: CGRect) -> (x: Int, y: Int) {
        let minX = Int(viewport.minX), minY = Int(viewport.minY)
        let maxX = max(minX, Int(viewport.maxX) - 1)
        let maxY = max(minY, Int(viewport.maxY) - 1)
        guard viewport.width > 0, viewport.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return (minX, minY) }
        let scale = min(viewSize.width / viewport.width, viewSize.height / viewport.height)
        let dispW = viewport.width * scale
        let dispH = viewport.height * scale
        let ox = (viewSize.width - dispW) / 2
        let oy = (viewSize.height - dispH) / 2
        let relX = (viewPoint.x - ox) / dispW
        let relY = (viewPoint.y - oy) / dispH
        let rx = minX + Int(relX * viewport.width)
        let ry = minY + Int(relY * viewport.height)
        return (max(minX, min(rx, maxX)), max(minY, min(ry, maxY)))
    }
}
