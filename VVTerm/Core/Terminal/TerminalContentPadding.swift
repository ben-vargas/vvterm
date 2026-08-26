nonisolated struct TerminalContentPadding: Equatable, Sendable {
    static let defaultValue = TerminalContentPadding(
        horizontal: TerminalDefaults.defaultContentPadding,
        vertical: TerminalDefaults.defaultContentPadding
    )

    let horizontal: Int
    let vertical: Int

    init(horizontal: Double, vertical: Double) {
        self.horizontal = Int(TerminalDefaults.clampedContentPadding(horizontal))
        self.vertical = Int(TerminalDefaults.clampedContentPadding(vertical))
    }
}
