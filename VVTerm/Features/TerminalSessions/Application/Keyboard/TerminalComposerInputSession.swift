#if os(iOS)
/// The keyboard coordinator owns focus; UIKit reports actual responder ownership.
@MainActor
protocol TerminalComposerInputSession: AnyObject {
    var allowsComposerFocus: Bool { get }
    var isComposerFirstResponder: Bool { get }
    func insertComposerText(_ text: String)
    func preventComposerInputAcquisition()
    func setComposerInput(active: Bool, softwareKeyboardHidden: Bool)
}
#endif
