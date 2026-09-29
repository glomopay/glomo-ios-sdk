import Foundation

/// A parsed Sentry DSN.
///
/// Everything the ingestion endpoint needs is derived from the DSN at runtime: scheme, host,
/// optional port, optional path prefix, project id and public key. No host or region is
/// hard-coded, so the same code works against `sentry.io`, a regional ingest host, or a
/// self-hosted Sentry behind a path prefix.
struct SentryDSN: Equatable {
    /// The DSN as configured, trimmed. Sent as `dsn` in the envelope header.
    let value: String
    /// `{scheme}://{host}[:port]/{path}api/{projectId}/envelope/`
    let envelopeURL: URL
    let publicKey: String
    /// Legacy DSN secret; sent as `sentry_secret` only when the DSN carries one.
    let secretKey: String?
    let projectID: String

    /// Returns nil for anything unusable. Never throws: a blank or malformed DSN must quietly
    /// disable error reporting rather than reach a merchant's checkout.
    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty,
            let publicKey = components.user, !publicKey.isEmpty
        else {
            return nil
        }

        var segments = components.path.split(separator: "/").map(String.init)
        guard let projectID = segments.popLast(), !projectID.isEmpty else { return nil }
        let prefix = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")

        var endpoint = URLComponents()
        endpoint.scheme = scheme
        endpoint.host = host
        endpoint.port = components.port
        endpoint.path = "\(prefix)/api/\(projectID)/envelope/"
        guard let envelopeURL = endpoint.url else { return nil }

        self.value = trimmed
        self.envelopeURL = envelopeURL
        self.publicKey = publicKey
        self.secretKey = components.password.flatMap { $0.isEmpty ? nil : $0 }
        self.projectID = projectID
    }

    /// The `X-Sentry-Auth` header value.
    func authHeader(client: String) -> String {
        var header = "Sentry sentry_version=7, sentry_client=\(client), sentry_key=\(publicKey)"
        if let secretKey {
            header += ", sentry_secret=\(secretKey)"
        }
        return header
    }
}
