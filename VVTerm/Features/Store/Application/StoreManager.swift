import Foundation
import Combine
import os.log

struct StoreEntitlementSnapshot {
    static let free = StoreEntitlementSnapshot(
        hasStoreAccess: false,
        hasLifetimeAccess: false,
        subscriptionStatus: nil
    )

    let hasStoreAccess: Bool
    let hasLifetimeAccess: Bool
    let subscriptionStatus: StoreSubscriptionStatus?
}

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var entitlementSnapshot = StoreEntitlementSnapshot.free
    @Published var products: [StoreProduct] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var restoreState: RestoreState = .idle
    @Published private(set) var lastPurchasedProductId: String?
    private(set) var activePaywallSource: PaywallSource = .general
    private(set) var hasPresentedPaywallThisLaunch = false

    private var startupTask: Task<Void, Never>?
    private var updateListenerTask: Task<Void, Never>?
    private let client: any StoreClient
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VVTerm",
        category: "Store"
    )

    var isPro: Bool {
        entitlementSnapshot.hasStoreAccess
    }

    var isLifetime: Bool {
        entitlementSnapshot.hasLifetimeAccess
    }

    var subscriptionStatus: StoreSubscriptionStatus? {
        entitlementSnapshot.subscriptionStatus
    }

    // MARK: - Sorted Products

    var monthlyProduct: StoreProduct? {
        products.first { $0.id == VVTermProducts.proMonthly }
    }

    var yearlyProduct: StoreProduct? {
        products.first { $0.id == VVTermProducts.proYearly }
    }

    var lifetimeProduct: StoreProduct? {
        products.first { $0.id == VVTermProducts.proLifetime }
    }

    // MARK: - Initialization

    init(client: any StoreClient) {
        self.client = client
    }

    func start() {
        guard startupTask == nil, updateListenerTask == nil else { return }
        startTransactionListener()
        let client = self.client
        let logger = self.logger
        startupTask = Task { [weak self, client, logger] in
            guard let products = await Self.loadProducts(using: client, logger: logger),
                  !Task.isCancelled else { return }
            self?.products = products

            let result = await client.entitlements(
                subscriptionProductIds: Self.subscriptionProductIds
            )
            guard !Task.isCancelled else { return }
            self?.applyEntitlementResult(result)
        }
    }

    func stop() {
        startupTask?.cancel()
        updateListenerTask?.cancel()
        startupTask = nil
        updateListenerTask = nil
    }

    deinit {
        startupTask?.cancel()
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        guard let loadedProducts = await Self.loadProducts(using: client, logger: logger) else {
            return
        }
        products = loadedProducts
    }

    private static func loadProducts(
        using client: any StoreClient,
        logger: Logger
    ) async -> [StoreProduct]? {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                let products = try await client.products(for: VVTermProducts.allProducts)
                try Task.checkCancellation()
                logger.info("Loaded \(products.count) products")
                return products
            } catch is CancellationError {
                return nil
            } catch {
                logger.error("Failed to load products (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        )
                    } catch {
                        return nil
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Paywall Presentation

    func notePaywallPresented(source: PaywallSource) {
        activePaywallSource = source
        hasPresentedPaywallThisLaunch = true
        EngagementTracker.shared.notePaywallPresented()
        AnalyticsTracker.shared.trackPaywallViewed(source: source.rawValue)
    }

    func notePaywallCTATapped(product: StoreProduct) {
        AnalyticsTracker.shared.trackPaywallCTATapped(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
    }

    func introductoryOfferState(for product: StoreProduct) async -> ProPlanIntroductoryOfferState {
        await client.introductoryOfferState(productId: product.id)
    }

    // MARK: - Purchase

    func purchase(_ product: StoreProduct) async {
        purchaseState = .purchasing
        lastPurchasedProductId = nil
        AnalyticsTracker.shared.trackPurchaseStarted(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await client.purchase(productId: product.id)

            switch result {
            case .verified:
                await checkEntitlements()
                applySuccessfulPurchase(of: product)

            case .unverified(let productId):
                logger.error(
                    "StoreKit transaction verification failed for product \(productId, privacy: .public)"
                )
                throw StoreError.verificationFailed

            case .userCancelled:
                AnalyticsTracker.shared.trackPurchaseCancelled(
                    source: activePaywallSource.rawValue,
                    productId: product.id
                )
                applyIdlePurchaseState(logMessage: "Purchase cancelled by user")

            case .pending:
                AnalyticsTracker.shared.trackPurchasePending(
                    source: activePaywallSource.rawValue,
                    productId: product.id
                )
                applyIdlePurchaseState(logMessage: "Purchase pending")

            case .unknown:
                purchaseState = .idle
            }
        } catch {
            AnalyticsTracker.shared.trackPurchaseFailed(
                source: activePaywallSource.rawValue,
                productId: product.id,
                reason: String(describing: type(of: error))
            )
            purchaseState = .failed(error.localizedDescription)
            logger.error("Purchase failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        restoreState = .restoring
        logger.info("Restoring purchases")
        do {
            try await client.sync()
            await checkEntitlements()
            applyRestoreResult(hasAccess: isPro)
        } catch {
            restoreState = .failed(error.localizedDescription)
            logger.error("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        let result = await client.entitlements(
            subscriptionProductIds: Self.subscriptionProductIds
        )
        applyEntitlementResult(result)
    }

    private func applyEntitlementResult(_ result: StoreEntitlementResult) {
        let hasLifetime = result.verifiedProductIds.contains(VVTermProducts.proLifetime)
        let hasVerifiedSubscription = result.verifiedProductIds.contains(VVTermProducts.proMonthly)
            || result.verifiedProductIds.contains(VVTermProducts.proYearly)
        let hasRecoverableSubscription = result.subscriptionEntitlements.contains {
            $0.isVerified && ($0.state == .inBillingRetryPeriod || $0.state == .inGracePeriod)
        }

        applyEntitlements(
            hasAccess: hasLifetime || hasVerifiedSubscription || hasRecoverableSubscription,
            hasLifetime: hasLifetime,
            status: result.subscriptionStatus
        )
    }

    // MARK: - Transaction Listener

    private func startTransactionListener() {
        guard updateListenerTask == nil else { return }
        let updates = client.transactionUpdates()
        updateListenerTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                switch update {
                case .verified:
                    await checkEntitlements()
                case .unverified(let productId):
                    logger.error(
                        "Ignored unverified StoreKit update for product \(productId, privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - Subscription Info

    var subscriptionExpirationDate: Date? {
        subscriptionStatus?.expirationDate
    }

    var isSubscriptionActive: Bool {
        guard let status = subscriptionStatus else { return isLifetime }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    var hasActiveSubscriptionWithLifetime: Bool {
        guard isLifetime, let status = subscriptionStatus else { return false }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    private func applySuccessfulPurchase(of product: StoreProduct) {
        lastPurchasedProductId = product.id
        purchaseState = .purchased
        AnalyticsTracker.shared.trackPurchaseSucceeded(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
        logger.info("Purchase successful: \(product.id)")
    }

    private func applyIdlePurchaseState(logMessage: String) {
        purchaseState = .idle
        logger.info("\(logMessage)")
    }

    private func applyRestoreResult(hasAccess: Bool) {
        restoreState = .restored(hasAccess: hasAccess)
        logger.info("Purchases restored")
    }

    private func applyEntitlements(
        hasAccess: Bool,
        hasLifetime: Bool,
        status: StoreSubscriptionStatus?
    ) {
        entitlementSnapshot = StoreEntitlementSnapshot(
            hasStoreAccess: hasAccess,
            hasLifetimeAccess: hasLifetime,
            subscriptionStatus: status
        )
        AnalyticsTracker.shared.trackAppLaunched(isPro: isPro)
        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime)")
    }

    private static let subscriptionProductIds = [
        VVTermProducts.proMonthly,
        VVTermProducts.proYearly
    ]
}
