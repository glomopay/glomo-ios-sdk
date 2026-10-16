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
        var evaluated: [String] = []
        controller.colorSchemeEvaluator = { webView, script, completion in
            XCTAssertIdentical(webView, main)
            evaluated.append(script)
            completion(true)
        }
        // Stands in for the checkout having loaded; the controller only pushes to pages that
        // have a document, since evaluating into one without would read as a page that refused.
        controller.didLoadCheckoutDocument = true

        controller.setColorScheme(.dark)

        XCTAssertEqual(evaluated, [GlomoPayInjectionScripts.colorScheme(.dark)])
        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark)
        // The live path is the injected setter. A new URL would reload the document and lose the
        // payment in flight.
        XCTAssertNil(main.url)
    }

    func testAChangeToTheSameResolvedSchemeIsANoOp() throws {
        let controller = makeController(appColorScheme: .auto, hostStyle: .dark)
        var evaluated: [String] = []
        controller.colorSchemeEvaluator = { _, script, completion in
            evaluated.append(script)
            completion(true)
        }
        controller.didLoadCheckoutDocument = true

        // auto already resolved to dark, so pinning dark is not a change.
        controller.setColorScheme(.dark)

        XCTAssertTrue(evaluated.isEmpty)
    }

    func testNothingIsPushedBeforeThePageHasLoaded() throws {
        let controller = makeController(appColorScheme: .light)
        var evaluated: [String] = []
        controller.colorSchemeEvaluator = { _, script, completion in
            evaluated.append(script)
            completion(true)
        }

        controller.setColorScheme(.dark)

        // The URL carries the scheme at mount, so there is nothing to push yet - and evaluating
        // into a WebView with no document would be reported as a page that refused.
        XCTAssertTrue(evaluated.isEmpty)
    }

    func testTheBankPageIsNeverSentAScheme() throws {
        let controller = makeController(appColorScheme: .light)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        let flow = try XCTUnwrap(webViews(in: controller.view).first { $0 !== main })
        var targets: [WKWebView] = []
        controller.colorSchemeEvaluator = { webView, _, completion in
            targets.append(webView)
            completion(true)
        }
        controller.didLoadCheckoutDocument = true

        controller.setColorScheme(.dark)

        // The main WebView was pushed to, so an empty flow result means excluded rather than
        // nothing having happened at all.
        XCTAssertEqual(targets, [main])
        XCTAssertFalse(targets.contains(flow))
        // Its reported appearance is still pinned with the others, so the platform cannot tell a
        // bank page something that disagrees with the checkout it was opened from.
        XCTAssertEqual(flow.overrideUserInterfaceStyle, .dark)
    }

    func testTheHandleForwardsToTheCheckout() throws {
        let controller = makeController(appColorScheme: .light)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        let handle = GlomoPayCheckoutHandle()
        handle.attach(controller)
        var evaluated: [String] = []
        controller.colorSchemeEvaluator = { _, script, completion in
            evaluated.append(script)
            completion(true)
        }
        controller.didLoadCheckoutDocument = true

        handle.setColorScheme(.dark)

        XCTAssertEqual(evaluated, [GlomoPayInjectionScripts.colorScheme(.dark)])
    }
}
#endif
