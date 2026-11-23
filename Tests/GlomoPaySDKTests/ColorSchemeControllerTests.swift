#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import XCTest
@testable import GlomoPaySDK

/// Colour-scheme behaviour that needs a real controller and real WKWebViews.
///
/// `swift test` builds for macOS, where the controller is compiled out entirely, so everything
/// here runs only on the iOS-simulator job. The resolution rules, the URL and the injected script
/// are covered on macOS in `ColorSchemeTests`; this file covers what only the controller does.
@MainActor
final class ColorSchemeControllerTests: XCTestCase {
    /// `UIViewController.parent` is weak, so a parent built inside a helper would be gone before
    /// the assertion runs and the trait inheritance with it.
    private var retainedParents: [UIViewController] = []

    private func queryParameters(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return items.reduce(into: [:]) { result, item in result[item.name] = item.value }
    }

    private func makeController(
        appColorScheme: GlomoColorScheme = .auto,
        hostStyle: UIUserInterfaceStyle = .light,
        insideParentStyled parentStyle: UIUserInterfaceStyle? = nil
    ) -> GlomoPayCheckoutViewController {
        let config = GlomoPayConfig(
            publicKey: "test_public_key",
            orderId: "order_123456",
            appColorScheme: appColorScheme
        )
        let controller = GlomoPayCheckoutViewController(
            config: config,
            orderType: "standard",
            listener: nil,
            apiClient: nil,
            telemetryRuntime: .shared
        )
        // Pinned before the view loads, because the scheme is resolved in viewDidLoad.
        controller.overrideUserInterfaceStyle = hostStyle
        // Parented before the view loads too, for the same reason: otherwise the trait
        // collection viewDidLoad reads has no ancestor to inherit from and the test proves
        // nothing about which of the two won.
        if let parentStyle {
            let parent = UIViewController()
            parent.overrideUserInterfaceStyle = parentStyle
            retainedParents.append(parent)
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.didMove(toParent: parent)
        }
        controller.loadViewIfNeeded()
        return controller
    }

    /// Drives the real checkout lifecycle, appearance transition included, and waits until the
    /// first load has been built.
    ///
    /// With an `orderBody` it takes the `auto` path, so the merchant flag arrives the way it does
    /// in production: off the order response, after the WebView already exists and has been
    /// pinned light. With `orderBody` nil it takes the explicit-order-type path, which skips the
    /// fetch entirely and never learns the flag.
    ///
    /// `loadViewIfNeeded()` alone is not enough for either: `startCheckout` runs from
    /// `viewDidAppear`, so without the transition a test asserts the construction-time pin and
    /// would still pass if the path under test went on to turn the surface dark.
    ///
    /// `httpClient` is for the two paths an `orderBody` cannot express - a fetch that fails and a
    /// fetch still in flight. Both of those need `waitingForFirstLoad` off, because the wait below
    /// is on a load that one of them never reaches and the other has not reached yet.
    private func makeFetchingController(
        appColorScheme: GlomoColorScheme = .auto,
        hostStyle: UIUserInterfaceStyle = .light,
        insideParentStyled parentStyle: UIUserInterfaceStyle? = nil,
        orderType: String = "auto",
        orderBody: String? = nil,
        httpClient: GlomoPayHTTPClient? = nil,
        waitingForFirstLoad: Bool = true
    ) async throws -> GlomoPayCheckoutViewController {
        let config = GlomoPayConfig(
            publicKey: "test_public_key",
            orderId: "order_123456",
            appColorScheme: appColorScheme
        )
        var orderClient: GlomoPayHTTPClient? = httpClient
        if orderClient == nil, let orderBody { orderClient = OrderBodyHTTPClient(body: orderBody) }
        let controller = GlomoPayCheckoutViewController(
            config: config,
            orderType: orderType,
            listener: nil,
            apiClient: orderClient.map { client in
                GlomoPayApiClient(
                    publicKey: "test_public_key",
                    baseURL: URL(string: "https://api.example.com")!,
                    client: client
                )
            },
            telemetryRuntime: .shared
        )
        controller.overrideUserInterfaceStyle = hostStyle
        // Parented before the view loads, for the same reason as in `makeController`: otherwise
        // the trait collection `viewDidLoad` reads has no ancestor to inherit from and the test
        // proves nothing about which of the two won.
        if let parentStyle {
            let parent = UIViewController()
            parent.overrideUserInterfaceStyle = parentStyle
            retainedParents.append(parent)
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.didMove(toParent: parent)
        }
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        guard waitingForFirstLoad else { return controller }
        try await waitForFirstLoad(controller)
        return controller
    }

