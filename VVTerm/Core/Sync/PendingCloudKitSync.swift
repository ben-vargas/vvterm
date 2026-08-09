import CloudKit
import Foundation

enum PendingCloudKitMutationPayload: Codable, Equatable {
    case serverUpsert(Server)
    case serverDelete(Server)
    case workspaceUpsert(Workspace)
    case workspaceDelete(Workspace)
    case terminalThemeUpsert(TerminalTheme)
    case terminalThemePreferenceUpsert(TerminalThemePreference)
    case terminalAccessoryProfileUpsert(TerminalAccessoryProfile)
    case statsPreferencesUpsert(StatsPreferences)

    private enum Kind: String, Codable {
        case serverUpsert
        case serverDelete
        case workspaceUpsert
        case workspaceDelete
        case terminalThemeUpsert
        case terminalThemePreferenceUpsert
        case terminalAccessoryProfileUpsert
        case statsPreferencesUpsert
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .serverUpsert:
            self = .serverUpsert(try container.decode(Server.self, forKey: .payload))
        case .serverDelete:
            self = .serverDelete(try container.decode(Server.self, forKey: .payload))
        case .workspaceUpsert:
            self = .workspaceUpsert(try container.decode(Workspace.self, forKey: .payload))
        case .workspaceDelete:
            self = .workspaceDelete(try container.decode(Workspace.self, forKey: .payload))
        case .terminalThemeUpsert:
            self = .terminalThemeUpsert(try container.decode(TerminalTheme.self, forKey: .payload))
        case .terminalThemePreferenceUpsert:
            self = .terminalThemePreferenceUpsert(
                try container.decode(TerminalThemePreference.self, forKey: .payload)
            )
        case .terminalAccessoryProfileUpsert:
            self = .terminalAccessoryProfileUpsert(
                try container.decode(TerminalAccessoryProfile.self, forKey: .payload)
            )
        case .statsPreferencesUpsert:
            self = .statsPreferencesUpsert(
                try container.decode(StatsPreferences.self, forKey: .payload)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .serverUpsert(let server):
            try container.encode(Kind.serverUpsert, forKey: .kind)
            try container.encode(server, forKey: .payload)
        case .serverDelete(let server):
            try container.encode(Kind.serverDelete, forKey: .kind)
            try container.encode(server, forKey: .payload)
        case .workspaceUpsert(let workspace):
            try container.encode(Kind.workspaceUpsert, forKey: .kind)
            try container.encode(workspace, forKey: .payload)
        case .workspaceDelete(let workspace):
            try container.encode(Kind.workspaceDelete, forKey: .kind)
            try container.encode(workspace, forKey: .payload)
        case .terminalThemeUpsert(let theme):
            try container.encode(Kind.terminalThemeUpsert, forKey: .kind)
            try container.encode(theme, forKey: .payload)
        case .terminalThemePreferenceUpsert(let preference):
            try container.encode(Kind.terminalThemePreferenceUpsert, forKey: .kind)
            try container.encode(preference, forKey: .payload)
        case .terminalAccessoryProfileUpsert(let profile):
            try container.encode(Kind.terminalAccessoryProfileUpsert, forKey: .kind)
            try container.encode(profile, forKey: .payload)
        case .statsPreferencesUpsert(let preferences):
            try container.encode(Kind.statsPreferencesUpsert, forKey: .kind)
            try container.encode(preferences, forKey: .payload)
        }
    }

    var entityKey: String {
        switch self {
        case .serverUpsert(let server), .serverDelete(let server):
            return server.id.uuidString
        case .workspaceUpsert(let workspace), .workspaceDelete(let workspace):
            return workspace.id.uuidString
        case .terminalThemeUpsert(let theme):
            return theme.id.uuidString
        case .terminalThemePreferenceUpsert:
            return TerminalThemePreference.recordName
        case .terminalAccessoryProfileUpsert:
            return TerminalAccessoryProfile.recordName
        case .statsPreferencesUpsert:
            return StatsPreferences.recordName
        }
    }

    var coalescingKey: String {
        switch self {
        case .serverUpsert, .serverDelete:
            return "server:\(entityKey)"
        case .workspaceUpsert, .workspaceDelete:
            return "workspace:\(entityKey)"
        case .terminalThemeUpsert:
            return "terminalTheme:\(entityKey)"
        case .terminalThemePreferenceUpsert:
            return "terminalThemePreference:\(entityKey)"
        case .terminalAccessoryProfileUpsert:
            return "terminalAccessoryProfile:\(entityKey)"
        case .statsPreferencesUpsert:
            return "statsPreferences:\(entityKey)"
        }
    }

