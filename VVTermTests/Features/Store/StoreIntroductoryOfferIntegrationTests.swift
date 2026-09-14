import XCTest
import StoreKit
import StoreKitTest
@testable import VVTerm

@MainActor
final class StoreIntroductoryOfferIntegrationTests: XCTestCase {
    func testMonthlyTrialComesFromStoreKitAndRefreshesAfterOfferChange() async throws {
        let client = AppStoreKitClient()
        try await withMonthlyOffer(mode: "free", period: "P3D", price: "0") { _ in
            let offer = try await self.loadedOffer(client)
            XCTAssertEqual(offer.paymentMode, .freeTrial)
            XCTAssertEqual(offer.periodUnit, .day)
            XCTAssertEqual(offer.periodValue, 3)
        }
        try await withMonthlyOffer(mode: "free", period: "P2W", price: "0") { _ in
            let offer = try await self.loadedOffer(client)
            XCTAssertEqual(offer.periodUnit, .week)
            XCTAssertEqual(offer.periodValue, 2)
        }
    }

    func testRemovedOfferIsClearedOnReload() async throws {
        let client = AppStoreKitClient()
        try await withMonthlyOffer(mode: "free", period: "P3D", price: "0") { _ in
            _ = try await self.loadedOffer(client)
        }
        let session = try SKTestSession(configurationFileNamed: "VVTermStoreKit")
        session.clearTransactions()
        defer { session.clearTransactions() }
        let products = try await client.products(for: VVTermProducts.allProducts)
        let monthly = try XCTUnwrap(products.first { $0.id == VVTermProducts.proMonthly })
        XCTAssertEqual(monthly.introductoryOfferState, .unavailable)
    }

    func testMonthlyUpFrontPriceComesFromStoreKit() async throws {
        try await withMonthlyOffer(mode: "payUpFront", period: "P3M", price: "0.99") { _ in
            let offer = try await self.loadedOffer(AppStoreKitClient())
            XCTAssertEqual(offer.paymentMode, .payUpFront)
            XCTAssertEqual(offer.displayPrice, "$0.99")
            XCTAssertEqual(offer.periodUnit, .month)
            XCTAssertEqual(offer.totalPeriodValue, 3)
            XCTAssertEqual(offer.periodCount, 1)
        }
    }

    func testMonthlyRepeatedPriceUsesStoreKitPeriodCount() async throws {
        try await withMonthlyOffer(mode: "payAsYouGo", period: "P1M", price: "0.99", count: 3) { _ in
            let offer = try await self.loadedOffer(AppStoreKitClient())
            XCTAssertEqual(offer.paymentMode, .payAsYouGo)
            XCTAssertEqual(offer.displayPrice, "$0.99")
            XCTAssertEqual(offer.periodValue, 1)
            XCTAssertEqual(offer.periodCount, 3)
            XCTAssertEqual(offer.totalPeriodValue, 3)
        }
    }

    func testConsumedIntroductoryOfferIsNotAdvertisedForEitherPlan() async throws {
        try await withMonthlyOffer(mode: "free", period: "P3D", price: "0") { _ in
            let result = try await AppStoreKitClient().purchase(productId: VVTermProducts.proMonthly)
            XCTAssertEqual(result, .verified(productId: VVTermProducts.proMonthly))
            var products: [StoreProduct] = []
            for _ in 0..<50 {
                products = try await AppStoreKitClient().products(for: VVTermProducts.allProducts)
                if products.filter({ $0.id != VVTermProducts.proLifetime }).allSatisfy({ $0.introductoryOfferState == .ineligible }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            for id in [VVTermProducts.proMonthly, VVTermProducts.proYearly] {
                let product = try XCTUnwrap(products.first { $0.id == id })
                XCTAssertEqual(product.introductoryOfferState, .ineligible)
            }
        }
    }

    private func loadedOffer(_ client: AppStoreKitClient) async throws -> StoreIntroductoryOffer {
        let products = try await client.products(for: VVTermProducts.allProducts)
        let monthly = try XCTUnwrap(products.first { $0.id == VVTermProducts.proMonthly })
        let lifetime = try XCTUnwrap(products.first { $0.id == VVTermProducts.proLifetime })
        XCTAssertEqual(lifetime.introductoryOfferState, .unavailable)
        let offer: StoreIntroductoryOffer?
        if case .eligible(let terms) = monthly.introductoryOfferState {
            offer = terms
        } else {
            offer = nil
        }
        return try XCTUnwrap(offer, "Monthly offer is not eligible: \(monthly.introductoryOfferState)")
    }

    private func withMonthlyOffer(
        mode: String,
        period: String,
        price: String,
        count: Int = 1,
        operation: (SKTestSession) async throws -> Void
    ) async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "VVTermStoreKit", withExtension: "storekit"))
        var configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        var groups = try XCTUnwrap(configuration["subscriptionGroups"] as? [[String: Any]])
        let groupIndex = try XCTUnwrap(groups.indices.first)
        var subscriptions = try XCTUnwrap(groups[groupIndex]["subscriptions"] as? [[String: Any]])
        // A new group prevents StoreKit eligibility caches from crossing test sessions.
        let groupID = UUID().uuidString
        groups[groupIndex]["id"] = groupID
        for index in subscriptions.indices {
            subscriptions[index]["subscriptionGroupID"] = groupID
        }
        let index = try XCTUnwrap(subscriptions.firstIndex { $0["productID"] as? String == VVTermProducts.proMonthly })
        subscriptions[index]["introductoryOffers"] = [[
            "internalID": "MONTHLYTESTOFFER",
            "paymentMode": mode,
            "subscriptionPeriod": period,
            "displayPrice": price,
            "numberOfPeriods": count
        ]]
        groups[groupIndex]["subscriptions"] = subscriptions
        configuration["subscriptionGroups"] = groups
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).storekit")
        try JSONSerialization.data(withJSONObject: configuration).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        try await operation(session)
    }
}
