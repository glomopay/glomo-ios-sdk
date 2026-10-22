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
    private func makeController(
        appColorScheme: GlomoColorScheme = .auto,
        hostStyle: UIUserInterfaceStyle = .light
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
        controller.loadViewIfNeeded()
        return controller
    }

    private func webViews(in root: UIView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = root as? WKWebView { found.append(webView) }
        for subview in root.subviews { found += webViews(in: subview) }
        return found
    }

    func testTheWebViewReportsTheSchemeWeSent() throws {
        // Without this the page is told dark over the URL while its own
        // `prefers-color-scheme` media query still matches light, and it renders half of each.
        let dark = try XCTUnwrap(webViews(in: makeController(appColorScheme: .dark).view).first)
        XCTAssertEqual(dark.overrideUserInterfaceStyle, .dark)

        let light = try XCTUnwrap(webViews(in: makeController(appColorScheme: .light).view).first)
        XCTAssertEqual(light.overrideUserInterfaceStyle, .light)
    }

    func testAnExplicitSchemeOverridesADarkHost() throws {
        let controller = makeController(appColorScheme: .light, hostStyle: .dark)
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .light)
    }

    func testAutoFollowsTheHost() throws {
        let controller = makeController(appColorScheme: .auto, hostStyle: .dark)
        let main = try XCTUnwrap(webViews(in: controller.view).first)

        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark)
    }

    func testAChangeReachesThePageWithoutReloadingIt() throws {
        let controller = makeController(appColorScheme: .light)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        var evaluated: [(WKWebView, String)] = []
        controller.scriptEvaluator = { webView, script in evaluated.append((webView, script)) }

        controller.setAppColorScheme(.dark)

        XCTAssertEqual(evaluated.map(\.1), [GlomoPayInjectionScripts.colorScheme(.dark)])
        XCTAssertIdentical(evaluated.first?.0, main)
        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark)
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
#endif
