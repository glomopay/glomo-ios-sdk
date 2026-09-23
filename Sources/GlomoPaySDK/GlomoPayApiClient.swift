import Foundation

public protocol GlomoPayHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GlomoPayHTTPClient {}

/// Order-fetch failures, one case per cause, because each one reports a different fault:
/// a phone with no signal and a backend returning 500 must not reach the host identically.
///
/// No case carries the response body. The body was retained here, never read, and travelled
/// up as `localizedDescription` into analytics and Sentry - an order payload leaving the
/// device. Status code only.
public enum GlomoPayAPIError: Error, LocalizedError, Equatable {
    case invalidOrderURL
    /// The request timed out before the backend answered.
    case requestTimeout
    /// The request never reached the backend. `code` is the `NSURLError` code.
    case transport(code: Int)
    /// The backend answered with a non-2xx status, so connectivity is fine.
    case failedToLoadOrder(statusCode: Int)
    /// The backend answered with something this client cannot parse: a broken contract
    /// between the SDK and its own backend.
    case invalidOrderResponse

    public var errorDescription: String? {
        switch self {
        case .invalidOrderURL:
            return "Unable to build order URL"
        case .requestTimeout:
            return "Order request timed out"
        case let .transport(code):
            return "Unable to reach the order service (\(code))"
        case let .failedToLoadOrder(statusCode):
            return "Failed to load order. Status: \(statusCode)"
        case .invalidOrderResponse:
            return "Order response was not a JSON object"
        }
    }
}

/// API client used for Flutter-compatible order type detection before checkout.
public final class GlomoPayApiClient {
    public static let defaultBaseURL = URL(string: "https://api.glomopay.com")!

    /// Exposed so the checkout-open watchdog can be derived from it instead of hard-coded.
    static let requestTimeout: TimeInterval = 15

    private let publicKey: String
    private let baseURL: URL
    private let client: GlomoPayHTTPClient

    public init(
        publicKey: String,
        baseURL: URL = GlomoPayApiClient.defaultBaseURL,
        client: GlomoPayHTTPClient = URLSession.shared
    ) {
        self.publicKey = publicKey
        self.baseURL = baseURL
        self.client = client
    }

    public func fetchOrder(_ orderId: String) async throws -> [String: Any] {
        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("public")
            .appendingPathComponent("v1")
            .appendingPathComponent("order")
            .appendingPathComponent(orderId)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await client.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            // Any 2xx is the backend answering. A 2xx body this client cannot parse is a
            // malformed response, not a status fault.
            guard (200..<300).contains(statusCode) else {
                throw GlomoPayAPIError.failedToLoadOrder(statusCode: statusCode)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                throw GlomoPayAPIError.invalidOrderResponse
            }
            return dictionary
        } catch let error as GlomoPayAPIError {
            // The typed case travels as-is: the caller decides which callback it reports through.
            GlomoPayLogger.error("Order fetch failed", error: error)
            throw error
        } catch {
            let transportError = Self.transportError(from: error)
            GlomoPayLogger.error("Order fetch failed", error: transportError)
            throw transportError
        }
    }

    private static func transportError(from error: Error) -> GlomoPayAPIError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .transport(code: nsError.code)
        }
        return nsError.code == NSURLErrorTimedOut ? .requestTimeout : .transport(code: nsError.code)
    }
}
