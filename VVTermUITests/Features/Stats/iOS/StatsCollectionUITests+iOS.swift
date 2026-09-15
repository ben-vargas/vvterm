#if os(iOS)
import XCTest

final class StatsCollectionUITests: XCTestCase {
    @MainActor
    func testStatsKeepPollingAfterTerminalAndFilesSwitches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-stats-collection",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO"
        ]
        app.launch()
        defer { app.terminate() }

        let tabs = app.segmentedControls["vvterm.stats.collection.tabs"]
        if !tabs.waitForExistence(timeout: 5), app.state == .runningForeground {
            // ActivityKit can launch the installed app before XCUITest supplies
            // the test arguments. Match the other production UI test launches.
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 8))
        let state = app.staticTexts["vvterm.stats.collection.state"]

        for previousTab in ["Terminal", "Files", "Terminal"] {
            tabs.buttons[previousTab].tap()
            tabs.buttons["Stats"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["vvterm.stats.card.cpu"].waitForExistence(timeout: 5))

            // Wait for more than the initial sample. A disappearing old Stats
            // view can pause the collector after the new view starts it.
            for _ in 0..<2 {
                let previousSample = try sample(in: state)
                let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    guard let value = state.value as? String,
                          value.contains("polling=true"),
                          let sample = self.sampleValue(value) else { return false }
                    return sample > previousSample
                }, object: nil)
                XCTAssertEqual(
                    XCTWaiter.wait(for: [advances], timeout: 5), .completed,
                    "Stats stopped after \(previousTab): \(state.value ?? "nil")"
                )
            }
        }

        tabs.buttons["Files"].tap()
        XCTAssertTrue((state.value as? String)?.contains("polling=false") == true)
    }

    @MainActor
    private func sample(in state: XCUIElement) throws -> Double {
        let value = state.value as? String
        return try XCTUnwrap(value.flatMap(sampleValue), "Missing sample in \(value ?? "nil")")
    }

    private func sampleValue(_ value: String) -> Double? {
        value.components(separatedBy: "sample=").last.flatMap(Double.init)
    }
}
#endif
