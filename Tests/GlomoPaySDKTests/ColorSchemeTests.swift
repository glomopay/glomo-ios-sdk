import XCTest
@testable import GlomoPaySDK

private func queryParameters(_ url: URL?) -> [String: String] {
    guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
        return [:]
    }
    return items.reduce(into: [:]) { result, item in result[item.name] = item.value }
}

final class ColorSchemeResolutionTests: XCTestCase {
    func testExplicitSchemesIgnoreTheHost() {
        XCTAssertEqual(GlomoColorScheme.light.resolve(hostIsDark: true), .light)
        XCTAssertEqual(GlomoColorScheme.dark.resolve(hostIsDark: false), .dark)
    }

    func testAutoFollowsTheHost() {
        XCTAssertEqual(GlomoColorScheme.auto.resolve(hostIsDark: true), .dark)
        XCTAssertEqual(GlomoColorScheme.auto.resolve(hostIsDark: false), .light)
    }

    func testALightOnlyAppOnADarkDeviceGetsALightCheckout() {
        // `hostIsDark` is read off the view controller's own trait collection, which carries the
        // host's `overrideUserInterfaceStyle`. An app pinned light reports light here even on a
        // device in dark mode, and that is what the checkout must follow.
        XCTAssertEqual(GlomoColorScheme.auto.resolve(hostIsDark: false), .light)
        XCTAssertEqual(GlomoColorScheme.light.resolve(hostIsDark: true), .light)
    }

    func testTheWireVocabularyIsExactlyLightAndDark() {
        XCTAssertEqual(ResolvedColorScheme.light.wireName, "light")
        XCTAssertEqual(ResolvedColorScheme.dark.wireName, "dark")
    }

    func testTheDefaultIsAuto() {
        XCTAssertEqual(GlomoPayConfig(publicKey: "live_k", orderId: "order_1").appColorScheme, .auto)
    }

    func testThePropertyVocabularyIsStable() {
        // Raw values reach analytics as `app_color_scheme`, so a rename here is a data change.
        XCTAssertEqual(GlomoColorScheme.auto.rawValue, "auto")
        XCTAssertEqual(GlomoColorScheme.light.rawValue, "light")
        XCTAssertEqual(GlomoColorScheme.dark.rawValue, "dark")
    }
}

final class ColorSchemeURLTests: XCTestCase {
    private let config = GlomoPayConfig(publicKey: "live_k", orderId: "order_1")

    func testTheResolvedSchemeReachesTheCheckoutURL() {
        XCTAssertEqual(
            queryParameters(ConfigManager.getCheckoutURL(config, orderType: "standard", colorScheme: .dark))["colorScheme"],
            "dark"
        )
        XCTAssertEqual(
            queryParameters(ConfigManager.getCheckoutURL(config, orderType: "lrs", colorScheme: .light))["colorScheme"],
            "light"
        )
    }

    func testTheCarouselTakesItOnTheSameParam() {
        XCTAssertEqual(
            queryParameters(ConfigManager.getCarouselURL(config, colorScheme: .dark))["colorScheme"],
            "dark"
        )
    }

    func testItIsOmittedWhenUnresolvedRatherThanSentEmpty() {
        XCTAssertNil(queryParameters(ConfigManager.getCheckoutURL(config))["colorScheme"])
        XCTAssertNil(queryParameters(ConfigManager.getCarouselURL(config))["colorScheme"])
    }

    func testItDoesNotDisturbTheParamsThePageAlreadyReads() {
        let parameters = queryParameters(
            ConfigManager.getCheckoutURL(config, orderType: "standard", colorScheme: .dark)
        )
        XCTAssertEqual(parameters["orderId"], "order_1")
        XCTAssertEqual(parameters["publicKey"], "live_k")
        XCTAssertEqual(parameters["mode"], "live")
        XCTAssertEqual(parameters["colorScheme"], "dark")

        let carousel = queryParameters(ConfigManager.getCarouselURL(config, colorScheme: .light))
        XCTAssertEqual(carousel["product"], "checkout-ios-sdk")
        XCTAssertEqual(carousel["surface"], "ios")
        XCTAssertEqual(carousel["colorScheme"], "light")
    }
}

final class ColorSchemeInjectionTests: XCTestCase {
    func testItGuardsTheSetterNotWindow() {
        // `window` always exists in a WebView; the setter is what is absent during load or on an
        // older merchant deploy, so `window?.` would throw where this skips.
        let script = GlomoPayInjectionScripts.colorScheme(.dark)
        XCTAssertTrue(script.contains("typeof window.glomoSetColorScheme === 'function'"))
        XCTAssertFalse(script.contains("window?."))
    }

    func testItSendsNothingButTheSetterCall() {
        // No parked global: no page reads one, so it would be a contract with no consumer. No
        // read-back either - a flag that is true whenever the setter returned says nothing about
        // whether the page changed, because the page weighs the request against the merchant's
        // own dashboard settings.
        let script = GlomoPayInjectionScripts.colorScheme(.dark)
        XCTAssertFalse(script.contains("__glomoColorScheme"))
        XCTAssertFalse(script.contains("return"))
    }

    func testItEmitsTheWireVocabulary() {
        XCTAssertTrue(GlomoPayInjectionScripts.colorScheme(.light).contains("'light'"))
        XCTAssertTrue(GlomoPayInjectionScripts.colorScheme(.dark).contains("'dark'"))
    }

    func testItHasNoRunOnceGuardUnlikeTheInjectionsAroundIt() {
        // Re-run on every page load and every change; a guard would pin the page to whatever it
        // saw first.
        XCTAssertFalse(GlomoPayInjectionScripts.colorScheme(.dark).contains("Injected__"))
    }

    func testItCannotThrowIntoThePage() {
        XCTAssertTrue(GlomoPayInjectionScripts.colorScheme(.dark).contains("catch (e) {}"))
    }
}