    var drainPriority: Int {
        switch self {
        case .workspaceUpsert: return 0
        case .serverUpsert: return 1
        case .terminalThemeUpsert: return 2
        case .terminalThemePreferenceUpsert: return 3
        case .terminalAccessoryProfileUpsert: return 4
        case .statsPreferencesUpsert: return 5
        case .serverDelete: return 6
        case .workspaceDelete: return 7
        }
    }

    var isDelete: Bool {
        switch self {
        case .serverDelete, .workspaceDelete:
            return true
        default:
            return false
        }
    }

    var isServerOrWorkspace: Bool {
        switch self {
        case .serverUpsert, .serverDelete, .workspaceUpsert, .workspaceDelete:
            return true
        default:
            return false
        }
    }

    var description: String {
        let operation: String
        switch self {
        case .serverUpsert: operation = "server upsert"
        case .serverDelete: operation = "server delete"
        case .workspaceUpsert: operation = "workspace upsert"
        case .workspaceDelete: operation = "workspace delete"
        case .terminalThemeUpsert: operation = "terminal theme upsert"
        case .terminalThemePreferenceUpsert: operation = "terminal theme preference upsert"
        case .terminalAccessoryProfileUpsert: operation = "terminal accessory profile upsert"
        case .statsPreferencesUpsert: operation = "stats preferences upsert"
        }
        return "\(operation) \(entityKey)"
    }
}

struct PendingCloudKitMutation: Codable, Equatable, Identifiable {
    static let maximumRetryCount = 64

    let id: UUID
    let payload: PendingCloudKitMutationPayload
    let createdAt: Date
    private(set) var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var lastErrorDescription: String?

    private static let baseRetryDelay: TimeInterval = 30
    private static let maximumRetryDelay: TimeInterval = 3_600
    private static let maximumRetryExponent = 7

    private enum CodingKeys: String, CodingKey {
        case id
        case payload
        case createdAt
        case retryCount
        case nextRetryAt
        case lastErrorCode
        case lastErrorDescription
    }

    init(
        id: UUID = UUID(),
        payload: PendingCloudKitMutationPayload,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastErrorCode: String? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = Self.boundedRetryCount(retryCount)
        self.nextRetryAt = nextRetryAt
        self.lastErrorCode = lastErrorCode
        self.lastErrorDescription = lastErrorDescription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        payload = try container.decode(PendingCloudKitMutationPayload.self, forKey: .payload)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        retryCount = Self.boundedRetryCount(try container.decode(Int.self, forKey: .retryCount))
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorDescription = try container.decodeIfPresent(String.self, forKey: .lastErrorDescription)
    }

