import Foundation

extension GhosttyTerminalView: EternalTerminalOutputSink {
    func receiveEternalTerminalOutput(_ data: Data) {
        feedData(data)
    }
}
