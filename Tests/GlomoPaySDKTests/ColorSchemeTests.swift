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

    // The app-light / device-dark case is not testable here: `resolve` takes a Bool, so asserting
    // it again would only restate testAutoFollowsTheHost. What has to be proved is that
    // `hostIsDark` reads the host's overridden style rather than the device's, which needs a real
    // trait collection - see ColorSchemeControllerTests.

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

final class ColorSchemeURLUpsertTests: XCTestCase {
    private let base = URL(string: "https://checkout.glomopay.com/?orderId=order_1&publicKey=live_k")!

    func testItAddsTheParamWhenThePageHasStrippedIt() {
        // The page removes it with history.replaceState once it has read it, so on most reload
        // paths there is nothing to replace and it has to be put back.
        XCTAssertEqual(queryParameters(withColorScheme(base, .dark))["colorScheme"], "dark")
    }

    func testItReplacesAStaleValueRatherThanAppendingASecond() {
        let stamped = withColorScheme(base, .light)
        let restamped = withColorScheme(stamped, .dark)
        let items = URLComponents(url: restamped, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "colorScheme" }.count, 1)
        XCTAssertEqual(queryParameters(restamped)["colorScheme"], "dark")
    }

    func testItKeepsEveryOtherParam() {
        let params = queryParameters(withColorScheme(base, .dark))
        XCTAssertEqual(params["orderId"], "order_1")
        XCTAssertEqual(params["publicKey"], "live_k")
    }

    func testItLeavesANonHttpUrlAlone() {
        // URLComponents will hang a query off a mailto: without complaint, and a parameter no
        // page can read is worse than none.
        let mailto = URL(string: "mailto:support@glomo.one")!
        XCTAssertEqual(withColorScheme(mailto, .dark).absoluteString, mailto.absoluteString)
    }
}

final class ColorSchemeOriginGateTests: XCTestCase {
    private let checkout = URL(string: "https://checkout.glomopay.com/?orderId=order_1")!

    func testAnOriginIsSchemeHostAndPort() {
        XCTAssertTrue(sameColorSchemeOrigin(checkout, URL(string: "https://checkout.glomopay.com/other")))
        XCTAssertFalse(sameColorSchemeOrigin(checkout, URL(string: "http://checkout.glomopay.com/")))
        XCTAssertFalse(sameColorSchemeOrigin(checkout, URL(string: "https://checkout.glomopay.com:8443/")))
    }

    func testADifferentHostIsADifferentOrigin() {
        XCTAssertFalse(sameColorSchemeOrigin(checkout, URL(string: "https://bank.example.com/3ds")))
    }

    func testNilOnEitherSideIsNotAMatch() {
        XCTAssertFalse(sameColorSchemeOrigin(nil, checkout))
        XCTAssertFalse(sameColorSchemeOrigin(checkout, nil))
    }

    func testALivePushSkipsASurfaceSittingOnABankPage() {
        // The case the gate exists for: a host theme change mid-payment must not restyle the
        // bank's own page.
        XCTAssertFalse(mayPushColorScheme(
            loaded: URL(string: "https://bank.example.com/3ds"), expected: checkout
        ))
    }

    func testALivePushReachesASurfaceBackOnAGlomoPage() {
        XCTAssertTrue(mayPushColorScheme(
            loaded: URL(string: "https://checkout.glomopay.com/step2"), expected: checkout
        ))
    }

    func testALivePushIsAllowedBeforeAnythingIsCommitted() {
        // Nothing to mis-theme, and the document that does land carries the scheme on its URL.
        XCTAssertTrue(mayPushColorScheme(loaded: nil, expected: checkout))
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

    func testItParksTheValueBeforeCallingTheSetter() {
        // The page seeds from the global on mount, which is what keeps a scheme pushed before
        // the setter existed from being lost. Before, not after: a setter already present runs
        // synchronously and would read a global not yet written.
        let script = GlomoPayInjectionScripts.colorScheme(.dark)
        let parked = script.range(of: "window.__glomoColorScheme__ = 'dark'")
        let called = script.range(of: "glomoSetColorScheme('dark')")
        XCTAssertNotNil(parked)
        XCTAssertNotNil(called)
        if let parked, let called {
            XCTAssertLessThan(parked.lowerBound, called.lowerBound)
        }
    }

    func testItReadsNothingBack() {
        // A flag that is true whenever the setter returned says nothing about whether the page
        // changed - the page weighs the request against the merchant's dashboard settings.
        XCTAssertFalse(GlomoPayInjectionScripts.colorScheme(.dark).contains("return"))
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

/// The merchant's `dark_mode_enabled` flag, as read off the order response.
///
/// Every dictionary here is decoded from JSON bytes rather than written as a Swift literal,
/// because the two do not behave the same. `JSONSerialization` boxes JSON booleans and JSON
/// numbers alike into `NSNumber`, and bridging back hands `1` to Swift as `true`; a Swift `Int`
/// literal never bridges, so a hand-built dictionary passes an identity check the wire does not.
///
/// Plain dictionary in, Bool out, so the rule is covered on the macOS run where the checkout
/// controller is compiled out. What the controller then does with it is in
/// `ColorSchemeControllerTests`, on the simulator.
final class DarkModeFlagTests: XCTestCase {
    /// The order response as it actually reaches `ConfigManager`.
    private func order(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testItIsOnOnlyForALiteralTrue() throws {
        XCTAssertTrue(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": true}"#)))
    }

    func testItIsOffForFalse() throws {
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": false}"#)))
    }

    func testItIsOffWhenTheKeyIsAbsent() throws {
        // What every response looked like before the field shipped, and what a cached or
        // proxied older response still looks like.
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"orderType": "lrs"}"#)))
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order("{}")))
    }

    func testItIsOffForANumber() throws {
        // The case a Swift literal cannot reach. `1` and `1.0` both arrive as `NSNumber` and
        // both bridge to `true` through `as? Bool`, so a truthiness read turns a numeric 1 into
        // a dark checkout for a merchant who never switched dark mode on.
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": 1}"#)))
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": 1.0}"#)))
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": 0}"#)))
    }

    func testItIsOffForAnythingThatIsNotABool() throws {
        // An identity check rather than a truthiness one: each of these is truthy in some
        // language on this contract, and dark is the only answer that can be visibly wrong.
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": "true"}"#)))
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"dark_mode_enabled": null}"#)))
    }

    func testItReadsTheSnakeCaseKeyOnly() throws {
        // The payload carries both `order_type` and `orderType`; this field has no camelCase
        // alias, so a reader guessing one finds nothing and silently stays light.
        XCTAssertFalse(ConfigManager.darkModeEnabled(try order(#"{"darkModeEnabled": true}"#)))
    }
}
