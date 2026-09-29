import Foundation

/// gzip (RFC 1952) for the envelope HTTP body, with no dependency beyond Foundation.
///
/// Foundation has no gzip encoder, but `NSData.compressed(using: .zlib)` (iOS 13+, macOS 10.15+)
/// produces a raw DEFLATE stream (RFC 1951). gzip is that stream framed by a fixed 10-byte header
/// and an 8-byte trailer of CRC-32 and the uncompressed size, both little-endian.
enum SentryGzip {
    /// Returns nil if compression fails; the caller then sends the body uncompressed.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty, let deflated = try? (data as NSData).compressed(using: .zlib) as Data else {
            return nil
        }
        // ID1 ID2, CM = deflate, FLG = none, MTIME = 0, XFL = 0, OS = 255 (unknown).
        var gzip = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        gzip.reserveCapacity(gzip.count + deflated.count + 8)
        gzip.append(deflated)
        appendLittleEndian(crc32(data), to: &gzip)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &gzip)
        return gzip
    }

    /// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as gzip requires.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
