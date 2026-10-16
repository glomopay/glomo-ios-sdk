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

    func testItParksTheValueBeforeCalling() {
        let script = GlomoPayInjectionScripts.colorScheme(.dark)
        let beforeCall = script.components(separatedBy: "glomoSetColorScheme(")[0]
        XCTAssertTrue(beforeCall.contains("window.__glomoColorScheme__ = 'dark';"))
    }

    func testItEvaluatesToWhetherTheCallTook() {
        // Read back by evaluateJavaScript, so the applied flag cannot race the page defining its
        // setter a moment later.
        let script = GlomoPayInjectionScripts.colorScheme(.dark)
        XCTAssertTrue(script.contains("return applied;"))
        XCTAssertTrue(script.contains("applied = true;"))
    }

    func testItEmitsTheWireVocabulary() {
        XCTAssertTrue(GlomoPayInjectionScripts.colorScheme(.light).contains("'light'"))
        XCTAssertTrue(GlomoPayInjectionScripts.colorScheme(.dark).contains("'dark'"))
    }

    func testItHasNoRunOnceGuardUnlikeTheInjectionsAroundIt() {
        // It is a document-start user script, so it runs on every load, and again on every
        // change. A guard would pin the page to whatever it saw first.
        XCTAssertFalse(GlomoPayInjectionScripts.colorScheme(.dark).contains("Injected__"))
    }

    func testItCannotThrowIntoThePage() {
        XCTAssertTrue(GlomoPayInjectionScripts.colorScheme(.dark).contains("catch (e) {}"))
    }
}

@MainActor
final class ColorSchemeChangeCollectorTests: XCTestCase {
    private var applied: [String]?
    private var unprobed: [String]?
    private var completions = 0

    private func makeCollector(_ targets: [String]) -> ColorSchemeChangeCollector {
        ColorSchemeChangeCollector(targets: targets) { [weak self] appliedTargets, unprobedTargets in
            self?.applied = appliedTargets
            self?.unprobed = unprobedTargets
            self?.completions += 1
        }
    }

    func testItReportsOnceEveryTargetHasAnswered() {
        let collector = makeCollector(["main", "carousel"])

        collector.record(target: "main", applied: true)
        XCTAssertNil(applied)

        collector.record(target: "carousel", applied: false)
        XCTAssertEqual(applied, ["main"])
        XCTAssertEqual(unprobed, [])
    }

    func testAPageThatRefusedIsAMissNotAnUnprobedSurface() {
        // The distinction is the whole point: a miss is a web-side slip, unprobed is our own
        // probe failing. Conflating them would let a torn-down WebView read as a site outage.
        let collector = makeCollector(["main", "carousel"])

        collector.record(target: "main", applied: true)
        collector.record(target: "carousel", applied: false)

        XCTAssertEqual(applied, ["main"])
        XCTAssertEqual(unprobed, [])
    }

    func testATargetThatNeverAnsweredIsUnprobed() {
        let collector = makeCollector(["main", "carousel"])

        collector.record(target: "main", applied: true)
        collector.timeOut()

        XCTAssertEqual(applied, ["main"])
        XCTAssertEqual(unprobed, ["carousel"])
    }

    func testATimeoutAfterEverythingAnsweredDoesNotReportTwice() {
        let collector = makeCollector(["main"])

        collector.record(target: "main", applied: true)
        collector.timeOut()

        XCTAssertEqual(completions, 1)
    }

    func testALateAnswerAfterReportingIsIgnored() {
        let collector = makeCollector(["main", "carousel"])

        collector.timeOut()
        collector.record(target: "main", applied: true)

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(applied, [])
        XCTAssertEqual(unprobed, ["main", "carousel"])
    }

    func testTheReportIsBuiltFromWhatWeAskedNotFromWhatArrived() {
        // The flow WebView is never a target - it holds the bank's page. If the report were built
        // from the answers rather than from the target list, a stray answer would put it in the
        // row and claim we themed a bank page.
        let collector = makeCollector(["main"])

        collector.record(target: "flow", applied: true)
        collector.record(target: "main", applied: true)

        XCTAssertEqual(applied, ["main"])
        XCTAssertEqual(unprobed, [])
    }
}