    static func serverUpsert(_ server: Server) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .serverUpsert(server))
    }

    static func serverDelete(_ server: Server) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .serverDelete(server))
    }

    static func workspaceUpsert(_ workspace: Workspace) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .workspaceUpsert(workspace))
    }

    static func workspaceDelete(_ workspace: Workspace) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .workspaceDelete(workspace))
    }

    static func terminalThemeUpsert(_ theme: TerminalTheme) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .terminalThemeUpsert(theme))
    }

    static func terminalThemePreferenceUpsert(_ preference: TerminalThemePreference) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .terminalThemePreferenceUpsert(preference))
    }

    static func terminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .terminalAccessoryProfileUpsert(profile))
    }

    static func statsPreferencesUpsert(_ preferences: StatsPreferences) -> PendingCloudKitMutation {
        PendingCloudKitMutation(payload: .statsPreferencesUpsert(preferences))
    }

    var entityKey: String { payload.entityKey }
    var drainPriority: Int { payload.drainPriority }
    var entityDescription: String { payload.description }

    static func drainsBefore(_ lhs: PendingCloudKitMutation, _ rhs: PendingCloudKitMutation) -> Bool {
        if lhs.drainPriority != rhs.drainPriority {
            return lhs.drainPriority < rhs.drainPriority
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    func canAttempt(at date: Date) -> Bool {
        guard let nextRetryAt else { return true }
        return nextRetryAt <= date
    }

    func withFailure(error: Error, at date: Date = Date()) -> PendingCloudKitMutation {
        var copy = self
        copy.retryCount = Self.boundedRetryCount(copy.retryCount)
        if copy.retryCount < Self.maximumRetryCount {
            copy.retryCount += 1
        }
        copy.lastErrorDescription = error.localizedDescription
        copy.lastErrorCode = Self.errorCodeString(for: error)

        let exponent = min(max(copy.retryCount - 1, 0), Self.maximumRetryExponent)
        let delay = min(
            Self.baseRetryDelay * pow(2, Double(exponent)),
            Self.maximumRetryDelay
        )
        copy.nextRetryAt = date.addingTimeInterval(delay)
        return copy
    }

    static func errorCodeString(for error: Error) -> String? {
        if let ckError = error as? CKError {
            return String(describing: ckError.code)
        }
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func boundedRetryCount(_ retryCount: Int) -> Int {
        min(max(retryCount, 0), maximumRetryCount)
    }
}

enum PendingCloudKitMutationQuarantineReason: String, Codable, Equatable, Error {
    case unreadableLegacyRecord
    case missingOrConflictingPayload
    case mismatchedEntityKey
    case unsupportedOperation
}

struct PendingCloudKitMutationQuarantine: Codable, Equatable, Identifiable {
    let id: UUID
    let legacyMutationID: UUID?
    let reason: PendingCloudKitMutationQuarantineReason
    let encodedLegacyRecord: Data
    let quarantinedAt: Date
}

final class PendingCloudKitSyncQueue {
    private static let quarantineStorageKeySuffix = ".quarantine.v1"

    private let storageKey: String
    private let quarantineStorageKey: String
    private let defaults: UserDefaults
    private var items: [PendingCloudKitMutation]
    private var quarantinedItems: [PendingCloudKitMutationQuarantine]

    init(
        storageKey: String = CloudKitSyncConstants.pendingCloudKitSyncQueueStorageKey,
        defaults: UserDefaults = .standard
    ) {
        self.storageKey = storageKey
        self.quarantineStorageKey = storageKey + Self.quarantineStorageKeySuffix
        self.defaults = defaults
        self.items = []
        self.quarantinedItems = []
        loadQuarantine()
        load()
    }

    func snapshot() -> [PendingCloudKitMutation] {
        items
    }

    func quarantineSnapshot() -> [PendingCloudKitMutationQuarantine] {
        quarantinedItems
    }

    func enqueue(_ mutation: PendingCloudKitMutation) {
        try? enqueueAtomically([mutation])
    }

    func enqueueAtomically(_ mutations: [PendingCloudKitMutation]) throws {
        var updatedItems = items
        for mutation in mutations {
            updatedItems.removeAll {
                $0.payload.coalescingKey == mutation.payload.coalescingKey
            }
            updatedItems.append(mutation)
        }

        let data = try JSONEncoder().encode(updatedItems)
        defaults.set(data, forKey: storageKey)
        guard defaults.data(forKey: storageKey) == data else {
            throw PendingCloudKitSyncQueueError.persistenceFailed
        }
        items = updatedItems
    }

    func remove(_ mutationID: UUID) {
        items.removeAll { $0.id == mutationID }
        persist()
    }

    func removeAll() {
        items.removeAll()
        persist()
    }

    func removeAll(where shouldRemove: (PendingCloudKitMutation) -> Bool) {
        items.removeAll(where: shouldRemove)
        persist()
    }

    func canAttempt(_ mutation: PendingCloudKitMutation, at date: Date) -> Bool {
        mutation.canAttempt(at: date)
    }

    func recordFailure(for mutation: PendingCloudKitMutation, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == mutation.id }) else {
            return
        }

        items[index] = items[index].withFailure(error: error)
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            return
        }

        if let decoded = try? JSONDecoder().decode([PendingCloudKitMutation].self, from: data) {
            items = decoded
            return
        }

        migrateLegacyQueue(from: data)
    }

    private func migrateLegacyQueue(from data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let records = object as? [Any] else {
            quarantine(data, legacyMutationID: nil, reason: .unreadableLegacyRecord)
            persistQuarantine()
            persist()
            return
        }

        var migratedItems: [PendingCloudKitMutation] = []
        for record in records {
            guard let recordData = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.fragmentsAllowed]
            ) else {
                quarantine(Data(), legacyMutationID: nil, reason: .unreadableLegacyRecord)
                continue
            }

            guard let legacyMutation = try? JSONDecoder().decode(
                LegacyPendingCloudKitMutation.self,
                from: recordData
            ) else {
                quarantine(recordData, legacyMutationID: nil, reason: .unreadableLegacyRecord)
                continue
            }

            switch legacyMutation.migrated() {
            case .success(let mutation):
                migratedItems.removeAll {
                    $0.payload.coalescingKey == mutation.payload.coalescingKey
                }
                migratedItems.append(mutation)
            case .failure(let reason):
                quarantine(recordData, legacyMutationID: legacyMutation.id, reason: reason)
            }
        }

        items = migratedItems
        persistQuarantine()
        persist()
    }

    private func quarantine(
        _ data: Data,
        legacyMutationID: UUID?,
        reason: PendingCloudKitMutationQuarantineReason
    ) {
        guard !quarantinedItems.contains(where: {
            $0.legacyMutationID == legacyMutationID &&
            $0.reason == reason &&
            $0.encodedLegacyRecord == data
        }) else {
            return
        }

        quarantinedItems.append(
            PendingCloudKitMutationQuarantine(
                id: UUID(),
                legacyMutationID: legacyMutationID,
                reason: reason,
                encodedLegacyRecord: data,
                quarantinedAt: Date()
            )
        )
    }

    private func loadQuarantine() {
        guard let data = defaults.data(forKey: quarantineStorageKey),
              let decoded = try? JSONDecoder().decode(
                [PendingCloudKitMutationQuarantine].self,
                from: data
              ) else {
            return
        }
        quarantinedItems = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private func persistQuarantine() {
        guard let data = try? JSONEncoder().encode(quarantinedItems) else {
            return
        }
        defaults.set(data, forKey: quarantineStorageKey)
    }
}

