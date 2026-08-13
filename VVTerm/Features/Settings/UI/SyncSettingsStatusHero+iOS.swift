#if os(iOS)
import SwiftUI

extension SyncSettingsStatusHero {
    var platformBody: some View {
        StatusHeroLayout(
            state: state,
            lastSuccessfulSyncDate: lastSuccessfulSyncDate
        )
    }
}

private struct StatusHeroLayout: View {
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 58.0

    let state: SyncSettingsUserState
    let lastSuccessfulSyncDate: Date?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state.statusHeroSystemImage)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(state.statusHeroTint)
                .accessibilityHidden(true)

            Text(state.title)
                .font(.title2.weight(.semibold))

            SyncSettingsStatusDetail(
                state: state,
                lastSuccessfulSyncDate: lastSuccessfulSyncDate
            )
                .font(.subheadline)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync Status")
        .accessibilityValue(state.title)
        .accessibilityIdentifier("vvterm.settings.sync.statusHero")
    }
}
#endif
