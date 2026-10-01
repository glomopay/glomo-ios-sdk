#if canImport(UIKit) && canImport(WebKit)
import WebKit
import XCTest
@testable import GlomoPaySDK

/// The carousel listener running in a real WKWebView, wired the way the checkout wires it: the
/// production user script at document start and the production message handler, registered
/// before the page loads. Pages post exactly as the hosted carousel does
/// (`window.parent.postMessage({ type, value }, '*')`, glomopay-checkout
/// `lrs-carousel.event-emitter.ts:5`). Runs on the iOS-simulator job only.
@MainActor
final class CarouselBridgeDeliveryTests: XCTestCase {
    private var webView: WKWebView?
    private var navigation: NavigationRecorder?

    override func tearDown() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        navigation = nil
        super.tearDown()
    }

    func testTheLiveSignalPostedFromThePagesFirstScriptReachesNative() throws {
        // Posted from the first inline <head> script, before the document has even parsed: the
        // earliest a page can send it.
        let received = try load(head: """
            window.parent.postMessage({ type: 'lrs.has_education_steps', value: true }, '*');
            """)

        XCTAssertEqual(received.count, 1)
        let message = try XCTUnwrap(received.first as? String)
        XCTAssertTrue(EducationCarouselContract.isContentSignal(rawMessage: message))
    }

    func testOnlyTheContentSignalIsForwarded() throws {
        // Every non-signal first, then the signal, so by the time the signal arrives the others
        // have been through the listener too.
        let received = try load(head: """
            window.parent.postMessage({ type: 'lrs.has_education_steps', value: false }, '*');
            window.parent.postMessage({ event: 'lrs.has_education_steps', hasContent: true }, '*');
            window.parent.postMessage({ type: 'lrs.has_education_steps', value: 'true' }, '*');
            window.parent.postMessage('{not json', '*');
            window.parent.postMessage({ type: 'lrs.has_education_steps', value: true }, '*');
            """)

        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(EducationCarouselContract.isContentSignal(rawMessage: try XCTUnwrap(received.first as? String)))
    }

    func testAPageThatNeverSignalsForwardsNothing() throws {
        // Lots of content but no signal: there is no DOM heuristic any more, so it stays hidden.
        let body = String(repeating: "<p>Lots of rendered text that used to trip the fallback.</p>", count: 40)
        let received = try load(
            head: """
                window.parent.postMessage({ type: 'lrs.has_education_steps', value: false }, '*');
                window.parent.postMessage({ event: 'lrs.has_education_steps', hasContent: true }, '*');
                """,
            body: body,
            expectingSignal: false
        )

        XCTAssertEqual(received.count, 0)
    }

    // MARK: Helpers

    /// Loads a page with the production carousel script and bridge, and returns what the native
    /// handler received. With `expectingSignal`, it waits for the first message; otherwise for the
    /// page to finish. Either way it then drains the run loop briefly to catch anything extra.
    private func load(head script: String, body: String = "", expectingSignal: Bool = true) throws -> [Any] {
        let box = MessageBox()
        let firstMessage = expectation(description: "native received the signal")
        firstMessage.assertForOverFulfill = false
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.carousel(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.add(GlomoPayJavaScriptBridge { body in
            box.append(body)
            firstMessage.fulfill()
        }, name: "GlomoCarouselBridge")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 120), configuration: configuration)
        let finished = expectation(description: "page finished")
        let navigation = NavigationRecorder { finished.fulfill() }
        webView.navigationDelegate = navigation
        self.webView = webView
        self.navigation = navigation

        webView.loadHTMLString(
            "<!doctype html><html><head><script>\(script)</script></head><body>\(body)</body></html>",
            baseURL: URL(string: "https://carousel.example.test/")
        )
        wait(for: expectingSignal ? [firstMessage, finished] : [finished], timeout: 30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return box.messages
    }
}

private final class MessageBox {
    private(set) var messages: [Any] = []
    func append(_ message: Any) { messages.append(message) }
}

private final class NavigationRecorder: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
#endif
