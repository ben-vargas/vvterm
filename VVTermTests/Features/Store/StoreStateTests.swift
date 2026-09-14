import XCTest
import StoreKit
import StoreKitTest
@testable import VVTerm

@MainActor
final class StoreStateTests: XCTestCase {
    private var sevenDayTrial: StoreIntroductoryOffer {
        StoreIntroductoryOffer(paymentMode: .freeTrial, displayPrice: "$0.00", periodUnit: .day, periodValue: 7, periodCount: 1)!
    }

    func testEntitlementSnapshotDerivesFreeAndProAccess() {
        let free = StoreEntitlementSnapshot.free
        let paid = StoreEntitlementSnapshot(
            accessState: .pro,
            hasLifetimeAccess: false,
            subscriptionStatus: nil
        )

        XCTAssertEqual(StoreEntitlementSnapshot.checking.accessState, .checking)
        XCTAssertFalse(free.hasStoreAccess)
        XCTAssertTrue(paid.hasStoreAccess)
    }

    func testPurchaseStateEqualityMatchesAssociatedMessage() {
        XCTAssertEqual(PurchaseState.failed("A"), PurchaseState.failed("A"))
        XCTAssertNotEqual(PurchaseState.failed("A"), PurchaseState.failed("B"))
    }

    func testRestoreStateEqualityMatchesAssociatedValues() {
        XCTAssertEqual(RestoreState.restored(hasAccess: true), RestoreState.restored(hasAccess: true))
        XCTAssertNotEqual(RestoreState.restored(hasAccess: true), RestoreState.restored(hasAccess: false))
    }

    func testStoreErrorFormatsPurchaseFailureMessage() {
        let error = StoreError.purchaseFailed("network")

        XCTAssertEqual(error.errorDescription, "Purchase failed: network")
    }

    func testEligibleYearlyPresentationAdvertisesSevenDayFreeTrial() {
        let presentation = ProPlanPresentation(
            plan: .yearly,
            displayPrice: "$24.99",
            introductoryOfferState: .eligible(sevenDayTrial)
        )

        XCTAssertEqual(presentation.priceLine, "Free trial: 7 days")
        XCTAssertEqual(presentation.detail, "Then $24.99 per year.")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Start Free Trial")
        XCTAssertEqual(
            presentation.renewalDisclosure,
            "Free trial: 7 days. Then $24.99 per year. Auto-renews until canceled."
        )
        XCTAssertTrue(presentation.planAccessibilityLabel.contains("$24.99"))
        XCTAssertTrue(presentation.purchaseButtonAccessibilityLabel.contains("Free trial: 7 days"))
    }

    func testIneligibleYearlyPresentationKeepsStandardSubscriptionCopy() {
        let presentation = ProPlanPresentation(
            plan: .yearly,
            displayPrice: "$24.99",
            introductoryOfferState: .ineligible
        )

        XCTAssertEqual(presentation.priceLine, "$24.99 per year")
        XCTAssertEqual(presentation.detail, "Best value for ongoing terminal work.")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Subscribe for $24.99")
        XCTAssertEqual(presentation.renewalDisclosure, "Auto-renews until canceled.")
    }

    func testUnavailableYearlyOfferMetadataKeepsStandardSubscriptionCopy() {
        let presentation = ProPlanPresentation(
            plan: .yearly,
            displayPrice: "$24.99",
            introductoryOfferState: .unavailable
        )

        XCTAssertEqual(presentation.priceLine, "$24.99 per year")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Subscribe for $24.99")
        XCTAssertEqual(presentation.renewalDisclosure, "Auto-renews until canceled.")
    }

    func testEligibleMonthlyTrialIsPresented() {
        let presentation = ProPlanPresentation(
            plan: .monthly,
            displayPrice: "$6.49",
            introductoryOfferState: .eligible(sevenDayTrial)
        )

        XCTAssertEqual(presentation.introductoryOfferState, .eligible(sevenDayTrial))
        XCTAssertTrue(presentation.priceLine.contains("7"))
        XCTAssertTrue(presentation.detail.contains("$6.49"))
    }

    func testStoreKitConfigurationProvidesEligibleSevenDayYearlyTrial() async throws {
        let session = try SKTestSession(configurationFileNamed: "VVTermStoreKit")
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let products = try await Product.products(for: [VVTermProducts.proYearly])
        let product = try XCTUnwrap(products.first)
        let subscription = try XCTUnwrap(product.subscription)
        let offer = try XCTUnwrap(subscription.introductoryOffer)

        XCTAssertEqual(offer.paymentMode, .freeTrial)
        switch offer.period.unit {
        case .day:
            XCTAssertEqual(offer.period.value, 7)
        case .week:
            XCTAssertEqual(offer.period.value, 1)
        default:
            XCTFail("The introductory offer is not seven days")
        }
        XCTAssertEqual(offer.periodCount, 1)
        let isEligible = await subscription.isEligibleForIntroOffer
        XCTAssertTrue(isEligible)
    }
}
