import Foundation

extension ProPlanKind {
    var title: String {
        switch self {
        case .monthly:
            return String(localized: "Monthly")
        case .yearly:
            return String(localized: "Yearly")
        case .lifetime:
            return String(localized: "Lifetime")
        }
    }

    var detail: String {
        switch self {
        case .monthly:
            return String(localized: "Flexible access to every Pro feature.")
        case .yearly:
            return String(localized: "Best value for ongoing terminal work.")
        case .lifetime:
            return String(localized: "Pay once and keep Pro access forever.")
        }
    }

    var badge: String? {
        self == .yearly ? String(localized: "Best value") : nil
    }
}

struct ProPlanPresentation {
    let plan: ProPlanKind
    let displayPrice: String
    let introductoryOfferState: ProPlanIntroductoryOfferState
    private let bundle: Bundle

    init(
        plan: ProPlanKind,
        displayPrice: String,
        introductoryOfferState: ProPlanIntroductoryOfferState = .unavailable,
        bundle: Bundle = .main
    ) {
        self.plan = plan
        self.displayPrice = displayPrice
        self.introductoryOfferState = plan == .lifetime ? .unavailable : introductoryOfferState
        self.bundle = bundle
    }

    var priceLine: String {
        if let offer {
            switch offer.paymentMode {
            case .freeTrial:
                return LocalizedFormat.string("Free trial: %@", duration(offer.totalPeriodValue, unit: offer.periodUnit), bundle: bundle)
            case .payUpFront:
                return LocalizedFormat.string("%@ total", offer.displayPrice, bundle: bundle)
            case .payAsYouGo:
                return LocalizedFormat.string("%@ / %@", offer.displayPrice, duration(offer.periodValue, unit: offer.periodUnit), bundle: bundle)
            }
        }
        switch plan {
        case .monthly:
            return LocalizedFormat.string("%@ per month", displayPrice, bundle: bundle)
        case .yearly:
            return LocalizedFormat.string("%@ per year", displayPrice, bundle: bundle)
        case .lifetime:
            return LocalizedFormat.string("%@ one time", displayPrice, bundle: bundle)
        }
    }

    var detail: String {
        guard let offer else { return plan.detail }
        if offer.paymentMode == .freeTrial {
            return LocalizedFormat.string(
                plan == .monthly ? "Then %@ per month." : "Then %@ per year.",
                displayPrice, bundle: bundle
            )
        }
        // A label keeps duration units independent of grammatical case in each language.
        return LocalizedFormat.string(
            plan == .monthly
                ? "Offer duration: %@. Then %@ per month."
                : "Offer duration: %@. Then %@ per year.",
            duration(offer.totalPeriodValue, unit: offer.periodUnit), displayPrice, bundle: bundle
        )
    }

    var purchaseButtonTitle: String {
        if plan == .lifetime {
            return LocalizedFormat.string("Buy %@", displayPrice, bundle: bundle)
        }
        if offer?.paymentMode == .freeTrial {
            return LocalizedFormat.string("Start Free Trial", bundle: bundle)
        }
        return LocalizedFormat.string("Subscribe for %@", offer?.displayPrice ?? displayPrice, bundle: bundle)
    }

    var renewalDisclosure: String {
        if plan == .lifetime {
            return LocalizedFormat.string("One-time purchase. No subscription renewal.", bundle: bundle)
        }
        if offer != nil {
            return LocalizedFormat.string("%@. %@ Auto-renews until canceled.", priceLine, detail, bundle: bundle)
        }
        return LocalizedFormat.string("Auto-renews until canceled.", bundle: bundle)
    }

    var planAccessibilityLabel: String {
        [plan.title, priceLine, detail].joined(separator: ". ")
    }

    var purchaseButtonAccessibilityLabel: String {
        offer != nil
            ? [purchaseButtonTitle, renewalDisclosure].joined(separator: ". ")
            : purchaseButtonTitle
    }

    private var offer: StoreIntroductoryOffer? {
        guard case .eligible(let offer) = introductoryOfferState else { return nil }
        return offer
    }

    private func duration(_ value: Int, unit: StoreIntroductoryOffer.PeriodUnit) -> String {
        let key: String
        switch unit {
        case .day: key = "%lld days"
        case .week: key = "%lld weeks"
        case .month: key = "%lld months"
        case .year: key = "%lld years"
        }
        return LocalizedFormat.string(key, Int64(value), bundle: bundle)
    }
}
