import XCTest
@testable import VVTerm

@MainActor
final class StoreManagerLifecycleTests: XCTestCase {
    private let monthlyProduct = StoreProduct(
        id: VVTermProducts.proMonthly,
        displayName: "Monthly",
        displayPrice: "$6.49"
    )

    func testVerifiedPurchaseRefreshesEntitlementsAndCompletesPurchase() async {
        let client = StoreClientFake()
        client.purchaseResult = .verified(productId: VVTermProducts.proMonthly)
        client.entitlementResult = entitlementResult(productIds: [VVTermProducts.proMonthly])
        let manager = StoreManager(client: client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .purchased)
        XCTAssertEqual(manager.lastPurchasedProductId, VVTermProducts.proMonthly)
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(client.purchasedProductIds, [VVTermProducts.proMonthly])
        XCTAssertEqual(client.entitlementRequestCount, 1)
    }

    func testUnverifiedPurchaseFailsWithoutGrantingAccess() async {
        let client = StoreClientFake()
        client.purchaseResult = .unverified(productId: VVTermProducts.proMonthly)
        let manager = StoreManager(client: client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(
            manager.purchaseState,
            .failed(StoreError.verificationFailed.localizedDescription)
        )
        XCTAssertNil(manager.lastPurchasedProductId)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testUserCancelledPurchaseReturnsToIdle() async {
        let client = StoreClientFake()
        client.purchaseResult = .userCancelled
        let manager = StoreManager(client: client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertNil(manager.lastPurchasedProductId)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testPendingPurchaseReturnsToIdleWithoutGrantingAccess() async {
        let client = StoreClientFake()
        client.purchaseResult = .pending
        let manager = StoreManager(client: client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testRestoreSyncsAndAppliesLifetimeEntitlement() async {
        let client = StoreClientFake()
        client.entitlementResult = entitlementResult(productIds: [VVTermProducts.proLifetime])
        let manager = StoreManager(client: client)

        await manager.restorePurchases()

        XCTAssertEqual(client.syncCount, 1)
        XCTAssertEqual(manager.restoreState, .restored(hasAccess: true))
        XCTAssertTrue(manager.isPro)
        XCTAssertTrue(manager.isLifetime)
    }

    func testVerifiedGraceAndBillingRetryStatesKeepAccess() async {
        for state in [StoreSubscriptionState.inGracePeriod, .inBillingRetryPeriod] {
            let client = StoreClientFake()
            client.entitlementResult = StoreEntitlementResult(
                verifiedProductIds: [],
                subscriptionEntitlements: [
                    StoreSubscriptionEntitlement(state: state, isVerified: true)
                ],
                subscriptionStatus: nil
            )
            let manager = StoreManager(client: client)

            await manager.checkEntitlements()

            XCTAssertTrue(manager.isPro, "Expected access for \(state)")
            XCTAssertFalse(manager.isLifetime)
        }
    }

    func testUnverifiedRecoverableSubscriptionStateDoesNotGrantAccess() async {
        let client = StoreClientFake()
        client.entitlementResult = StoreEntitlementResult(
            verifiedProductIds: [],
            subscriptionEntitlements: [
                StoreSubscriptionEntitlement(state: .inGracePeriod, isVerified: false)
            ],
            subscriptionStatus: nil
        )
        let manager = StoreManager(client: client)

        await manager.checkEntitlements()

        XCTAssertFalse(manager.isPro)
    }

    func testUnknownPurchaseReturnsToIdleWithoutRefreshingEntitlements() async {
        let client = StoreClientFake()
        client.purchaseResult = .unknown
        let manager = StoreManager(client: client)

        await manager.purchase(monthlyProduct)

        XCTAssertEqual(manager.purchaseState, .idle)
        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testStartLoadsProductsThenEntitlementsAndIsIdempotent() async {
        let client = StoreClientFake()
        client.loadedProducts = [monthlyProduct]
        client.entitlementResult = entitlementResult(productIds: [VVTermProducts.proMonthly])
        let started = expectation(description: "Startup completed")
        client.onEntitlementRequest = { started.fulfill() }
        let manager = StoreManager(client: client)

        manager.start()
        manager.start()
        await fulfillment(of: [started], timeout: 1)
        await Task.yield()

        XCTAssertEqual(manager.products, [monthlyProduct])
        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(client.events, ["updates", "products", "entitlements"])
        XCTAssertEqual(client.transactionUpdateRequestCount, 1)
        manager.stop()
    }

    func testUnverifiedUpdateIsIgnoredBeforeVerifiedUpdateRefreshesEntitlements() async {
        let client = StoreClientFake()
        client.entitlementResults = [
            .free,
            entitlementResult(productIds: [VVTermProducts.proMonthly])
        ]
        let startup = expectation(description: "Startup entitlements checked")
        let update = expectation(description: "Update entitlements checked")
        client.onEntitlementRequest = {
            if client.entitlementRequestCount == 1 {
                startup.fulfill()
            } else if client.entitlementRequestCount == 2 {
                update.fulfill()
            }
        }
        let manager = StoreManager(client: client)

        manager.start()
        await fulfillment(of: [startup], timeout: 1)
        client.emit(.unverified(productId: VVTermProducts.proMonthly))
        client.emit(.verified(productId: VVTermProducts.proMonthly))
        await fulfillment(of: [update], timeout: 1)
        await Task.yield()

        XCTAssertTrue(manager.isPro)
        XCTAssertEqual(client.entitlementRequestCount, 2)
        manager.stop()
    }

    func testStopCancelsTransactionStream() async {
        let client = StoreClientFake()
        let terminated = expectation(description: "Transaction stream terminated")
        client.onTransactionStreamTermination = { terminated.fulfill() }
        let manager = StoreManager(client: client)

        manager.start()
        manager.stop()
        await fulfillment(of: [terminated], timeout: 1)

        XCTAssertEqual(client.transactionStreamTerminationCount, 1)
    }

    func testStopCancelsStartupBeforeEntitlements() async {
        let client = StoreClientFake()
        let productLoadStarted = expectation(description: "Product load started")
        let productLoadCancelled = expectation(description: "Product load cancelled")
        client.productsHandler = {
            productLoadStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            } catch {
                productLoadCancelled.fulfill()
                throw CancellationError()
            }
        }
        let manager = StoreManager(client: client)

        manager.start()
        await fulfillment(of: [productLoadStarted], timeout: 1)
        manager.stop()
        await fulfillment(of: [productLoadCancelled], timeout: 1)

        XCTAssertEqual(client.entitlementRequestCount, 0)
    }

    func testOwnerReleaseCancelsStartupAndTransactionStream() async {
        let client = StoreClientFake()
        let productLoadStarted = expectation(description: "Product load started")
        let productLoadCancelled = expectation(description: "Product load cancelled")
        let streamTerminated = expectation(description: "Transaction stream terminated")
        client.productsHandler = {
            productLoadStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            } catch {
                productLoadCancelled.fulfill()
                throw CancellationError()
            }
        }
        client.onTransactionStreamTermination = { streamTerminated.fulfill() }
        var manager: StoreManager? = StoreManager(client: client)
        weak var weakManager = manager

        manager?.start()
        await fulfillment(of: [productLoadStarted], timeout: 1)
        manager = nil
        await fulfillment(
            of: [productLoadCancelled, streamTerminated],
            timeout: 1
        )

        XCTAssertNil(weakManager)
    }

    func testOwnerReleaseAfterStartupCompletesTerminatesTransactionStream() async {
        let client = StoreClientFake()
        client.loadedProducts = [monthlyProduct]
        client.entitlementResult = entitlementResult(
            productIds: [VVTermProducts.proMonthly]
        )
        let startupCompleted = expectation(description: "Startup completed")
        let streamTerminated = expectation(description: "Transaction stream terminated")
        client.onEntitlementRequest = { startupCompleted.fulfill() }
        client.onTransactionStreamTermination = { streamTerminated.fulfill() }
        var manager: StoreManager? = StoreManager(client: client)
        weak var weakManager = manager

        manager?.start()
        await fulfillment(of: [startupCompleted], timeout: 1)
        await Task.yield()
        XCTAssertTrue(manager?.isPro == true)
        manager = nil
        await fulfillment(of: [streamTerminated], timeout: 1)

        XCTAssertNil(weakManager)
        XCTAssertEqual(client.entitlementRequestCount, 1)
        XCTAssertEqual(client.transactionStreamTerminationCount, 1)
    }

    private func entitlementResult(productIds: Set<String>) -> StoreEntitlementResult {
        StoreEntitlementResult(
            verifiedProductIds: productIds,
            subscriptionEntitlements: [],
            subscriptionStatus: nil
        )
    }
}

@MainActor
private final class StoreClientFake: StoreClient {
    var loadedProducts: [StoreProduct] = []
    var purchaseResult: StorePurchaseResult = .pending
    var entitlementResult = StoreEntitlementResult.free
    var entitlementResults: [StoreEntitlementResult] = []
    var introductoryOfferState: ProPlanIntroductoryOfferState = .unavailable
    var onEntitlementRequest: (() -> Void)?
    var onTransactionStreamTermination: (() -> Void)?
    var productsHandler: (() async throws -> [StoreProduct])?

    private(set) var events: [String] = []
    private(set) var purchasedProductIds: [String] = []
    private(set) var syncCount = 0
    private(set) var entitlementRequestCount = 0
    private(set) var transactionUpdateRequestCount = 0
    private(set) var transactionStreamTerminationCount = 0

    private var updatesContinuation: AsyncStream<StoreTransactionUpdate>.Continuation?

    func products(for identifiers: [String]) async throws -> [StoreProduct] {
        events.append("products")
        if let productsHandler {
            return try await productsHandler()
        }
        return loadedProducts.filter { identifiers.contains($0.id) }
    }

    func purchase(productId: String) async throws -> StorePurchaseResult {
        purchasedProductIds.append(productId)
        return purchaseResult
    }

    func sync() async throws {
        syncCount += 1
    }

    func entitlements(subscriptionProductIds: [String]) async -> StoreEntitlementResult {
        events.append("entitlements")
        entitlementRequestCount += 1
        onEntitlementRequest?()
        if !entitlementResults.isEmpty {
            return entitlementResults.removeFirst()
        }
        return entitlementResult
    }

    func introductoryOfferState(productId: String) async -> ProPlanIntroductoryOfferState {
        introductoryOfferState
    }

    func transactionUpdates() -> AsyncStream<StoreTransactionUpdate> {
        events.append("updates")
        transactionUpdateRequestCount += 1
        return AsyncStream { continuation in
            updatesContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    transactionStreamTerminationCount += 1
                    onTransactionStreamTermination?()
                }
            }
        }
    }

    func emit(_ update: StoreTransactionUpdate) {
        updatesContinuation?.yield(update)
    }
}
