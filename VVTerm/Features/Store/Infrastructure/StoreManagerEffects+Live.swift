import Foundation

extension StoreManagerEffects {
    static func live(engagementTracker: EngagementTracker) -> Self {
        StoreManagerEffects { effect in
            switch effect {
            case .paywallPresented(let source):
                engagementTracker.notePaywallPresented()
                AnalyticsTracker.shared.trackPaywallViewed(source: source.rawValue)
            case .paywallCTATapped(let source, let productID):
                AnalyticsTracker.shared.trackPaywallCTATapped(
                    source: source.rawValue,
                    productId: productID
                )
            case .purchaseStarted(let source, let productID):
                AnalyticsTracker.shared.trackPurchaseStarted(
                    source: source.rawValue,
                    productId: productID
                )
            case .purchaseSucceeded(let source, let productID):
                AnalyticsTracker.shared.trackPurchaseSucceeded(
                    source: source.rawValue,
                    productId: productID
                )
            case .purchaseCancelled(let source, let productID):
                AnalyticsTracker.shared.trackPurchaseCancelled(
                    source: source.rawValue,
                    productId: productID
                )
            case .purchasePending(let source, let productID):
                AnalyticsTracker.shared.trackPurchasePending(
                    source: source.rawValue,
                    productId: productID
                )
            case .purchaseFailed(let source, let productID, let reason):
                AnalyticsTracker.shared.trackPurchaseFailed(
                    source: source.rawValue,
                    productId: productID,
                    reason: reason
                )
            case .entitlementsUpdated(let isPro):
                AnalyticsTracker.shared.trackAppLaunched(isPro: isPro)
            case .reviewRequestedAfterPurchase:
                engagementTracker.requestReviewAfterPurchase()
            }
        }
    }
}
