import XCTest
@testable import VVTerm

@MainActor
final class StoreIntroductoryOfferTests: XCTestCase {
    func testThreeDayMonthlyTrialShowsDurationAndRenewal() throws {
        let presentation = try presentation(mode: .freeTrial, unit: .day, value: 3)
        XCTAssertEqual(presentation.priceLine, "Free trial: 3 days")
        XCTAssertEqual(presentation.detail, "Then $6.49 per month.")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Start Free Trial")
        XCTAssertEqual(presentation.renewalDisclosure, "Free trial: 3 days. Then $6.49 per month. Auto-renews until canceled.")
    }

    func testUpFrontOfferShowsOnePaymentAndFullDuration() throws {
        let presentation = try presentation(mode: .payUpFront, unit: .month, value: 3)
        XCTAssertEqual(presentation.priceLine, "$0.99 total")
        XCTAssertEqual(presentation.detail, "Offer duration: 3 months. Then $6.49 per month.")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Subscribe for $0.99")
        XCTAssertTrue(presentation.purchaseButtonAccessibilityLabel.contains(presentation.renewalDisclosure))
    }

    func testRepeatedOfferShowsPricePerPeriodAndTotalDuration() throws {
        let presentation = try presentation(mode: .payAsYouGo, unit: .month, value: 1, count: 3)
        XCTAssertEqual(presentation.priceLine, "$0.99 / 1 month")
        XCTAssertEqual(presentation.detail, "Offer duration: 3 months. Then $6.49 per month.")
        XCTAssertEqual(presentation.renewalDisclosure, "$0.99 / 1 month. Offer duration: 3 months. Then $6.49 per month. Auto-renews until canceled.")
    }

    func testAllPaymentModesSupportYearlyPlan() throws {
        for mode in [StoreIntroductoryOffer.PaymentMode.freeTrial, .payUpFront, .payAsYouGo] {
            let presentation = try presentation(mode: mode, unit: .week, value: 2, plan: .yearly)
            XCTAssertTrue(presentation.detail.contains("Then $24.99 per year."))
            XCTAssertFalse(presentation.renewalDisclosure.contains("per month"))
        }
    }

    func testOfferCannotLeakIntoLifetimePlan() throws {
        let presentation = try presentation(mode: .freeTrial, unit: .day, value: 3, plan: .lifetime)
        XCTAssertEqual(presentation.introductoryOfferState, .unavailable)
        XCTAssertEqual(presentation.priceLine, "$49.99 one time")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Buy $49.99")
    }

    func testIneligibleAndUnavailableMonthlyOffersUseNormalPrice() {
        for state in [ProPlanIntroductoryOfferState.ineligible, .unavailable] {
            let presentation = ProPlanPresentation(plan: .monthly, displayPrice: "$6.49", introductoryOfferState: state)
            XCTAssertEqual(presentation.priceLine, "$6.49 per month")
            XCTAssertEqual(presentation.purchaseButtonTitle, "Subscribe for $6.49")
        }
    }

    func testInvalidCountsAndOverflowAreRejected() {
        for (value, count) in [(0, 1), (-1, 1), (1, 0), (1, -1), (Int.max, 2), (2, Int.max)] {
            XCTAssertNil(StoreIntroductoryOffer(paymentMode: .payAsYouGo, displayPrice: "$0.99", periodUnit: .month, periodValue: value, periodCount: count))
        }
        for mode in [StoreIntroductoryOffer.PaymentMode.freeTrial, .payUpFront] {
            XCTAssertNil(StoreIntroductoryOffer(paymentMode: mode, displayPrice: "$0.99", periodUnit: .month, periodValue: 1, periodCount: 2))
        }
        let largest = StoreIntroductoryOffer(paymentMode: .payAsYouGo, displayPrice: "$0.99", periodUnit: .month, periodValue: Int.max, periodCount: 1)
        XCTAssertEqual(largest?.totalPeriodValue, Int.max)
    }

    func testCalendarUnitsArePreserved() throws {
        for (unit, expected) in [(StoreIntroductoryOffer.PeriodUnit.day, "6 days"), (.week, "6 weeks"), (.month, "6 months"), (.year, "6 years")] {
            let presentation = try presentation(mode: .payAsYouGo, unit: unit, value: 2, count: 3)
            XCTAssertTrue(presentation.detail.contains(expected))
        }
    }

    func testAllLanguagesFormatOfferTermsWithTheirOwnPluralRules() throws {
        let cases: [String: (String, String)] = [
            "en": ("3 days", "3 months"), "be": ("3 дні", "3 месяцы"),
            "cs": ("3 dny", "3 měsíce"), "de": ("3 Tage", "3 Monate"),
            "es": ("3 días", "3 meses"), "fr": ("3 jours", "3 mois"),
            "ja": ("3日", "3か月"), "ko": ("3일", "3개월"),
            "pl": ("3 dni", "3 miesiące"), "ru": ("3 дня", "3 месяца"),
            "uk": ("3 дні", "3 місяці"), "zh-Hans": ("3 天", "3 个月"),
            "th": ("3 วัน", "3 เดือน"), "vi": ("3 ngày", "3 tháng")
        ]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (language, expected) in cases {
            let bundle = try localizedBundle(language, in: temporary)
            let trial = try presentation(mode: .freeTrial, unit: .day, value: 3, bundle: bundle)
            let paid = try presentation(mode: .payAsYouGo, unit: .month, value: 1, count: 3, bundle: bundle)
            XCTAssertTrue(trial.priceLine.contains(expected.0), "\(language): \(trial.priceLine)")
            XCTAssertTrue(paid.detail.contains(expected.1), "\(language): \(paid.detail)")
            XCTAssertTrue(paid.renewalDisclosure.contains("$0.99"))
            XCTAssertTrue(paid.renewalDisclosure.contains("$6.49"))
            XCTAssertFalse(paid.renewalDisclosure.contains("%@"))
            if language != "en" {
                XCTAssertFalse(trial.priceLine.contains("Free trial"))
                XCTAssertFalse(paid.detail.contains("Offer duration"))
            }
        }
    }

    private func presentation(
        mode: StoreIntroductoryOffer.PaymentMode,
        unit: StoreIntroductoryOffer.PeriodUnit,
        value: Int,
        count: Int = 1,
        plan: ProPlanKind = .monthly,
        bundle: Bundle = .main
    ) throws -> ProPlanPresentation {
        let offer = try XCTUnwrap(StoreIntroductoryOffer(paymentMode: mode, displayPrice: "$0.99", periodUnit: unit, periodValue: value, periodCount: count))
        let price = plan == .monthly ? "$6.49" : plan == .yearly ? "$24.99" : "$49.99"
        return ProPlanPresentation(plan: plan, displayPrice: price, introductoryOfferState: .eligible(offer), bundle: bundle)
    }

    private func localizedBundle(_ language: String, in temporary: URL) throws -> Bundle {
        let path = temporary.appendingPathComponent("\(language).bundle")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.offers.\(language)", "CFBundleDevelopmentRegion": language]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Info.plist"))
        let source = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
        try FileManager.default.copyItem(at: source, to: path.appendingPathComponent("\(language).lproj"))
        return try XCTUnwrap(Bundle(url: path))
    }
}
