import SwiftUI

extension WakeOnLANDestination.Mode {
    var displayName: LocalizedStringResource {
        switch self {
        case .automatic:
            return "Automatic"
        case .explicitBroadcast:
            return "Specific broadcast address"
        }
    }
}

struct WakeOnLANFormSection: View {
    @Binding var model: WakeOnLANFormModel

    var body: some View {
        Section {
            Toggle("Enable Wake-on-LAN", isOn: $model.isEnabled)
                .accessibilityIdentifier("vvterm.serverForm.wakeOnLAN.enabled")

            if model.isEnabled {
                TextField(
                    "MAC Address",
                    text: $model.macAddress,
                    prompt: Text("AA:BB:CC:DD:EE:FF")
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                .keyboardType(.asciiCapable)
                #endif
                .accessibilityIdentifier("vvterm.serverForm.wakeOnLAN.macAddress")

                Picker("Broadcast", selection: $model.destinationMode) {
                    ForEach(WakeOnLANDestination.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .accessibilityIdentifier("vvterm.serverForm.wakeOnLAN.destination")

                if model.destinationMode == .explicitBroadcast {
                    TextField(
                        "Broadcast Address",
                        text: $model.broadcastAddress,
                        prompt: Text("192.168.1.255")
                    )
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .accessibilityIdentifier(
                        "vvterm.serverForm.wakeOnLAN.broadcastAddress"
                    )
                }

                TextField("UDP Port", text: $model.port, prompt: Text("9"))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityIdentifier("vvterm.serverForm.wakeOnLAN.port")
            }
        } header: {
            sectionHeader
        } footer: {
            footer
        }
    }

    private var sectionHeader: some View {
        Text("Wake-on-LAN")
            #if os(iOS)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
            #endif
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "Wake-on-LAN works on the same Wi-Fi or Ethernet network. VPN, cellular, and isolated guest networks may block it."
            )

            if model.isEnabled && !model.hasValidMACAddress {
                Text("Enter a 12-digit MAC address.")
                    .foregroundStyle(.red)
            }

            if model.isEnabled && !model.hasValidBroadcastAddress {
                Text("Enter a valid IPv4 broadcast address.")
                    .foregroundStyle(.red)
            }

            if model.isEnabled && !model.hasValidPort {
                Text("Use a UDP port from 1 to 65535.")
                    .foregroundStyle(.red)
            }
        }
    }
}
