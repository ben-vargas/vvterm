//
//  AboutView.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AboutView: View {
    @State private var isShowingOpenSourceLicenses = false

    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    var body: some View {
        VStack(spacing: 0) {
            // App icon and name
            VStack(spacing: 12) {
                appIcon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .cornerRadius(18)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("VVTerm")
                    .font(.system(size: 24, weight: .bold))

                Text(String(format: String(localized: "Version %@ (%@)"), appVersion, buildNumber))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Tagline
            Text("Professional SSH client\nfor macOS & iOS")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

            // Links
            VStack(spacing: 12) {
                LinkButton(
                    title: String(localized: "Visit Website"),
                    icon: "globe",
                    url: "https://vvterm.com"
                )

                LinkButton(
                    title: String(localized: "GitHub"),
                    icon: "chevron.left.forwardslash.chevron.right",
                    url: "https://github.com/vivy-company/vvterm"
                )

                LinkButton(
                    title: String(localized: "Report an Issue"),
                    icon: "exclamationmark.bubble",
                    url: "https://github.com/vivy-company/vvterm/issues"
                )

                LinkButton(
                    title: String(localized: "Privacy Policy"),
                    icon: "hand.raised",
                    url: "https://vvterm.com/privacy"
                )

                LinkButton(
                    title: String(localized: "Terms of Use (EULA)"),
                    icon: "doc.text",
                    url: "https://vvterm.com/terms"
                )

                Button {
                    isShowingOpenSourceLicenses = true
                } label: {
                    AboutButtonLabel(
                        title: String(localized: "Open Source & Licenses"),
                        icon: "doc.text.magnifyingglass",
                        trailingIcon: "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vvterm.about.openSourceLicenses")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            Divider()
                .padding(.horizontal, 32)

            // Copyright
        Text(String(format: String(localized: "© %lld Vivy Technologies Co., Limited"), Int64(Calendar.current.component(.year, from: Date()))))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 16)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $isShowingOpenSourceLicenses) {
            OpenSourceLicensesView()
        }
    }

    private var appIcon: Image {
        #if os(macOS)
        if let nsImage = NSImage(named: "AppIcon") {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "terminal")
        #else
        if let uiImage = UIImage(named: "AppIcon") {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "terminal")
        #endif
    }
}

private struct LinkButton: View {
    let title: String
    let icon: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            AboutButtonLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
    }
}

private struct AboutButtonLabel: View {
    let title: String
    let icon: String
    var trailingIcon = "arrow.up.right"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Image(systemName: trailingIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 8))
    }
}

#Preview {
    AboutView()
}
