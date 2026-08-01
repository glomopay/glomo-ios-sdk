#if canImport(WebKit)
import WebKit

final class GlomoPayJavaScriptBridge: NSObject, WKScriptMessageHandler {
    private let onMessage: (Any) -> Void

    init(onMessage: @escaping (Any) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}
#endif
