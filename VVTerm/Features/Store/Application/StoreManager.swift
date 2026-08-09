import StoreKit
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
    let subscriptionStatus: Product.SubscriptionInfo.Status?
}

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var entitlementSnapshot = StoreEntitlementSnapshot.free
    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var restoreState: RestoreState = .idle
    @Published private(set) var lastPurchasedProductId: String?
    private(set) var activePaywallSource: PaywallSource = .general
    private(set) var hasPresentedPaywallThisLaunch = false

    private var updateListenerTask: Task<Void, Error>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Store")

    var isPro: Bool {
        entitlementSnapshot.hasStoreAccess
    }

    var isLifetime: Bool {
        entitlementSnapshot.hasLifetimeAccess
    }

    var subscriptionStatus: Product.SubscriptionInfo.Status? {
        entitlementSnapshot.subscriptionStatus
    }

    // MARK: - Sorted Products

    var monthlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proMonthly }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proYearly }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == VVTermProducts.proLifetime }
    }

    // MARK: - Initialization

    private init() {
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await checkEntitlements()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                products = try await Product.products(for: VVTermProducts.allProducts)
                logger.info("Loaded \(self.products.count) products")
                return
            } catch {
                logger.error("Failed to load products (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Paywall Presentation

    func notePaywallPresented(source: PaywallSource) {
        activePaywallSource = source
        hasPresentedPaywallThisLaunch = true
        EngagementTracker.shared.notePaywallPresented()
        AnalyticsTracker.shared.trackPaywallViewed(source: source.rawValue)
    }

    func notePaywallCTATapped(product: Product) {
        AnalyticsTracker.shared.trackPaywallCTATapped(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
    }

    func introductoryOfferState(for product: Product) async -> ProPlanIntroductoryOfferState {
        guard product.id == VVTermProducts.proYearly,
              let subscription = product.subscription,
              let offer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial,
              offer.periodCount == 1,
              offer.period.isOneWeek else {
            return .unavailable
        }

        return await subscription.isEligibleForIntroOffer
            ? .eligibleForSevenDayFreeTrial
            : .ineligible
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        lastPurchasedProductId = nil
        AnalyticsTracker.shared.trackPurchaseStarted(
            source: activePaywallSource.rawValue,
            productId: product.id
        )
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                applySuccessfulPurchase(of: product)

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

            @unknown default:
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
            try await AppStore.sync()
            await checkEntitlements()
            applyRestoreResult(hasAccess: isPro)
        } catch {
            restoreState = .failed(error.localizedDescription)
            logger.error("Failed to restore purchases: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        var hasAccess = false
        var hasLifetime = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                switch transaction.productID {
                case VVTermProducts.proMonthly,
                     VVTermProducts.proYearly:
                    hasAccess = true
                case VVTermProducts.proLifetime:
                    hasAccess = true
                    hasLifetime = true
                default:
                    break
                }
            }
        }

        // Check subscription status for billing retry / grace period
        var activeStatus: Product.SubscriptionInfo.Status?
        if let product = monthlyProduct ?? yearlyProduct,
           let statuses = try? await product.subscription?.status {
            activeStatus = statuses.first {
                $0.state == .subscribed || $0.state == .inGracePeriod
            } ?? statuses.first

            if !hasAccess {
                for status in statuses {
                    if case .verified = status.transaction,
                       status.state == .inBillingRetryPeriod || status.state == .inGracePeriod {
                        hasAccess = true
                        break
                    }
                }
            }
        }

        applyEntitlements(hasAccess: hasAccess, hasLifetime: hasLifetime, status: activeStatus)
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await self.checkEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(let unverifiedValue, let verificationError):
            if let transaction = unverifiedValue as? Transaction {
                logger.error(
                    """
                    StoreKit transaction verification failed for product \
                    \(transaction.productID, privacy: .public), transaction \
                    \(String(transaction.id), privacy: .public): \
                    \(String(describing: verificationError), privacy: .public)
                    """
                )
            } else {
                logger.error(
                    """
                    StoreKit verification failed for \
                    \(String(describing: T.self), privacy: .public): \
                    \(String(describing: verificationError), privacy: .public)
                    """
                )
            }
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Subscription Info

    var subscriptionExpirationDate: Date? {
        guard let status = subscriptionStatus else { return nil }
        guard case .verified(let transaction) = status.transaction else { return nil }
        return transaction.expirationDate
    }

    var isSubscriptionActive: Bool {
        guard let status = subscriptionStatus else { return isLifetime }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    var hasActiveSubscriptionWithLifetime: Bool {
        guard isLifetime, let status = subscriptionStatus else { return false }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    private func applySuccessfulPurchase(of product: Product) {
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
        status: Product.SubscriptionInfo.Status?
    ) {
        entitlementSnapshot = StoreEntitlementSnapshot(
            hasStoreAccess: hasAccess,
            hasLifetimeAccess: hasLifetime,
            subscriptionStatus: status
        )
        AnalyticsTracker.shared.trackAppLaunched(isPro: isPro)
        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime)")
    }

    #if DEBUG
    func setProAccessForTesting(_ enabled: Bool) {
        entitlementSnapshot = StoreEntitlementSnapshot(
            hasStoreAccess: enabled,
            hasLifetimeAccess: false,
            subscriptionStatus: nil
        )
    }

    func setEntitlementSnapshotForTesting(_ snapshot: StoreEntitlementSnapshot) {
        entitlementSnapshot = snapshot
    }
    #endif
}

private extension Product.SubscriptionPeriod {
    var isOneWeek: Bool {
        (unit == .week && value == 1) || (unit == .day && value == 7)
    }
}
