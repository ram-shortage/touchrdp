import Foundation
import CoreGraphics

/// Conversion between a `CGImage` and a Windows clipboard device-independent bitmap
/// (CF_DIB / CF_DIBV5 payload — a `BITMAP*INFOHEADER` followed by pixel data, with NO
/// `BITMAPFILEHEADER`). The C bridge shuttles these bytes verbatim over cliprdr; all
/// pixel-format knowledge lives here so the bridge stays a dumb byte pipe.
///
/// Outbound (Mac → Windows) we emit the most broadly pasteable form: 24-bit BGR,
/// bottom-up, BI_RGB. Inbound (Windows → Mac) we accept 24/32-bit BI_RGB and 32-bit
/// BI_BITFIELDS, top-down or bottom-up, and any header size ≥ 40 (V1/V4/V5). Images are
/// decoded as opaque (alpha ignored) — clipboard bitmaps are screenshots/photos, and
/// honoring a possibly-undefined alpha channel is the classic source of all-black pastes.
enum ClipboardImageDIB {

    // BITMAPINFOHEADER compression modes we understand.
    private static let BI_RGB: UInt32 = 0
    private static let BI_BITFIELDS: UInt32 = 3

    // Hard ceiling mirrored on the C side (rdpbridge.c CLIP_MAX_IMAGE_BYTES). Rejecting
    // oversized payloads here too bounds memory before we ever allocate a pixel buffer.
    static let maxBytes = 64 * 1024 * 1024

    // MARK: - Encode (CGImage → CF_DIB)

    /// Render `image` to a 24-bit, bottom-up, BI_RGB DIB. Returns nil on failure or if the
    /// result would exceed `maxBytes`.
    static func dib(from image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        // Draw into a known RGBA8 buffer so we don't have to handle every CGImage layout.
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let srcRowBytes = width * 4
        var rgba = [UInt8](repeating: 0, count: srcRowBytes * height)
        let drew: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: srcRowBytes, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        // 24-bit rows are padded to a 4-byte boundary.
        let dstRowBytes = ((width * 3) + 3) & ~3
        let pixelBytes = dstRowBytes * height
        let headerSize = 40
        guard headerSize + pixelBytes <= maxBytes else { return nil }

        var out = Data(capacity: headerSize + pixelBytes)
        // BITMAPINFOHEADER (all little-endian).
        appendLE32(&out, UInt32(headerSize))            // biSize
        appendLE32(&out, UInt32(bitPattern: Int32(width)))   // biWidth
        appendLE32(&out, UInt32(bitPattern: Int32(height)))  // biHeight (+ = bottom-up)
        appendLE16(&out, 1)                             // biPlanes
        appendLE16(&out, 24)                            // biBitCount
        appendLE32(&out, BI_RGB)                        // biCompression
        appendLE32(&out, UInt32(pixelBytes))           // biSizeImage
        appendLE32(&out, 2835)                          // biXPelsPerMeter (~72 dpi)
        appendLE32(&out, 2835)                          // biYPelsPerMeter
        appendLE32(&out, 0)                             // biClrUsed
        appendLE32(&out, 0)                             // biClrImportant

        var row = [UInt8](repeating: 0, count: dstRowBytes)
        rgba.withUnsafeBytes { src in
            for dibRow in 0..<height {
                // Bottom-up: first DIB row is the bottom scanline of the image. The RGBA
                // buffer is top-row-first, so the bottom scanline is the last buffer row.
                let srcRow = (height - 1 - dibRow) * srcRowBytes
                var d = 0
                var s = srcRow
                for _ in 0..<width {
                    let r = src[s + 0], g = src[s + 1], b = src[s + 2]
                    row[d + 0] = b; row[d + 1] = g; row[d + 2] = r   // BGR
                    d += 3; s += 4
                }
                // Pad bytes (d..<dstRowBytes) are already zero from the initial fill.
                while d < dstRowBytes { row[d] = 0; d += 1 }
                out.append(contentsOf: row)
            }
        }
        return out
    }

    // MARK: - Decode (CF_DIB → CGImage)

    /// Parse a CF_DIB / CF_DIBV5 payload into an opaque CGImage. Returns nil for formats
    /// we don't handle (palettized, exotic compression) or malformed data.
    static func cgImage(fromDIB data: Data) -> CGImage? {
        guard data.count >= 40, data.count <= maxBytes else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> CGImage? in
            let base = raw.bindMemory(to: UInt8.self)
            func u32(_ off: Int) -> UInt32 {
                UInt32(base[off]) | (UInt32(base[off+1]) << 8)
                    | (UInt32(base[off+2]) << 16) | (UInt32(base[off+3]) << 24)
            }
            func i32(_ off: Int) -> Int32 { Int32(bitPattern: u32(off)) }
            func u16(_ off: Int) -> UInt16 { UInt16(base[off]) | (UInt16(base[off+1]) << 8) }

            let headerSize = Int(u32(0))
            guard headerSize >= 40, headerSize <= data.count else { return nil }
            let width = Int(i32(4))
            let rawHeight = Int(i32(8))
            let bitCount = Int(u16(14))
            let compression = u32(16)
            let clrUsed = Int(u32(32))
            guard width > 0, rawHeight != 0, width <= 32768 else { return nil }
            let topDown = rawHeight < 0
            let height = abs(rawHeight)
            guard height <= 32768 else { return nil }
            guard bitCount == 24 || bitCount == 32 else { return nil }            // no palettes
            guard compression == BI_RGB || (compression == BI_BITFIELDS && bitCount == 32)
            else { return nil }

            // Pixel data offset: header, then any BI_BITFIELDS masks (V1 only — V4/V5 fold
            // them into the header), then any palette (absent for 24/32-bit, but honor
            // biClrUsed defensively).
            var pixelOffset = headerSize
            if compression == BI_BITFIELDS && headerSize == 40 { pixelOffset += 12 }
            pixelOffset += clrUsed * 4
            guard pixelOffset <= data.count else { return nil }

            let srcRowBytes = ((width * bitCount + 31) / 32) * 4
            guard pixelOffset + srcRowBytes * height <= data.count else { return nil }

            // Output: opaque RGBA, top-row-first (the layout CGImage expects).
            let dstRowBytes = width * 4
            var out = [UInt8](repeating: 0, count: dstRowBytes * height)
            let bytesPerPixel = bitCount / 8
            for y in 0..<height {
                let srcRowIndex = topDown ? y : (height - 1 - y)
                var s = pixelOffset + srcRowIndex * srcRowBytes
                var d = y * dstRowBytes
                for _ in 0..<width {
                    let b = base[s + 0], g = base[s + 1], r = base[s + 2]
                    out[d + 0] = r; out[d + 1] = g; out[d + 2] = b; out[d + 3] = 255
                    s += bytesPerPixel; d += 4
                }
            }

            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: dstRowBytes, space: cs, bitmapInfo: info,
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)
        }
    }

    // MARK: - LE helpers

    private static func appendLE16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }
}
