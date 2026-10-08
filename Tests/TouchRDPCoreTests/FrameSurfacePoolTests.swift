import XCTest
import CoreGraphics
import IOSurface
import TouchRDPCore
@testable import TouchRDPEngine

/// PERF-1/PERF-5: the pooled zero-copy frame snapshots must behave exactly like the
/// old per-paint full copies from the outside — immutable while displayed, always
/// depicting the full current framebuffer — while only blitting the rows a surface
/// is stale by. The surfaces are IOSurfaces whose rows may be alignment-padded, so
/// every pixel read goes through the frame's own `bytesPerRow`.
final class FrameSurfacePoolTests: XCTestCase {

    private let w = 4, h = 4, stride = 16   // 4×4 BGRA source
    private var src = [UInt8]()

    override func setUp() {
        super.setUp()
        src = [UInt8](repeating: 0x11, count: stride * h)
    }

    private func fillRow(_ row: Int, _ value: UInt8) {
        for i in 0..<stride { src[row * stride + i] = value }
    }

    private func snap(_ pool: FrameSurfacePool, dirtyY: Int, dirtyH: Int) -> RemoteFrame? {
        src.withUnsafeBytes { buf in
            pool.snapshot(src: buf.baseAddress!, dirtyY: dirtyY, dirtyH: dirtyH,
                          fullWidth: w, fullHeight: h, stride: stride)
        }
    }

    /// First byte of `row` straight out of the surface.
    private func rowByte(_ frame: RemoteFrame, _ row: Int) -> UInt8 {
        let io = frame.surface
        _ = io.lock(options: .readOnly, seed: nil)
        defer { _ = io.unlock(options: .readOnly, seed: nil) }
        return io.baseAddress.load(fromByteOffset: row * io.bytesPerRow, as: UInt8.self)
    }

