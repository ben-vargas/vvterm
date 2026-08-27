import Testing
@testable import VVTerm

struct WakeOnLANFormModelTests {
    @Test
    func disabledFormNeedsNoStoredConfiguration() {
        var model = WakeOnLANFormModel()
        model.macAddress = "invalid"
        model.port = "0"

        #expect(model.isValid)
        #expect(model.persistedConfiguration == nil)
    }

    @Test
    func enabledFormRequiresMACDestinationAndPort() {
        var model = WakeOnLANFormModel()
        model.isEnabled = true

        #expect(!model.isValid)
        #expect(!model.hasValidMACAddress)

        model.macAddress = "AA:BB:CC:DD:EE:FF"
        model.port = "65536"
        #expect(!model.hasValidPort)

        model.port = "9"
        model.destinationMode = .explicitBroadcast
        #expect(!model.hasValidBroadcastAddress)

        model.broadcastAddress = "192.168.50.255"
        #expect(model.isValid)
    }

    @Test
    func persistedConfigurationRestoresCanonicalFormValues() throws {
        let configuration = try WakeOnLANConfiguration(
            macAddress: WakeOnLANMACAddress("aa-bb-cc-dd-ee-ff"),
            destination: .explicitBroadcast(
                WakeOnLANIPv4Address("192.168.50.255")
            ),
            port: 7
        )

        let model = WakeOnLANFormModel(configuration: configuration)

        #expect(model.isEnabled)
        #expect(model.macAddress == "AA:BB:CC:DD:EE:FF")
        #expect(model.destinationMode == .explicitBroadcast)
        #expect(model.broadcastAddress == "192.168.50.255")
        #expect(model.port == "7")
        #expect(model.persistedConfiguration == configuration)
    }
}