enum PendingCloudKitSyncQueueError: LocalizedError {
    case persistenceFailed

    var errorDescription: String? {
        "The pending CloudKit mutation queue could not be saved."
    }
}

private enum LegacyPendingCloudKitEntity: String, Decodable {
    case server
    case workspace
    case terminalTheme
    case terminalThemePreference
    case terminalAccessoryProfile
    case statsPreferences
}

private enum LegacyPendingCloudKitOperation: String, Decodable {
    case upsert
    case delete
}

private struct LegacyPendingCloudKitMutation: Decodable {
    let id: UUID
    let entity: LegacyPendingCloudKitEntity
    let operation: LegacyPendingCloudKitOperation
    let entityKey: String
    let server: Server?
    let workspace: Workspace?
    let terminalTheme: TerminalTheme?
    let terminalThemePreference: TerminalThemePreference?
    let terminalAccessoryProfile: TerminalAccessoryProfile?
    let statsPreferences: StatsPreferences?
    let createdAt: Date
    let retryCount: Int
    let nextRetryAt: Date?
    let lastErrorCode: String?
    let lastErrorDescription: String?

    func migrated() -> Result<PendingCloudKitMutation, PendingCloudKitMutationQuarantineReason> {
        let payload: PendingCloudKitMutationPayload
        switch (entity, operation) {
        case (.server, .upsert):
            guard let server else { return .failure(.missingOrConflictingPayload) }
            payload = .serverUpsert(server)
        case (.server, .delete):
            guard let server else { return .failure(.missingOrConflictingPayload) }
            payload = .serverDelete(server)
        case (.workspace, .upsert):
            guard let workspace else { return .failure(.missingOrConflictingPayload) }
            payload = .workspaceUpsert(workspace)
        case (.workspace, .delete):
            guard let workspace else { return .failure(.missingOrConflictingPayload) }
            payload = .workspaceDelete(workspace)
        case (.terminalTheme, .upsert), (.terminalTheme, .delete):
            guard let terminalTheme else { return .failure(.missingOrConflictingPayload) }
            // Legacy theme deletes used the same CloudKit save path as tombstone upserts.
            payload = .terminalThemeUpsert(terminalTheme)
        case (.terminalThemePreference, .upsert):
            guard let terminalThemePreference else {
                return .failure(.missingOrConflictingPayload)
            }
            payload = .terminalThemePreferenceUpsert(terminalThemePreference)
        case (.terminalAccessoryProfile, .upsert):
            guard let terminalAccessoryProfile else {
                return .failure(.missingOrConflictingPayload)
            }
            payload = .terminalAccessoryProfileUpsert(terminalAccessoryProfile)
        case (.statsPreferences, .upsert):
            guard let statsPreferences else {
                return .failure(.missingOrConflictingPayload)
            }
            payload = .statsPreferencesUpsert(statsPreferences)
        case (.terminalThemePreference, .delete),
             (.terminalAccessoryProfile, .delete),
             (.statsPreferences, .delete):
            return .failure(.unsupportedOperation)
        }

        guard payloadCount == 1 else {
            return .failure(.missingOrConflictingPayload)
        }

        guard entityKey == payload.entityKey else {
            return .failure(.mismatchedEntityKey)
        }

        return .success(
            PendingCloudKitMutation(
                id: id,
                payload: payload,
                createdAt: createdAt,
                retryCount: retryCount,
                nextRetryAt: nextRetryAt,
                lastErrorCode: lastErrorCode,
                lastErrorDescription: lastErrorDescription
            )
        )
    }

    private var payloadCount: Int {
        [
            server != nil,
            workspace != nil,
            terminalTheme != nil,
            terminalThemePreference != nil,
            terminalAccessoryProfile != nil,
            statsPreferences != nil
        ].reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}
