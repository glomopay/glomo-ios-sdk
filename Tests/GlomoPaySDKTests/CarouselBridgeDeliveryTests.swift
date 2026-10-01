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
    /// The first WebContent process of a test run can take minutes to come up on a cold CI
    /// simulator (seen at about two minutes on the iOS 18.5 job). Paying that once, up front, keeps
    /// it out of each test's own wait.
    private static var webKitIsWarm = false

    override func tearDown() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
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
            body: body
        )

        XCTAssertEqual(received.count, 0)
    }

    // MARK: Helpers

    /// Loads a page with the production carousel script and bridge and returns what the native
    /// carousel handler received.
    ///
    /// Every page ends by posting a marker through the same `postMessage` channel. Message events
    /// reach listeners in order, and the carousel listener is registered first (document start),
    /// so when the marker arrives every earlier message has been through it. That makes "nothing
    /// was forwarded" observable without timing, and without depending on navigation callbacks.
    private func warmUpWebKitOnce() {
        guard !Self.webKitIsWarm else { return }
        let warm = expectation(description: "WebKit answered once")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<!doctype html><title>warm</title>", baseURL: nil)
        func poll() {
            webView.evaluateJavaScript("document.readyState") { value, _ in
                if value as? String == "complete" {
                    warm.fulfill()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                }
            }
        }
        poll()
        wait(for: [warm], timeout: 300)
        Self.webKitIsWarm = true
    }

    private func load(head script: String, body: String = "") throws -> [Any] {
        warmUpWebKitOnce()
        let box = MessageBox()
        let done = expectation(description: "page posted its last message")
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: GlomoPayInjectionScripts.carousel(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.add(GlomoPayJavaScriptBridge { box.append($0) }, name: "GlomoCarouselBridge")
        controller.add(GlomoPayJavaScriptBridge { _ in done.fulfill() }, name: "TestDone")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 120), configuration: configuration)
        self.webView = webView
        let page = """
            <!doctype html><html><head><script>
            window.addEventListener('message', function (event) {
              if (event.data === '__test_done__') window.webkit.messageHandlers.TestDone.postMessage('done');
            });
            \(script)
            window.parent.postMessage('__test_done__', '*');
            </script></head><body>\(body)</body></html>
            """
        webView.loadHTMLString(page, baseURL: URL(string: "https://carousel.example.test/"))
        wait(for: [done], timeout: 60)
        return box.messages
    }
}

private final class MessageBox {
    private(set) var messages: [Any] = []
    func append(_ message: Any) { messages.append(message) }
}
#endif
