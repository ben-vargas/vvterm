import Foundation

@MainActor
protocol ServerManagerPreferences: AnyObject {
    var hasResolvedInitialWorkspace: Bool { get set }
    var hasSeenWelcome: Bool { get }
    var freePlanGeneration: FreePlanGeneration? { get set }
}
