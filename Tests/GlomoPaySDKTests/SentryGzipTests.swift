import XCTest
@testable import GlomoPaySDK

/// Golden checks that the SDK's hand-framed gzip is real gzip: standard decoders accept it and
/// the trailer matches published CRC-32 check values.
final class SentryGzipTests: XCTestCase {
    private let sample = Data("""
        {"event_id":"0123456789abcdef0123456789abcdef","sent_at":"2026-09-29T11:00:00.000Z"}
        {"type":"event","length":64,"content_type":"application/json"}
        {"message":{"formatted":"₹1,000 भुगतान failed"},"level":"error","tags":{"a":"b"}}
        """.utf8)

    func testCRC32MatchesThePublishedCheckValues() {
        // The standard CRC-32 check value for "123456789", and the empty string.
        XCTAssertEqual(SentryGzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(SentryGzip.crc32(Data()), 0)
    }

    func testHeaderAndTrailerFollowRFC1952() throws {
        let input = Data("123456789".utf8)
        let gzip = try XCTUnwrap(SentryGzip.compress(input))
        let bytes = [UInt8](gzip)

        XCTAssertEqual(Array(bytes.prefix(10)), [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        // CRC-32 0xCBF43926 then ISIZE 9, both little-endian.
        XCTAssertEqual(Array(bytes.suffix(8)), [0x26, 0x39, 0xF4, 0xCB, 0x09, 0x00, 0x00, 0x00])
    }

    func testOutputDecodesWithFoundationInflate() throws {
        let gzip = try XCTUnwrap(SentryGzip.compress(sample))

        XCTAssertEqual(SentryWire.gunzip(gzip), sample)
        XCTAssertNil(SentryWire.gunzip(gzip.dropLast()), "a truncated stream must not decode")
    }

    #if os(macOS)
    /// The system `gzip` binary is a decoder the SDK has no hand in.
    func testOutputDecodesWithTheSystemGzipTool() throws {
        let gzip = try XCTUnwrap(SentryGzip.compress(sample))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(gzip)
        try input.fileHandleForWriting.close()
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(decoded, sample)
    }
    #endif

    func testEmptyInputIsNotCompressed() {
        XCTAssertNil(SentryGzip.compress(Data()))
    }
}
