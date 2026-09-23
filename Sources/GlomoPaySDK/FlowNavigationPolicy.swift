import Foundation

/// Scheme allowlist for the bank/3DS flow WebView.
///
/// The main WebView is deliberately not filtered: it only ever loads GlomoPay's own checkout
/// document, so the allowlist belongs on the flow WebView, where the bank decides where to
/// navigate next.
///
/// WKWebView does not hand unknown schemes to the system - only an explicit
/// `UIApplication.open(_:)` does - so a `upi://` or `intent://` navigation fails quietly and
/// leaves the user on a bank page that appears to have done nothing. Blocking it explicitly is
/// what Flutter does, and it makes the outcome observable instead of silent. Whether iOS should
/// additionally open such URLs in the system is a separate product decision.
enum FlowNavigationPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "about", "blob", "data"]

    static func allows(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Reported as the `scheme` property on the blocked-navigation analytics event.
    static func scheme(of url: URL?) -> String {
        url?.scheme?.lowercased() ?? "none"
    }
}
