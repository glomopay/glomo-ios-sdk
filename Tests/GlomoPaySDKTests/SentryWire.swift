import Foundation
import XCTest
@testable import GlomoPaySDK

/// A fake Sentry ingest host at the `URLSession` boundary.
///
/// Requests are intercepted by a `URLProtocol` registered on the client's own session
/// configuration, so the client's real request building, encoding and response handling all
/// run; only the socket is replaced. Assertions are made on the bytes that would have left the
/// device. Each wire owns a unique host, so a request still in flight from one test can never
/// land in another, and an unknown host fails instead of reaching the real network.
final class SentryWire: @unchecked Sendable {
    enum Reply {
        case status(Int, headers: [String: String] = [:])
        case failure(URLError.Code)
        /// Held until `release()`; used to keep a send in flight.
        case held
    }

    struct Captured {
        let request: URLRequest
        /// The envelope: the HTTP body after undoing its `Content-Encoding`.
        let body: Data
        /// The bytes actually sent.
        let wireBody: Data

        var lines: [Data] {
            body.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        }

        var bodyText: String { String(decoding: body, as: UTF8.self) }

        func envelopeHeader() throws -> [String: Any] { try json(line: 0) }
        func itemHeader() throws -> [String: Any] { try json(line: 1) }
        func event() throws -> [String: Any] { try json(line: 2) }

        private func json(line index: Int) throws -> [String: Any] {
            let lines = self.lines
            guard lines.indices.contains(index) else {
                throw NSError(domain: "SentryWire", code: 1, userInfo: [NSLocalizedDescriptionKey: "No line \(index)"])
            }
            let object = try JSONSerialization.jsonObject(with: lines[index])
            return try XCTUnwrap(object as? [String: Any])
        }
    }

    static let publicKey = "fakepublickey0123456789"
    static let projectID = "4501111111111111"

    let host: String
    private let lock = NSLock()
    private var scripted: [Reply] = []
    private var defaultReply: Reply = .status(200)
    private var captured: [Captured] = []
    private var heldProtocols: [SentryWireProtocol] = []
    private var released = false

    init(hostPrefix: String = "o4500000000000000.ingest") {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        host = "\(hostPrefix).\(unique).test"
        Self.register(self)
    }

    /// Intercepts a real host, so a client built from real configuration never reaches it.
    init(exactHost: String) {
        host = exactHost.lowercased()
        Self.register(self)
    }

    deinit {
        Self.unregister(host)
    }

    var dsn: String { "https://\(Self.publicKey)@\(host)/\(Self.projectID)" }

    var requests: [Captured] { lock.glomoWithLock { captured } }

    /// Replies used in order for the next requests; afterwards `defaultReply` applies.
    func script(_ replies: Reply...) {
        lock.glomoWithLock { scripted.append(contentsOf: replies) }
    }

    func replyToEverything(_ reply: Reply) {
        lock.glomoWithLock { defaultReply = reply }
    }

    /// Answers every held request, and any later one, with 200.
    func release() {
        let pending: [SentryWireProtocol] = lock.glomoWithLock {
            released = true
            defer { heldProtocols.removeAll() }
            return heldProtocols
        }
        pending.forEach { $0.respond(.status(200)) }
    }

    func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = SentryEnvelopeClient.defaultSessionConfiguration()
        configuration.protocolClasses = [SentryWireProtocol.self]
        return configuration
    }

    func makeClient(
        dsn: String? = nil,
        now: @escaping () -> Date = Date.init,
        infoDictionary: [String: Any]? = nil
    ) throws -> SentryEnvelopeClient {
        try XCTUnwrap(
            SentryEnvelopeClient(
                dsn: dsn ?? self.dsn,
                sessionConfiguration: sessionConfiguration(),
                now: now,
                infoDictionary: infoDictionary
            )
        )
    }

    fileprivate func receive(_ request: URLRequest, body: Data, via protocolInstance: SentryWireProtocol) -> Reply? {
        lock.glomoWithLock {
            let decoded = request.value(forHTTPHeaderField: "Content-Encoding") == "gzip"
                ? (Self.gunzip(body) ?? Data())
                : body
            captured.append(Captured(request: request, body: decoded, wireBody: body))
            let reply = scripted.isEmpty ? defaultReply : scripted.removeFirst()
            if case .held = reply {
                if released { return .status(200) }
                heldProtocols.append(protocolInstance)
                return nil
            }
            return reply
        }
    }

    // MARK: gzip

    /// Test-side gzip decoder, independent of the SDK's encoder: checks the RFC 1952 header,
    /// inflates the DEFLATE stream with Foundation, and verifies the trailer's CRC-32 (computed
    /// bit by bit here) and size. Returns nil for anything that is not valid gzip.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08, bytes[3] == 0x00 else {
            return nil
        }
        let deflated = Data(bytes[10..<(bytes.count - 8)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else { return nil }
        let trailer = Array(bytes[(bytes.count - 8)...])
        let crc = trailer[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let size = trailer[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        guard size == UInt32(truncatingIfNeeded: inflated.count), crc == bitwiseCRC32(inflated) else { return nil }
        return inflated
    }

    static func bitwiseCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }

    // MARK: Registry

    private static let registryLock = NSLock()
    private static var registry: [String: WeakWire] = [:]

    private struct WeakWire {
        weak var wire: SentryWire?
    }

    private static func register(_ wire: SentryWire) {
        registryLock.glomoWithLock { registry[wire.host] = WeakWire(wire: wire) }
    }

    private static func unregister(_ host: String) {
        registryLock.glomoWithLock { registry[host] = nil }
    }

    fileprivate static func wire(for request: URLRequest) -> SentryWire? {
        guard let host = request.url?.host else { return nil }
        return registryLock.glomoWithLock { registry[host]?.wire }
    }
}

final class SentryWireProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let wire = SentryWire.wire(for: request) else {
            respond(.failure(.cannotFindHost))
            return
        }
        if let reply = wire.receive(request, body: Self.body(of: request), via: self) {
            respond(reply)
        }
    }

    override func stopLoading() {}

    func respond(_ reply: SentryWire.Reply) {
        switch reply {
        case let .status(code, headers):
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .held:
            break
        }
    }

    /// `URLSession` moves `httpBody` into `httpBodyStream` before a protocol sees the request.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A clock a test can move forward, for rate-limit windows.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date { lock.glomoWithLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.glomoWithLock { current = current.addingTimeInterval(seconds) }
    }
}
