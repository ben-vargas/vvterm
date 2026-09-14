import Foundation

/// StoreKit offer terms. Counts remain in calendar units; months are not fixed days.
nonisolated struct StoreIntroductoryOffer: Equatable, Sendable {
    enum PaymentMode: Equatable, Sendable {
        case freeTrial
        case payUpFront
        case payAsYouGo
    }

    enum PeriodUnit: Equatable, Sendable {
        case day
        case week
        case month
        case year
    }

    let paymentMode: PaymentMode
    let displayPrice: String
    let periodUnit: PeriodUnit
    let periodValue: Int
    let periodCount: Int

    init?(
        paymentMode: PaymentMode,
        displayPrice: String,
        periodUnit: PeriodUnit,
        periodValue: Int,
        periodCount: Int
    ) {
        guard periodValue > 0, periodCount > 0,
              !periodValue.multipliedReportingOverflow(by: periodCount).overflow,
              paymentMode == .payAsYouGo || periodCount == 1 else { return nil }
        self.paymentMode = paymentMode
        self.displayPrice = displayPrice
        self.periodUnit = periodUnit
        self.periodValue = periodValue
        self.periodCount = periodCount
    }

    var totalPeriodValue: Int { periodValue * periodCount }
}

nonisolated enum ProPlanIntroductoryOfferState: Equatable, Sendable {
    case unavailable
    case ineligible
    case eligible(StoreIntroductoryOffer)
}
