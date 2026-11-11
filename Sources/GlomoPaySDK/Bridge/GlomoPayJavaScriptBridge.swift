#if canImport(WebKit)
import WebKit

/// Who sent a bridge message, as WebKit attributes it.
///
/// Carried alongside the body rather than derived later: `WKScriptMessage.frameInfo` is the only
/// authoritative answer, it is gone the moment the message is handed on, and the WebView's own URL
/// is not a substitute — that is the top-level document's, which says nothing about a subframe.
struct BridgeMessageSender {
    /// `scheme://host[:port]`, or nil when the frame has no http(s) origin.
    let origin: String?

    /// False for anything sent from an iframe, including one embedded in a GlomoPay page.
    let isMainFrame: Bool
}

final class GlomoPayJavaScriptBridge: NSObject, WKScriptMessageHandler {
    private let onMessage: (Any, BridgeMessageSender) -> Void

    init(onMessage: @escaping (Any, BridgeMessageSender) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let sender = BridgeMessageSender(
            origin: TrustedOrigin.origin(of: message.frameInfo.securityOrigin),
            isMainFrame: message.frameInfo.isMainFrame
        )
        onMessage(message.body, sender)
    }
}
#endif
