import XCTest
import StoreKit
import StoreKitTest
@testable import VVTerm

@MainActor
final class StoreStateTests: XCTestCase {
    func testEntitlementSnapshotDerivesFreeAndProAccess() {
        let free = StoreEntitlementSnapshot.free
        let paid = StoreEntitlementSnapshot(
            hasStoreAccess: true,
            hasLifetimeAccess: false,
            subscriptionStatus: nil
        )

        XCTAssertFalse(free.hasProAccess(reviewModeEnabled: false))
        XCTAssertTrue(paid.hasProAccess(reviewModeEnabled: false))
    }

    func testReviewModeMasksLifetimeAndSubscriptionPresentation() {
        let lifetime = StoreEntitlementSnapshot(
            hasStoreAccess: true,
            hasLifetimeAccess: true,
            subscriptionStatus: nil
        )

        XCTAssertTrue(lifetime.hasProAccess(reviewModeEnabled: true))
        XCTAssertFalse(lifetime.isLifetimeAccessActive(reviewModeEnabled: true))
        XCTAssertNil(lifetime.visibleSubscriptionStatus(reviewModeEnabled: true))
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
            introductoryOfferState: .eligibleForSevenDayFreeTrial
        )

        XCTAssertEqual(presentation.priceLine, "7 days free")
        XCTAssertEqual(presentation.detail, "Then $24.99 per year.")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Start 7-Day Free Trial")
        XCTAssertEqual(
            presentation.renewalDisclosure,
            "7 days free, then $24.99 per year. Auto-renews until canceled."
        )
        XCTAssertTrue(presentation.planAccessibilityLabel.contains("$24.99"))
        XCTAssertTrue(presentation.purchaseButtonAccessibilityLabel.contains("7 days free"))
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

    func testTrialStateCannotLeakIntoOtherPlans() {
        let presentation = ProPlanPresentation(
            plan: .monthly,
            displayPrice: "$6.49",
            introductoryOfferState: .eligibleForSevenDayFreeTrial
        )

        XCTAssertEqual(presentation.introductoryOfferState, .unavailable)
        XCTAssertEqual(presentation.priceLine, "$6.49 per month")
        XCTAssertEqual(presentation.purchaseButtonTitle, "Subscribe for $6.49")
    }

    func testStoreKitConfigurationProvidesEligibleSevenDayYearlyTrial() async throws {
        let session = try SKTestSession(configurationFileNamed: "VVTermStoreKit")
        session.disableDialogs = true
        session.clearTransactions()

        let products = try await Product.products(for: [VVTermProducts.proYearly])
        let product = try XCTUnwrap(products.first)
        let subscription = try XCTUnwrap(product.subscription)
        let offer = try XCTUnwrap(subscription.introductoryOffer)

        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.value, 7)
        XCTAssertEqual(offer.period.unit, .day)
        XCTAssertEqual(offer.periodCount, 1)
        let isEligible = await subscription.isEligibleForIntroOffer
        XCTAssertTrue(isEligible)
    }
}
