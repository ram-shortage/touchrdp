import Foundation
import CoreGraphics
import IOSurface

/// One delivered snapshot of the remote framebuffer (BGRA, top row first).
///
/// PERF-5: the pixels live in an `IOSurface`, not a malloc'd buffer, so a canvas can
/// hand the surface straight to Core Animation as its layer `contents`. The render
/// server maps an IOSurface directly — no per-commit copy of the whole framebuffer,
/// which was the largest client-side cost left after PERF-1 (a `CGImage` over a
/// custom data provider is copied in full by CA on every commit, even when a single
/// row changed).
///
/// Lifetime contract: while any `RemoteFrame` object is alive its surface is never
/// written by the engine, so what's on screen is immutable, exactly like the old
/// per-frame `CGImage` snapshots. Releasing the last reference returns the surface to
/// the engine's pool (see `FrameSurfacePool`).
public final class RemoteFrame {
    public let surface: IOSurface
    public let width: Int
    public let height: Int
    private let onRelease: ((IOSurface) -> Void)?

    public var bytesPerRow: Int { surface.bytesPerRow }

    public init(surface: IOSurface, width: Int, height: Int,
                onRelease: ((IOSurface) -> Void)? = nil) {
        self.surface = surface
        self.width = width
        self.height = height
        self.onRelease = onRelease
    }

    deinit { onRelease?(surface) }

    /// An independent `CGImage` COPY of the frame (screenshots, clipboard). This is
    /// deliberately not the display path — a copy per frame is what PERF-5 removes.
    public func makeCGImage(colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) -> CGImage? {
        let rowBytes = surface.bytesPerRow
        let byteCount = rowBytes * height
        guard width > 0, height > 0, byteCount > 0 else { return nil }
        _ = surface.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surface.baseAddress, count: byteCount)
        _ = surface.unlock(options: .readOnly, seed: nil)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // BGRA bytes in memory == little-endian 32-bit, skip alpha (matches the canvas).
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
