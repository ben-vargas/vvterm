import Foundation

nonisolated enum FreeTierLimitPresentation {
    static func serverCountDescription(_ limit: Int) -> String {
        if limit == 1 {
            return String(localized: "1 server")
        }
        return LocalizedFormat.string("%lld servers", Int64(limit))
    }
}
