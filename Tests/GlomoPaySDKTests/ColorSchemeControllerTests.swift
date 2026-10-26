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

    // MARK: - The chrome the SDK draws itself

    private func flowToolbar(in controller: GlomoPayCheckoutViewController) throws -> UIView {
        // The toolbar is the overlay's first subview and the only one that is a plain UIView
        // holding a UIButton.
        let overlay = try XCTUnwrap(
            controller.view.subviews.first { $0.layer.zPosition == 100 }
        )
        return try XCTUnwrap(
            overlay.subviews.first { $0.subviews.contains(where: { $0 is UIButton }) }
        )
    }

    func testTheFlowBarFollowsAnExplicitDarkScheme() throws {
        // The demo feedback, on the surface it was about: the bar over a bank page is the only
        // way out, and a white one pinned over a dark page is the most conspicuous thing in the
        // journey.
        let controller = makeController(appColorScheme: .dark, hostStyle: .light)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])

        XCTAssertEqual(try flowToolbar(in: controller).overrideUserInterfaceStyle, .dark)
    }

    func testAutoLeavesTheChromeLightOnADarkHost() throws {
        // The page is asked for dark and the frame stays light, deliberately. `auto` is a
        // request the page can refuse - the merchant may have no dark-mode flag - and a dark
        // frame around a light checkout reads as a defect where a light one reads as plain.
        // Before this, iOS was the one SDK that shipped the opposite, for free, through
        // semantic colours.
        let controller = makeController(appColorScheme: .auto, hostStyle: .dark)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])

        XCTAssertEqual(main.overrideUserInterfaceStyle, .dark, "the page still gets the host")
        XCTAssertEqual(try flowToolbar(in: controller).overrideUserInterfaceStyle, .light)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .light)
    }

    func testTheChromeMovesWhenTheMerchantMovesTheProp() throws {
        let controller = makeController(appColorScheme: .auto, hostStyle: .dark)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        XCTAssertEqual(try flowToolbar(in: controller).overrideUserInterfaceStyle, .light)

        // Resolves to dark either way on a dark host, so the page sees no change at all - which
        // is exactly the case a chrome keyed off the resolved scheme would miss.
        controller.setAppColorScheme(.dark)

        XCTAssertEqual(try flowToolbar(in: controller).overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(controller.loadingView.overrideUserInterfaceStyle, .dark)
    }

    func testPinningTheChromeLeavesTheBankPageInheritingTheHost() throws {
        // The containers carry the override, never this controller or its root view: an
        // override on either reaches the flow WebView, and pinning that would hand the bank's
        // own page a prefers-color-scheme the merchant's dark-mode flag never gated.
        let controller = makeController(appColorScheme: .dark, hostStyle: .light)
        let main = try XCTUnwrap(webViews(in: controller.view).first)
        controller.eventRouter.handle(envelope: ["type": "window.open", "url": "https://bank.example/3ds"])
        let flow = try XCTUnwrap(webViews(in: controller.view).first { $0 !== main })

        XCTAssertEqual(flow.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(flow.traitCollection.userInterfaceStyle, .light, "the host, not our dark")
        XCTAssertEqual(controller.view.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .light, "the test's host style")
    }

    func testALightOnlyAppOnADarkDeviceGetsALightCheckout() throws {
        // The item-4 case, and the only place it can actually be proved: `hostIsDark` reads the
        // controller's own trait collection, so what is under test is that an app pinning
        // `.light` inside a dark ancestor is followed rather than the ambient dark being read.
        // Asserting `resolve(hostIsDark:)` again would only restate testAutoFollowsTheHost.
        let controller = makeController(
            appColorScheme: .auto, hostStyle: .light, insideParentStyled: .dark
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
#endif
