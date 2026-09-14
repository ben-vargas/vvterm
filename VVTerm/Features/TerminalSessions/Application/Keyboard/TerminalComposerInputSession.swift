#if os(iOS)
/// The keyboard coordinator owns focus; UIKit reports actual responder ownership.
@MainActor
protocol TerminalComposerInputSession: AnyObject {
    var isComposerFirstResponder: Bool { get }
    func preventComposerInputAcquisition()
    func setComposerInput(active: Bool, softwareKeyboardHidden: Bool)
}
#endif
