#if os(iOS)
import UIKit

// UIKit marks these protocol properties optional, so they cannot be assigned
// through UITextInputTraits. Both terminal inputs implement this required subset.
@MainActor
protocol TerminalKeyboardConfigurableInput: AnyObject {
    var autocorrectionType: UITextAutocorrectionType { get set }
    var autocapitalizationType: UITextAutocapitalizationType { get set }
    var spellCheckingType: UITextSpellCheckingType { get set }
    var smartQuotesType: UITextSmartQuotesType { get set }
    var smartDashesType: UITextSmartDashesType { get set }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get set }
    @available(iOS 17.0, *)
    var inlinePredictionType: UITextInlinePredictionType { get set }
}

extension UITextView: TerminalKeyboardConfigurableInput {}
extension TerminalIMEProxyTextView: TerminalKeyboardConfigurableInput {}

extension TerminalKeyboardConfigurableInput where Self: UIView {
    func applyKeyboardOptions(_ options: TerminalKeyboardOptions) {
        let correction: UITextAutocorrectionType = options.contains(.autocorrection) ? .default : .no
        let capitalization: UITextAutocapitalizationType = options.contains(.capitalization) ? .sentences : .none
        let spelling: UITextSpellCheckingType = options.contains(.spellChecking) ? .default : .no
        let quotes: UITextSmartQuotesType = options.contains(.smartPunctuation) ? .default : .no
        let dashes: UITextSmartDashesType = options.contains(.smartPunctuation) ? .default : .no
        let spacing: UITextSmartInsertDeleteType = options.contains(.smartSpacing) ? .default : .no
        var changed = autocorrectionType != correction || autocapitalizationType != capitalization
            || spellCheckingType != spelling || smartQuotesType != quotes
            || smartDashesType != dashes || smartInsertDeleteType != spacing
        if #available(iOS 17.0, *) {
            let predictions: UITextInlinePredictionType = options.contains(.inlinePrediction) ? .default : .no
            changed = changed || inlinePredictionType != predictions
            if inlinePredictionType != predictions { inlinePredictionType = predictions }
        }
        guard changed else { return }
        autocorrectionType = correction
        autocapitalizationType = capitalization
        spellCheckingType = spelling
        smartQuotesType = quotes
        smartDashesType = dashes
        smartInsertDeleteType = spacing
        if isFirstResponder, window?.isKeyWindow == true,
           window?.windowScene?.activationState == .foregroundActive { reloadInputViews() }
    }
}
#endif
