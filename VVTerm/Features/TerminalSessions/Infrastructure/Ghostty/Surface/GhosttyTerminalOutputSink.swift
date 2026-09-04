import Foundation

extension GhosttyTerminalView: TerminalOutputSink {
    func configureTerminalOutputRuntime() {
        guard useCustomIO, let surface else { return }
        terminalOutputRuntime = GhosttyTerminalOutputRuntime(surface: surface)
    }

    func releaseTerminalSurface() {
        let outputRuntime = terminalOutputRuntime
        terminalOutputRuntime = nil
        let currentSurface = surface
        surface = nil

        if let outputRuntime {
            outputRuntime.close()
        } else {
            currentSurface?.free()
        }
    }
}
