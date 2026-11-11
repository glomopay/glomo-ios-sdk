import XCTest
@testable import GlomoPaySDK

final class AnalyticsCatalogueTests: XCTestCase {
    func testNamesAndLists() throws {
        XCTAssertEqual(AnalyticsCatalogue.eventNames, [
            "sdk_loaded",
            "sdk_page_viewed",
            "sdk_api_backend",
            "sdk_action_submitted",
            "sdk_action_failed",
            "sdk_cta_clicked",
            "sdk_control_changed",
            "sdk_checkout_failed",
            "sdk_checkout_closed",
        ])
        XCTAssertEqual(try declaredEventNames(), AnalyticsCatalogue.eventNames)

        XCTAssertEqual(
            AnalyticsPageName.allCases.map(\.rawValue),
            ["loading", "checkout", "bank_redirect", "education_carousel", "error"]
        )
        XCTAssertEqual(AnalyticsCTAName.allCases.map(\.rawValue), ["retry", "back_to_checkout"])
        XCTAssertEqual(AnalyticsCloseTrigger.allCases.map(\.rawValue), ["user_dismiss", "merchant", "sdk"])
        XCTAssertEqual(Set(AnalyticsErrorPageCode.allCases.map(\.rawValue)), Self.errorPageCodes)
        XCTAssertEqual(AnalyticsWebViewType.allCases.map(\.rawValue), ["main", "flow"])
        XCTAssertTrue(Set(AnalyticsActionName.allCases.map(\.rawValue)).isSubset(of: Self.errorCodesByAction.keys))
        XCTAssertTrue(Set(AnalyticsPaymentEvent.allCases.map(\.rawValue)).isSubset(of: Self.paymentEvents))
        XCTAssertTrue(Set(AnalyticsAPIError.allCases.map(\.rawValue)).isSubset(of: Self.apiErrorCodes))
        XCTAssertEqual(Set(AnalyticsCheckoutFailure.errorCodes), Set(Self.detailsByCheckoutFailure.keys))
        XCTAssertEqual(AnalyticsCatalogue.orderAPIPath, "/api/public/v1/order/:order_id")
    }

