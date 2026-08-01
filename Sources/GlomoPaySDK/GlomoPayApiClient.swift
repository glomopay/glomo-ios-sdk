import Foundation

public protocol GlomoPayHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GlomoPayHTTPClient {}

public enum GlomoPayAPIError: Error, LocalizedError, Equatable {
    case invalidOrderURL
    case failedToLoadOrder(statusCode: Int, body: String)
    case invalidOrderResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOrderURL:
            return "Unable to build order URL"
        case let .failedToLoadOrder(statusCode, body):
            return "Failed to load order. Status: \(statusCode), Body: \(body)"
        case .invalidOrderResponse:
            return "Order response was not a JSON object"
        case let .network(message):
            return "Network error fetching order: \(message)"
        }
    }
}

/// API client used for Flutter-compatible order type detection before checkout.
public final class GlomoPayApiClient {
    public static let defaultBaseURL = URL(string: "https://api.glomopay.com")!

    private let publicKey: String
    private let devMode: Bool
    private let baseURL: URL
    private let client: GlomoPayHTTPClient

    public init(
        publicKey: String,
        devMode: Bool = false,
        baseURL: URL = GlomoPayApiClient.defaultBaseURL,
        client: GlomoPayHTTPClient = URLSession.shared
    ) {
        self.publicKey = publicKey
        self.devMode = devMode
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
        request.timeoutInterval = 15
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await client.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""

            guard statusCode == 200 else {
                throw GlomoPayAPIError.failedToLoadOrder(statusCode: statusCode, body: body)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GlomoPayAPIError.invalidOrderResponse
            }
            return object
        } catch let error as GlomoPayAPIError {
            if devMode { print("[GlomoPay API] \(error.localizedDescription)") }
            throw wrap(error)
        } catch {
            let networkError = GlomoPayAPIError.network(error.localizedDescription)
            if devMode { print("[GlomoPay API] \(networkError.localizedDescription)") }
            throw networkError
        }
    }

    private func wrap(_ error: GlomoPayAPIError) -> GlomoPayAPIError {
        switch error {
        case let .failedToLoadOrder(statusCode, body):
            return .network(GlomoPayAPIError.failedToLoadOrder(statusCode: statusCode, body: body).localizedDescription)
        case .invalidOrderResponse:
            return .network(error.localizedDescription)
        case .invalidOrderURL:
            return .network(error.localizedDescription)
        case .network:
            return error
        }
    }
}
