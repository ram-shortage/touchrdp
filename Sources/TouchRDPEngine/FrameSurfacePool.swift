import Foundation
import IOSurface
import TouchRDPCore

/// PERF-1/PERF-5: reusable full-frame BGRA surfaces for zero-copy frame snapshots.
///
/// The bridge hands `handleFrame` a pointer into GDI's framebuffer plus the region
/// this paint changed, while the RDP thread holds the lock every input send contends
/// on. This pool keeps a small set of persistent `IOSurface`s and, per paint, copies
/// only the rows by which the chosen surface lags the freshest content. The surface
/// is then delivered as a `RemoteFrame`, which the canvas assigns straight to its
/// layer's `contents` — Core Animation maps an IOSurface directly, so nothing copies
/// the full framebuffer again downstream (PERF-5).
///
/// Correctness model:
/// - A `RemoteFrame` retains a surface. While any frame holds a surface, that surface
///   is "in use" and is NEVER written — so displayed pixels are immutable.
/// - Every surface (free, in use, or cooling) accumulates a `staleRows` box: the union
///   of all paint regions since that surface was last brought current. When a surface
///   is picked for the next snapshot, only its stale rows are blitted, then cleared.
/// - "Cooling": when the last `RemoteFrame` for a surface is released, the render
///   server may still be scanning it out (the layer's replacement `contents` commits
///   at the end of the run-loop turn, and the compositor holds a use count until it
///   has switched). `IOSurface.isInUse` reports that cross-process hold, so such a
///   surface is parked and only returned to the free list once it reads false.
/// - Worst case (full-screen video: staleRows == full frame every paint) degrades to
///   one full-frame memcpy per paint — the same as before, minus CA's own copy.
///
/// Threading: `snapshot` runs on the RDP thread; `RemoteFrame` deinit (which recycles
/// surfaces) can fire on any thread — all shared state is guarded by `lock`, which
/// is never held while a surface is being blitted.
final class FrameSurfacePool {

    /// Inclusive-row dirty bounding box (full-width rows are blitted; tracking x would
    /// save little since rows are contiguous memcpys anyway).
    struct DirtyRows: Equatable {
        var minY: Int
        var maxY: Int   // inclusive; minY > maxY means empty

        static let empty = DirtyRows(minY: .max, maxY: -1)
        var isEmpty: Bool { minY > maxY }

        mutating func union(minY newMin: Int, maxY newMax: Int) {
            minY = Swift.min(minY, newMin)
            maxY = Swift.max(maxY, newMax)
        }
    }

    final class Surface {
        let io: IOSurface
        var staleRows: DirtyRows
        let generation: Int

        init(io: IOSurface, generation: Int) {
            self.io = io
            // A fresh surface lags by everything.
            self.staleRows = DirtyRows(minY: 0, maxY: .max)
            self.generation = generation
        }
    }

    private let lock = NSLock()
    private var free: [Surface] = []
    private var inUse: [Surface] = []
    /// Released by the app but still referenced by the compositor (see class docs).
    private var cooling: [Surface] = []
    private var width = 0, height = 0
    private var generation = 0
    /// 3 covers steady state (one on the layer, one pending, one being written);
    /// bursts beyond it allocate fresh surfaces that are dropped on release.
    private let maxPooled = 3
    /// Cap on parked surfaces so a compositor that holds on unusually long can't
    /// make the pool grow without bound (extras are simply dropped).
    private let maxCooling = 4

    var pooledSurfaceCount: Int {   // test hook
        lock.lock(); defer { lock.unlock() }
        return free.count
    }

    /// The FourCC 'BGRA' (== kCVPixelFormatType_32BGRA, without importing CoreVideo).
    private static let pixelFormatBGRA: UInt32 = 0x42475241