    func testEveryEmissionGoesThroughTheTypedCatalogue() throws {
        let sourcesRoot = Self.repositoryRoot.appendingPathComponent("Sources/GlomoPaySDK")
        let catalogueFiles: Set<String> = ["AnalyticsCatalogue.swift", "AnalyticsTracker.swift"]
        let untypedCall = try NSRegularExpression(pattern: #"(?<!func )(?<![A-Za-z0-9_])track\s*\(|AnalyticsEventName\."#)

        var offenders: [String] = []
        for url in try swiftFiles(in: sourcesRoot) where !catalogueFiles.contains(url.lastPathComponent) {
            let source = try String(contentsOf: url, encoding: .utf8)
            if untypedCall.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertEqual(offenders, [], "Track through the typed helpers in AnalyticsCatalogue.swift")
    }

    func testCatalogueEventsCarryOnlyListedValuesAndNoFreeText() {
        let analytics = RecordingCatalogueTracker()
        emitEveryCatalogueShape(into: analytics)

        XCTAssertFalse(analytics.events.isEmpty)
        for event in analytics.events {
            let properties = event.properties.compactMapValues { $0 }
            let context = "\(event.name) \(properties)"
            XCTAssertTrue(AnalyticsCatalogue.eventNames.contains(event.name), context)
            XCTAssertTrue(Self.freeTextKeys.isDisjoint(with: properties.keys), context)
            let errorCode = properties["error_code"] as? String
            switch event.name {
            case AnalyticsEventName.sdkPageViewed:
                XCTAssertTrue(Self.viewablePages.contains(properties["page_name"] as? String ?? ""), context)
                if let errorCode { XCTAssertTrue(Self.errorPageCodes.contains(errorCode), context) }
            case AnalyticsEventName.sdkAPIBackend:
                XCTAssertEqual(properties["api_path"] as? String, "/api/public/v1/order/:order_id", context)
                XCTAssertEqual(properties["http_method"] as? String, "GET", context)
                XCTAssertTrue(["succeeded", "failed"].contains(properties["status"] as? String ?? ""), context)
                if let errorCode { XCTAssertTrue(Self.apiErrorCodes.contains(errorCode), context) }
            case AnalyticsEventName.sdkActionSubmitted:
                XCTAssertEqual(properties["action_name"] as? String, "bank_redirect", context)
            case AnalyticsEventName.sdkActionFailed:
                let action = properties["action_name"] as? String ?? ""
                XCTAssertTrue(Self.errorCodesByAction[action]?.contains(errorCode ?? "") == true, context)
            case AnalyticsEventName.sdkCTAClicked:
                XCTAssertTrue(["retry", "back_to_checkout"].contains(properties["cta_name"] as? String ?? ""), context)
            case AnalyticsEventName.sdkControlChanged:
                XCTAssertEqual(properties["control_name"] as? String, "color_scheme", context)
            case AnalyticsEventName.sdkCheckoutFailed:
                let details = Self.detailsByCheckoutFailure[errorCode ?? ""]
                XCTAssertNotNil(details, context)
                if let detail = properties["error_detail"] as? String {
                    XCTAssertTrue(details?.contains(detail) == true, context)
                }
            case AnalyticsEventName.sdkCheckoutClosed:
                XCTAssertTrue(["user_dismiss", "merchant", "sdk"].contains(properties["trigger"] as? String ?? ""), context)
                if let paymentEvent = properties["payment_event"] as? String {
                    XCTAssertTrue(Self.paymentEvents.contains(paymentEvent), context)
                    XCTAssertNotNil(properties["had_listener"] as? Bool, context)
                }
            default:
                break
            }
        }
    }

    private func emitEveryCatalogueShape(into analytics: AnalyticsTracking) {
        analytics.trackSDKLoaded()
        for page in [AnalyticsPageName.checkout, .bankRedirect, .educationCarousel] {
            analytics.trackPageViewed(page, urlOrigin: "https://bank.example")
        }
        for code in AnalyticsErrorPageCode.allCases {
            analytics.trackPageViewed(.error, errorCode: code)
        }
        analytics.trackOrderFetchSucceeded(httpStatus: 200)
        for error in AnalyticsAPIError.allCases {
            analytics.trackOrderFetchFailed(error, httpStatus: 500)
        }
        analytics.trackBankRedirectSubmitted(urlOrigin: "https://bank.example")
        for error in AnalyticsLoadError.allCases {
            for webViewType in AnalyticsWebViewType.allCases {
                analytics.trackActionFailed(.webViewLoad(
                    error,
                    webViewType: webViewType,
                    httpStatus: 503,
                    isRecoverable: true,
                    urlOrigin: "https://bank.example"
                ))
            }
        }
        for error in AnalyticsNavigationError.allCases {
            analytics.trackActionFailed(.navigation(error, scheme: "upi", webViewType: .flow))
        }
        for error in AnalyticsPaymentPayloadError.allCases {
            for pageEvent in AnalyticsPaymentEvent.allCases {
                analytics.trackActionFailed(.paymentPayload(error, pageEvent: pageEvent))
            }
        }
        for error in AnalyticsEducationCarouselError.allCases {
            analytics.trackActionFailed(.educationCarousel(error))
        }
        for cta in AnalyticsCTAName.allCases {
            for page in AnalyticsPageName.allCases {
                analytics.trackCTAClicked(cta, page: page)
            }
        }
        analytics.trackColorSchemeChanged(newValue: "dark", previousValue: "light", appColorScheme: "auto")
        AnalyticsInvalidInitParams.allCases.forEach { analytics.trackCheckoutFailed(.invalidInitParams($0)) }
        analytics.trackCheckoutFailed(.dependenciesFailedToLoad)
        AnalyticsComplianceBlock.allCases.forEach { analytics.trackCheckoutFailed(.complianceBlocked($0)) }
        AnalyticsOrderFetchFailure.allCases.forEach { analytics.trackCheckoutFailed(.orderFetchFailed($0)) }
        analytics.trackCheckoutFailed(.openTimeout(lastStep: "navigation_finished"))
        AnalyticsConnectionFailure.allCases.forEach { analytics.trackCheckoutFailed(.connectionError($0)) }
        for trigger in AnalyticsCloseTrigger.allCases {
            for page in AnalyticsPageName.allCases {
                analytics.trackCheckoutClosed(trigger, page: page)
            }
        }
        for paymentEvent in AnalyticsPaymentEvent.allCases {
            analytics.trackCheckoutClosed(.sdk, page: .checkout, paymentEvent: paymentEvent, hadListener: false)
        }
    }

    private func declaredEventNames() throws -> Set<String> {
        let trackerURL = Self.repositoryRoot.appendingPathComponent("Sources/GlomoPaySDK/Analytics/AnalyticsTracker.swift")
        let source = try String(contentsOf: trackerURL, encoding: .utf8)
        let block = try XCTUnwrap(
            source.components(separatedBy: "enum AnalyticsEventName {").dropFirst().first?
                .components(separatedBy: "\n}\n").first
        )
        let expression = try NSRegularExpression(pattern: #"static let [A-Za-z0-9_]+ = "([^"]+)""#)
        let matches = expression.matches(in: block, range: NSRange(block.startIndex..., in: block))
        return Set(matches.compactMap { match in
            Range(match.range(at: 1), in: block).map { String(block[$0]) }
        })
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw NSError(domain: "AnalyticsCatalogueTests", code: 1)
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let viewablePages: Set<String> = ["checkout", "bank_redirect", "education_carousel", "error"]
    private static let errorPageCodes: Set<String> = [
        "connection_error", "http_error", "webview_error", "content_process_terminated", "open_timeout", "other",
    ]
    private static let paymentEvents: Set<String> = [
        "payment_success", "payment_failure", "payment_pending", "bank_transfer_submitted",
    ]
    private static let apiErrorCodes: Set<String> = ["timeout", "network", "http_error", "invalid_response"]
    private static let freeTextKeys: Set<String> = [
        "error_message", "error_description", "reason", "message", "data", "url", "checkout_url", "errors",
    ]
    private static let errorCodesByAction: [String: Set<String>] = [
        "bank_redirect": [],
        "document_upload": ["picker_error"],
        "document_save": ["fetch_failed", "too_large", "save_failed", "unavailable", "rejected"],
        "device_permission": ["permission_denied"],
        "webview_load": ["connection_error", "http_error", "webview_error", "content_process_terminated"],
        "navigation": ["non_http_scheme", "external_host", "invalid_window_open_url"],
        "payment_payload": ["incomplete", "dropped"],
        "education_carousel": ["webview_error", "content_process_terminated", "render_failed", "other"],
        "page_load": [],
    ]
    private static let detailsByCheckoutFailure: [String: Set<String>] = [
        "invalid_init_params": ["invalid_public_key", "missing_order_id", "invalid_order_id", "invalid_server", "other"],
        "dependencies_failed_to_load": [],
        "compliance_blocked": ["jailbreak_detected", "root_detected", "debugger_attached"],
        "order_fetch_failed": ["timeout", "http_4xx", "http_5xx", "network", "invalid_response", "other"],
        "open_timeout": [],
        "connection_error": ["http_4xx", "http_5xx", "network"],
    ]
}

private final class RecordingCatalogueTracker: AnalyticsTracking {
    struct RecordedEvent { let name: String; let properties: [String: Any?] }
    var events: [RecordedEvent] = []
    func track(_ event: String, properties: [String: Any?]) {
        events.append(RecordedEvent(name: event, properties: properties))
    }
    func updateFlowType(_ flowType: String) {}
}
