import SwiftUI

struct WelcomeFeature: Identifiable {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let color: Color

    var id: String { icon + String(describing: title) }
}

enum WelcomeFeatureCatalog {
    static let features: [WelcomeFeature] = [
        WelcomeFeature(
            icon: "terminal.fill",
            title: "SSH Terminal",
            description: "Connect to servers with GPU-accelerated terminal emulation.",
            color: .blue
        ),
        WelcomeFeature(
            icon: "folder.fill",
            title: "SFTP Files",
            description: "Browse folders, preview files, and move things around on your server.",
            color: .indigo
        ),
        WelcomeFeature(
            icon: "chart.xyaxis.line",
            title: "Server Stats",
            description: "Keep an eye on CPU, memory, disk, and network activity at a glance.",
            color: .mint
        ),
        WelcomeFeature(
            icon: "icloud.fill",
            title: "iCloud Sync",
            description: "Servers and credentials sync across all your devices.",
            color: .cyan
        ),
        WelcomeFeature(
            icon: "clock.arrow.circlepath",
            title: "Session Persistence",
            description: "Keep sessions alive with tmux, even after disconnects.",
            color: .teal
        ),
        WelcomeFeature(
            icon: "key.fill",
            title: "Secure Storage",
            description: "Passwords and SSH keys protected by Keychain.",
            color: .green
        ),
        WelcomeFeature(
            icon: "waveform",
            title: "Voice Commands",
            description: "Speak commands with on-device speech recognition.",
            color: .orange
        )
    ]
}