    private static func makeSurface(width: Int, height: Int) -> IOSurface? {
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let allocSize = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bytesPerRow * height)
        return IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .allocSize: allocSize,
            .pixelFormat: pixelFormatBGRA,
        ])
    }

    /// Blit the changed region and return an immutable full-frame snapshot.
    /// RDP thread only; `src` (the FULL framebuffer base) is valid only for this call.
    func snapshot(src: UnsafeRawPointer, dirtyY: Int, dirtyH: Int,
                  fullWidth: Int, fullHeight: Int, stride: Int) -> RemoteFrame? {
        guard fullWidth > 0, fullHeight > 0, stride >= fullWidth * 4,
              dirtyH > 0, dirtyY >= 0, dirtyY + dirtyH <= fullHeight else { return nil }

        lock.lock()
        if fullWidth != width || fullHeight != height {
            // Geometry changed (resize/re-resolution): old surfaces are the wrong size.
            // Bump the generation so in-flight releases drop them instead of pooling.
            generation += 1
            free.removeAll()
            cooling.removeAll()
            width = fullWidth; height = fullHeight
        }
        // Every surface — free, displayed, or cooling — now lags by this paint's rows too.
        for s in free    { s.staleRows.union(minY: dirtyY, maxY: dirtyY + dirtyH - 1) }
        for s in inUse   { s.staleRows.union(minY: dirtyY, maxY: dirtyY + dirtyH - 1) }
        for s in cooling { s.staleRows.union(minY: dirtyY, maxY: dirtyY + dirtyH - 1) }
        // Surfaces the compositor has let go of are usable again.
        sweepCoolingLocked()

        let surface: Surface
        if let reused = free.popLast() {
            surface = reused
        } else {
            guard let io = Self.makeSurface(width: fullWidth, height: fullHeight) else {
                lock.unlock()
                return nil
            }
            surface = Surface(io: io, generation: generation)
        }
        let rows = surface.staleRows
        surface.staleRows = .empty
        inUse.append(surface)
        lock.unlock()

        // Blit outside the pool lock (release callbacks must never wait on a blit).
        // The surface is in `inUse`, so nothing else touches its buffer.
        let firstRow = max(0, rows.minY)
        let lastRow = min(fullHeight - 1, rows.maxY)
        if firstRow <= lastRow {
            let io = surface.io
            let dstStride = io.bytesPerRow
            _ = io.lock(options: [], seed: nil)
            let dst = io.baseAddress
            if dstStride == stride {
                // Same layout: the row range is one contiguous copy.
                let offset = firstRow * stride
                memcpy(dst + offset, src + offset, (lastRow - firstRow + 1) * stride)
            } else {
                // IOSurface rows are alignment-padded: copy the pixel span of each row.
                let rowBytes = fullWidth * 4
                for row in firstRow...lastRow {
                    memcpy(dst + row * dstStride, src + row * stride, rowBytes)
                }
            }
            _ = io.unlock(options: [], seed: nil)
        }

        return RemoteFrame(surface: surface.io, width: fullWidth, height: fullHeight,
                           onRelease: { [self] io in self.recycle(io) })
    }

    private func recycle(_ io: IOSurface) {
        lock.lock()
        guard let idx = inUse.firstIndex(where: { $0.io === io }) else {
            lock.unlock()
            return
        }
        let surface = inUse.remove(at: idx)
        if surface.generation == generation {
            if surface.io.isInUse {
                // The compositor still references it — park until it lets go.
                if cooling.count < maxCooling { cooling.append(surface) }
            } else if free.count < maxPooled {
                free.append(surface)
            }
        }
        lock.unlock()
    }

    /// Move parked surfaces the compositor has released onto the free list (bounded by
    /// `maxPooled`; the rest are dropped). Caller holds `lock`.
    private func sweepCoolingLocked() {
        guard !cooling.isEmpty else { return }
        var stillCooling: [Surface] = []
        for s in cooling {
            if s.io.isInUse {
                stillCooling.append(s)
            } else if free.count < maxPooled {
                free.append(s)
            }
        }
        cooling = stillCooling
    }
}