    /// `currentURL` is assigned in `loadCheckout`, which runs after the fetch resolved and the
    /// flag was applied - so waiting on it synchronises on both without reaching into either.
    private func waitForFirstLoad(_ controller: GlomoPayCheckoutViewController) async throws {
        for _ in 0..<600 where controller.currentURL == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try XCTUnwrap(controller.currentURL)
    }

    /// What a surface actually paints, resolved against the traits it is pinned to.
    ///
    /// The colour is dynamic, so comparing `UIColor` instances compares two recipes rather than
    /// two pixels; a hex string is the thing the page and the SDK have to agree on.
    private func paintedHex(_ color: UIColor?, in traits: UITraitCollection) throws -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try XCTUnwrap(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255 + 0.5), Int(green * 255 + 0.5), Int(blue * 255 + 0.5)
        )
    }

    /// The carousel, told apart from the main and flow WebViews by the only script it carries.
    ///
    /// Positional indexing would pass just as well today and silently pick the wrong surface the
    /// first time the view hierarchy moves.
    private func carouselWebView(in controller: GlomoPayCheckoutViewController) throws -> WKWebView {
        try XCTUnwrap(webViews(in: controller.view).first { webView in
            webView.configuration.userContentController.userScripts.contains {
                $0.source == GlomoPayInjectionScripts.carousel()
            }
        })
    }

    private func webViews(in root: UIView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = root as? WKWebView { found.append(webView) }
        for subview in root.subviews { found += webViews(in: subview) }
        return found
    }

    func testTheWebViewReportsTheSchemeWeSent() async throws {
        // Without this the page is told dark over the URL while its own
        // `prefers-color-scheme` media query still matches light, and it renders half of each.
        // Only true for a merchant on the flag: with it off the page renders light whatever the
        // URL said, so reporting dark would be the same split rendering the other way round.
        let dark = try await makeFetchingController(appColorScheme: .dark, orderBody: darkModeOnOrder)
        XCTAssertEqual(try XCTUnwrap(webViews(in: dark.view).first).overrideUserInterfaceStyle, .dark)

        let light = try await makeFetchingController(appColorScheme: .light, orderBody: darkModeOnOrder)
        XCTAssertEqual(try XCTUnwrap(webViews(in: light.view).first).overrideUserInterfaceStyle, .light)
    }

    func testAnExplicitSchemeOverridesADarkHost() async throws {
        let controller = try await makeFetchingController(
            appColorScheme: .light, hostStyle: .dark, orderBody: darkModeOnOrder
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
    }

    func testAutoFollowsTheHost() async throws {
        let controller = try await makeFetchingController(
            appColorScheme: .auto, hostStyle: .dark, orderBody: darkModeOnOrder
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark)
    }

    func testTheWebViewStaysLightWhileTheMerchantFlagIsOff() async throws {
        // The regression this ticket exists for: before the flag was read, a dark-requesting host
        // on a flag-off merchant pinned dark here, flashing dark in front of a page that renders
        // light and leaving `prefers-color-scheme` disagreeing with the URL.
        let controller = try await makeFetchingController(
            appColorScheme: .dark, hostStyle: .dark, orderBody: darkModeOffOrder
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
    }

    func testTheWebViewStaysLightWhenTheResponseCarriesNoFlag() async throws {
        // What an older or proxied response looks like. Absent is not permission.
        let controller = try await makeFetchingController(
            appColorScheme: .dark, hostStyle: .dark, orderBody: orderWithoutFlag
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
    }

    func testAPathThatNeverFetchesStaysLight() async throws {
        // An explicit order type skips the order fetch entirely, so the flag is never known.
        // Light is the correct answer and this pins it: these merchants keep the flash until
        // the fetch is reworked, which is deliberately not this change.
        let controller = try await makeFetchingController(
            appColorScheme: .dark, hostStyle: .dark, orderType: "standard"
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .light)
    }

    func testTheLoadingViewFollowsTheFlagToo() async throws {
        // The loading view covers the WebView until the page paints, so recolouring only the
        // WebView underneath would change nothing anyone can see.
        let on = try await makeFetchingController(appColorScheme: .dark, orderBody: darkModeOnOrder)
        XCTAssertEqual(on.loadingView.overrideUserInterfaceStyle, .dark)

        let off = try await makeFetchingController(appColorScheme: .dark, orderBody: darkModeOffOrder)
        XCTAssertEqual(off.loadingView.overrideUserInterfaceStyle, .light)
    }

    func testEverySurfaceIsLightWhileTheFetchIsStillInFlight() async throws {
        // The window this change actually lives in. The WebView exists and is on screen before
        // the flag can possibly be known, so "light until it lands" is the whole guarantee - and
        // it is the half that a construction-time pin to the request would get wrong.
        let gate = OrderFetchGate()
        let controller = try await makeFetchingController(
            appColorScheme: .dark,
            hostStyle: .dark,
            httpClient: GatedOrderHTTPClient(body: darkModeOnOrder, gate: gate),
            waitingForFirstLoad: false
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .light)

        await gate.open()
        try await waitForFirstLoad(controller)

        // And dark lands once it is known, so the first half is the fetch being in flight rather
        // than the flag never arriving.
        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .dark)
    }

    func testAFailedOrderFetchLeavesEverySurfaceLight() async throws {
        // Fail-open: the flag is read off a fetch that already gates the load, so a fetch that
        // never answers must leave the surfaces exactly as they started rather than guessing.
        let controller = try await makeFetchingController(
            appColorScheme: .dark,
            hostStyle: .dark,
            httpClient: FailingOrderHTTPClient(),
            waitingForFirstLoad: false
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        // The failure path hides the loading view on its way out, which is the one observable
        // moment the fetch is known to have been given up on.
        for _ in 0..<600 where !controller.loadingView.isHidden {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.loadingView.isHidden)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .light)
    }

    func testTheCarouselFollowsTheFlagOnAnLRSOrder() async throws {
        // The carousel is built inside `openFlow`, after the response has answered, so unlike the
        // main WebView it takes the gated scheme at construction and is never re-pinned on the
        // way in. That is a second path to the same rule, and nothing else covers it.
        let on = try await makeFetchingController(appColorScheme: .dark, orderBody: lrsDarkModeOnOrder)
        on.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        XCTAssertEqual(try carouselWebView(in: on).overrideUserInterfaceStyle, .dark)

        let off = try await makeFetchingController(appColorScheme: .dark, orderBody: lrsDarkModeOffOrder)
        off.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        XCTAssertEqual(try carouselWebView(in: off).overrideUserInterfaceStyle, .light)
    }

    func testTheDarkLoadingScreenIsThePagesOwnDarkNotBlack() async throws {
        // `.systemBackground` under a `.dark` override is #000000, which is darker than the page
        // it frames: the edges seam while the page settles. Same value as the Android SDK's.
        //
        // Resolved against the style the surface is pinned to rather than against its live
        // traits: a view that is not in a window has nothing to propagate them from, so reading
        // `traitCollection` here would measure the test harness rather than the colour.
        let on = try await makeFetchingController(appColorScheme: .dark, orderBody: darkModeOnOrder)
        XCTAssertEqual(on.loadingView.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(
            try paintedHex(on.loadingView.backgroundColor, in: UITraitCollection(userInterfaceStyle: .dark)),
            "#0F172A"
        )

        // And light is left exactly where it was, which is what makes the flag-off path a no-op.
        let off = try await makeFetchingController(appColorScheme: .dark, orderBody: darkModeOffOrder)
        XCTAssertEqual(off.loadingView.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(
            try paintedHex(off.loadingView.backgroundColor, in: UITraitCollection(userInterfaceStyle: .light)),
            try paintedHex(.systemBackground, in: UITraitCollection(userInterfaceStyle: .light))
        )
    }

    func testALiveChangeRepaintsEverySurfaceOnTheFlag() async throws {
        // `applyColorScheme(_:)` is the only thing that runs when the host changes appearance
        // mid-checkout. The loading view is the one that bites: it comes back on every main-frame
        // navigation, on Retry and on process-termination recovery, so a style left behind here
        // reappears over the new page rather than being corrected by the next load.
        let controller = try await makeFetchingController(
            appColorScheme: .light, orderBody: darkModeOnOrder
        )
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)

        controller.setAppColorScheme(.dark)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .dark)
    }

    func testALiveChangeLeavesAFlagOffCheckoutLight() async throws {
        // The request still reaches the page; what the SDK paints is the separate decision.
        let controller = try await makeFetchingController(
            appColorScheme: .light, orderBody: darkModeOffOrder
        )

        controller.setAppColorScheme(.dark)

        let main = try XCTUnwrap(webViews(in: controller.view).first)
        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .light)
    }

    func testAChangeReachesThePageWithoutReloadingIt() throws {
        let controller = makeController(appColorScheme: .light)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        var evaluated: [(WKWebView, String)] = []
        controller.scriptEvaluator = { webView, script in evaluated.append((webView, script)) }

        controller.setAppColorScheme(.dark)

        XCTAssertEqual(evaluated.map(\.1), [GlomoPayInjectionScripts.colorScheme(.dark)])
        XCTAssertIdentical(evaluated.first?.0, main)
        // The request still reaches the page - what we paint is a separate decision, and with no
        // flag on this controller it stays light.
        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
        // The live path is the injected setter. A new URL would reload the document and lose the
        // payment in flight.
        XCTAssertNil(main.url)
    }

    func testAChangeToTheSameResolvedSchemeIsANoOp() throws {
        let controller = makeController(appColorScheme: .auto, hostStyle: .dark)
        var evaluated: [String] = []
        controller.scriptEvaluator = { _, script in evaluated.append(script) }

        // auto already resolved to dark, so pinning dark is not a change.
        controller.setAppColorScheme(.dark)

        XCTAssertTrue(evaluated.isEmpty)
    }

    func testTheBankPageIsNeitherSentASchemeNorRestyled() throws {
        let controller = makeController(appColorScheme: .light)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        let flow = try XCTUnwrap(webViews(in: controller.view).first { $0 !== main })
        let flowStyleBefore = flow.overrideUserInterfaceStyle
        var targets: [WKWebView] = []
        controller.scriptEvaluator = { webView, _ in targets.append(webView) }

        controller.setAppColorScheme(.dark)

        // The main WebView was pushed to, so an empty flow result means excluded rather than
        // nothing having happened at all.
        XCTAssertEqual(targets, [main])
        // And its appearance is left exactly as it was: pinning it would let a merchant on `.dark`
        // darken the bank's own 3DS page, which is not gated on the merchant's dark-mode flag the
        // way the checkout page is.
        XCTAssertEqual(flow.overrideUserInterfaceStyle, flowStyleBefore)
    }

    func testALightOnlyAppOnADarkDeviceGetsALightCheckout() async throws {
        // The item-4 case, and the only place it can actually be proved: `hostIsDark` reads the
        // controller's own trait collection, so what is under test is that an app pinning
        // `.light` inside a dark ancestor is followed rather than the ambient dark being read.
        // Asserting `resolve(hostIsDark:)` again would only restate testAutoFollowsTheHost.
        // On the flag, so that light here is the host being followed rather than the flag
        // forcing light and the assertion proving nothing.
        let controller = try await makeFetchingController(
            appColorScheme: .auto,
            hostStyle: .light,
            insideParentStyled: .dark,
            orderBody: darkModeOnOrder
        )

        let main = try XCTUnwrap(webViews(in: controller.view).first)
        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
    }

    func testARetryAfterAChangeCarriesTheNewScheme() throws {
        let controller = makeController(appColorScheme: .light)
        let opened = try XCTUnwrap(controller.mainDocumentRequest(
            for: XCTUnwrap(URL(string: "https://checkout.glomopay.com/?orderId=order_1&colorScheme=light"))
        ).url)
        XCTAssertEqual(queryParameters(opened)["colorScheme"], "light")

        controller.setAppColorScheme(.dark)

        // Retry and the recovery reload both replay the URL built at open. Rebuilt through the
        // same chokepoint, they carry the scheme current now - not the one the checkout opened
        // with - and the parameter is replaced rather than duplicated.
        let retried = try XCTUnwrap(controller.mainDocumentRequest(
            for: XCTUnwrap(URL(string: "https://checkout.glomopay.com/?orderId=order_1&colorScheme=light"))
        ).url)
        XCTAssertEqual(queryParameters(retried)["colorScheme"], "dark")
        let items = URLComponents(url: retried, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "colorScheme" }.count, 1)
    }

    func testTheHandleForwardsToTheCheckout() throws {
        let controller = makeController(appColorScheme: .light)
        let handle = GlomoPayCheckoutHandle()
        handle.attach(controller)
        var evaluated: [String] = []
        controller.scriptEvaluator = { _, script in evaluated.append(script) }

        handle.setAppColorScheme(.dark)

        XCTAssertEqual(evaluated, [GlomoPayInjectionScripts.colorScheme(.dark)])
    }
}

private let darkModeOnOrder = #"{"id":"order_123456","orderType":"standard","dark_mode_enabled":true}"#
private let darkModeOffOrder = #"{"id":"order_123456","orderType":"standard","dark_mode_enabled":false}"#
private let orderWithoutFlag = #"{"id":"order_123456","orderType":"standard"}"#
// No `orderType`: the type is detected from the `lrs` key, which is what puts a carousel above
// the bank page.
private let lrsDarkModeOnOrder = #"{"id":"order_123456","lrs":{},"dark_mode_enabled":true}"#
private let lrsDarkModeOffOrder = #"{"id":"order_123456","lrs":{},"dark_mode_enabled":false}"#

private struct OrderBodyHTTPClient: GlomoPayHTTPClient {
    let body: String
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private struct FailingOrderHTTPClient: GlomoPayHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// Holds the order fetch open until a test has looked at the surfaces underneath it.
private actor OrderFetchGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private struct GatedOrderHTTPClient: GlomoPayHTTPClient {
    let body: String
    let gate: OrderFetchGate
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await gate.wait()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
#endif