    func testFirstSnapshotIsFullFrame() {
        let pool = FrameSurfacePool()
        let frame = snap(pool, dirtyY: 0, dirtyH: h)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.width, w)
        XCTAssertEqual(frame?.height, h)
        for row in 0..<h { XCTAssertEqual(rowByte(frame!, row), 0x11) }
    }

    /// The surface is a real BGRA IOSurface of the frame's geometry — the property
    /// Core Animation relies on when it's handed over as layer contents.
    func testSurfaceGeometryMatchesFrame() {
        let pool = FrameSurfacePool()
        let frame = snap(pool, dirtyY: 0, dirtyH: h)!
        XCTAssertEqual(frame.surface.width, w)
        XCTAssertEqual(frame.surface.height, h)
        XCTAssertEqual(frame.surface.bytesPerElement, 4)
        XCTAssertGreaterThanOrEqual(frame.surface.bytesPerRow, w * 4)
        XCTAssertEqual(frame.surface.pixelFormat, 0x42475241, "'BGRA'")
    }

    /// A held frame must keep its pixels while later paints land elsewhere, and the
    /// later snapshot must show the full merged state.
    func testHeldFrameIsImmutableAndNewSnapshotIsCurrent() {
        let pool = FrameSurfacePool()
        let f1 = snap(pool, dirtyY: 0, dirtyH: h)!

        fillRow(0, 0x22); fillRow(1, 0x22)
        let f2 = snap(pool, dirtyY: 0, dirtyH: 2)!

        XCTAssertFalse(f1.surface === f2.surface, "a held surface was handed out again")
        XCTAssertEqual(rowByte(f1, 0), 0x11, "displayed snapshot mutated by a later paint")
        XCTAssertEqual(rowByte(f2, 0), 0x22)
        XCTAssertEqual(rowByte(f2, 1), 0x22)
        XCTAssertEqual(rowByte(f2, 2), 0x11, "undirtied rows must carry forward")
    }

    /// A surface recycled after sitting out several paints must be brought current for
    /// everything it missed, not just the newest dirty rect.
    func testStaleAccumulationAcrossRecycles() {
        let pool = FrameSurfacePool()
        var f1: RemoteFrame? = snap(pool, dirtyY: 0, dirtyH: h)   // surface A

        fillRow(0, 0x22); fillRow(1, 0x22)
        var f2: RemoteFrame? = snap(pool, dirtyY: 0, dirtyH: 2)   // surface B (A in use)

        f1 = nil                                                  // A pooled; missed rows 0-1
        _ = f1

        fillRow(3, 0x33)
        let f3 = snap(pool, dirtyY: 3, dirtyH: 1)!                // reuses A
        XCTAssertEqual(rowByte(f3, 0), 0x22, "recycled surface missed an earlier paint")
        XCTAssertEqual(rowByte(f3, 1), 0x22)
        XCTAssertEqual(rowByte(f3, 2), 0x11)
        XCTAssertEqual(rowByte(f3, 3), 0x33)

        f2 = nil
        _ = f2
    }

    /// White-box: a surface with an empty stale box must blit ONLY the declared dirty
    /// rows — an undeclared source mutation (which the contract forbids) is the probe
    /// that proves the partial copy.
    func testOnlyStaleRowsAreBlitted() {
        let pool = FrameSurfacePool()
        var warm: RemoteFrame? = snap(pool, dirtyY: 0, dirtyH: h)
        warm = nil                                                // pooled, stale empty
        _ = warm

        fillRow(2, 0x44)                                          // NOT declared dirty
        fillRow(0, 0x55)
        let frame = snap(pool, dirtyY: 0, dirtyH: 1)!             // declares row 0 only
        XCTAssertEqual(rowByte(frame, 0), 0x55)
        XCTAssertEqual(rowByte(frame, 2), 0x11,
                       "row 2 was blitted despite being neither dirty nor stale")
    }

    func testGeometryChangeDropsPooledSurfaces() {
        let pool = FrameSurfacePool()
        var frame: RemoteFrame? = snap(pool, dirtyY: 0, dirtyH: h)
        frame = nil
        _ = frame
        XCTAssertEqual(pool.pooledSurfaceCount, 1)

        // Different width ⇒ old surfaces unusable.
        let wide = [UInt8](repeating: 0x77, count: 32 * h)
        let f2 = wide.withUnsafeBytes { buf in
            pool.snapshot(src: buf.baseAddress!, dirtyY: 0, dirtyH: h,
                          fullWidth: 8, fullHeight: h, stride: 32)
        }
        XCTAssertNotNil(f2)
        XCTAssertEqual(pool.pooledSurfaceCount, 0)
        XCTAssertEqual(f2!.surface.width, 8)
        XCTAssertEqual(rowByte(f2!, 0), 0x77)
    }

    func testSurfacesAreReusedNotReallocated() {
        let pool = FrameSurfacePool()
        for _ in 0..<10 {
            var frame: RemoteFrame? = snap(pool, dirtyY: 0, dirtyH: 1)
            frame = nil
            _ = frame
        }
        XCTAssertLessThanOrEqual(pool.pooledSurfaceCount, 1,
                                 "serial snapshot/release should cycle one surface")
    }

    func testRejectsOutOfRangeDirtyRect() {
        let pool = FrameSurfacePool()
        XCTAssertNil(snap(pool, dirtyY: 0, dirtyH: 0))
        XCTAssertNil(snap(pool, dirtyY: 3, dirtyH: 2))
        XCTAssertNil(snap(pool, dirtyY: -1, dirtyH: 2))
    }

    /// The screenshot path copies out of the surface into an independent CGImage with
    /// the frame's geometry and pixels.
    func testMakeCGImageCopiesPixels() {
        let pool = FrameSurfacePool()
        fillRow(1, 0x99)
        let frame = snap(pool, dirtyY: 0, dirtyH: h)!
        let cg = frame.makeCGImage()
        XCTAssertNotNil(cg)
        XCTAssertEqual(cg?.width, w)
        XCTAssertEqual(cg?.height, h)
        XCTAssertEqual(cg?.bytesPerRow, frame.bytesPerRow)
        let data = cg!.dataProvider!.data! as Data
        XCTAssertEqual(data[0], 0x11)
        XCTAssertEqual(data[frame.bytesPerRow], 0x99)
    }
}
