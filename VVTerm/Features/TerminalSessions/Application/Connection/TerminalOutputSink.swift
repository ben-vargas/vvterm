import Foundation

@MainActor
protocol TerminalOutputSink: AnyObject {
    @discardableResult
    func receiveTerminalOutput(_ data: Data) async -> Bool
}
