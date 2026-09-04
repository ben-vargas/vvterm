import Foundation

/// Runs Ghostty's synchronous external-output boundary on a dedicated worker.
/// Each transport awaits one completed write, which keeps output ordered and bounded.
/// The lock protects write acceptance and the active write count. The serial queue
/// is the only executor of native output processing. This manual contract is
/// required because the C surface handle cannot express Swift sendability.
nonisolated final class GhosttyTerminalOutputRuntime: @unchecked Sendable {
    private let outputQueue = DispatchQueue(
        label: "app.vivy.VVTerm.ghostty-terminal-output",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var surface: Ghostty.Surface?
    private var activeWriteCount = 0

    init(surface: Ghostty.Surface) {
        self.surface = surface
    }

    func write(_ data: Data) async -> Bool {
        guard !data.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            lock.lock()
            guard let surface else {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            guard activeWriteCount < Int.max else {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            activeWriteCount += 1
            outputQueue.async {
                let processed = surface.processTerminalOutput(data)
                self.lock.withLock {
                    self.activeWriteCount -= 1
                }
                continuation.resume(returning: processed)
            }
            lock.unlock()
        }
    }

    @MainActor
    func close() {
        lock.lock()
        guard let surface else {
            lock.unlock()
            return
        }
        self.surface = nil
        let canFreeNow = activeWriteCount == 0
        if canFreeNow {
            lock.unlock()
            surface.free()
            return
        }
        outputQueue.async {
            DispatchQueue.main.async {
                surface.free()
            }
        }
        lock.unlock()
    }
}
