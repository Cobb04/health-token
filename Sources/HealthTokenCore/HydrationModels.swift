import Foundation

public enum HydrationStatus: String, Codable, Equatable, Sendable {
    case accumulating
    case dueAmbient
    case dueStrong
    case snoozed
    case paused

    public var isHydrationDue: Bool {
        self == .dueAmbient || self == .dueStrong || self == .snoozed
    }
}

public enum ReminderLevel: String, Codable, Equatable, Sendable {
    case hidden
    case ambient
    case strong
    case confirmation
}

public enum SipEstimate: Int, Codable, CaseIterable, Equatable, Sendable {
    case small = 15
    case regular = 25
    case large = 35

    public var milliliters: Int { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try? container.decode(Int.self)
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .regular
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct HydrationSettings: Codable, Equatable, Sendable {
    public static let defaultReminderInterval: TimeInterval = 30 * 60
    public static let defaultBottleCapacityMilliliters = 1_000
    public static let reminderIntervalOptions: [TimeInterval] = [
        15 * 60,
        30 * 60,
        45 * 60,
        60 * 60
    ]
    public static let bottleCapacityOptions = [500, 750, 1_000, 1_500, 2_000]

    public var reminderInterval: TimeInterval
    public var sipEstimate: SipEstimate
    public var bottleCapacityMilliliters: Int
    public var noAgentFallbackEnabled: Bool

    public init(
        reminderInterval: TimeInterval = Self.defaultReminderInterval,
        sipEstimate: SipEstimate = .regular,
        bottleCapacityMilliliters: Int = Self.defaultBottleCapacityMilliliters,
        noAgentFallbackEnabled: Bool = true
    ) {
        self.reminderInterval = Self.normalizedReminderInterval(reminderInterval)
        self.sipEstimate = sipEstimate
        self.bottleCapacityMilliliters = Self.normalizedBottleCapacity(
            bottleCapacityMilliliters
        )
        self.noAgentFallbackEnabled = noAgentFallbackEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case reminderInterval
        case sipEstimate
        case bottleCapacityMilliliters
        case noAgentFallbackEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedInterval = try? container.decode(
            TimeInterval.self,
            forKey: .reminderInterval
        )
        reminderInterval = Self.normalizedReminderInterval(
            savedInterval ?? Self.defaultReminderInterval
        )
        sipEstimate = (try? container.decode(SipEstimate.self, forKey: .sipEstimate))
            ?? .regular
        bottleCapacityMilliliters = Self.normalizedBottleCapacity(
            (try? container.decode(Int.self, forKey: .bottleCapacityMilliliters))
                ?? Self.defaultBottleCapacityMilliliters
        )
        noAgentFallbackEnabled = (try? container.decode(
            Bool.self,
            forKey: .noAgentFallbackEnabled
        )) ?? true
    }

    public static func normalizedReminderInterval(_ interval: TimeInterval) -> TimeInterval {
        interval.isFinite && interval > 0 ? interval : defaultReminderInterval
    }

    public static func normalizedBottleCapacity(_ milliliters: Int) -> Int {
        (100...5_000).contains(milliliters)
            ? milliliters
            : defaultBottleCapacityMilliliters
    }
}

public struct HydrationCycle: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let reminderInterval: TimeInterval

    public init(startedAt: Date, reminderInterval: TimeInterval) {
        self.startedAt = startedAt
        self.reminderInterval = reminderInterval
    }

    public func status(at date: Date) -> HydrationStatus {
        date.timeIntervalSince(startedAt) >= reminderInterval
            ? .dueAmbient
            : .accumulating
    }

    public func remainingTime(at date: Date) -> TimeInterval {
        max(0, reminderInterval - date.timeIntervalSince(startedAt))
    }
}

public struct DrinkRecord: Codable, Equatable, Identifiable, Sendable {
    public enum SourceAction: String, Codable, Equatable, Sendable {
        case sipConfirmation
        case proactiveSip
        case bottleReconciliation
    }

    public let id: UUID
    public let timestamp: Date
    public let estimatedMilliliters: Int
    public let sourceAction: SourceAction

    public var sipEstimate: SipEstimate? {
        SipEstimate(rawValue: estimatedMilliliters)
    }

    public init(
        id: UUID,
        timestamp: Date,
        sipEstimate: SipEstimate,
        sourceAction: SourceAction
    ) {
        self.id = id
        self.timestamp = timestamp
        estimatedMilliliters = sipEstimate.milliliters
        self.sourceAction = sourceAction
    }

    public init(
        id: UUID,
        timestamp: Date,
        estimatedMilliliters: Int,
        sourceAction: SourceAction
    ) {
        self.id = id
        self.timestamp = timestamp
        self.estimatedMilliliters = estimatedMilliliters
        self.sourceAction = sourceAction
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case estimatedMilliliters
        case sourceAction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let milliliters = try container.decode(Int.self, forKey: .estimatedMilliliters)
        sourceAction = try container.decode(SourceAction.self, forKey: .sourceAction)
        let validAmount: Bool
        switch sourceAction {
        case .sipConfirmation, .proactiveSip:
            validAmount = SipEstimate(rawValue: milliliters) != nil
        case .bottleReconciliation:
            validAmount = milliliters > 0
        }
        guard validAmount else {
            throw DecodingError.dataCorruptedError(
                forKey: .estimatedMilliliters,
                in: container,
                debugDescription: "Drink record amount is invalid for its source action."
            )
        }
        estimatedMilliliters = milliliters
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(estimatedMilliliters, forKey: .estimatedMilliliters)
        try container.encode(sourceAction, forKey: .sourceAction)
    }
}

public struct HydrationPersistence: Codable, Equatable, Sendable {
    public var settings: HydrationSettings
    public var records: [DrinkRecord]
    public var cycle: HydrationCycle
    public var isPaused: Bool
    public var snoozedUntil: Date?

    public init(
        settings: HydrationSettings,
        records: [DrinkRecord],
        cycle: HydrationCycle,
        isPaused: Bool = false,
        snoozedUntil: Date? = nil
    ) {
        self.settings = settings
        self.records = records
        self.cycle = cycle
        self.isPaused = isPaused
        self.snoozedUntil = snoozedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case settings
        case records
        case cycle
        case isPaused
        case snoozedUntil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decode(HydrationSettings.self, forKey: .settings)
        let savedRecords = (try? container.decode(
            [RecoverableValue<DrinkRecord>].self,
            forKey: .records
        )) ?? []
        records = savedRecords.compactMap(\.value)
        let savedCycle = try container.decode(HydrationCycle.self, forKey: .cycle)
        cycle = HydrationCycle(
            startedAt: savedCycle.startedAt,
            reminderInterval: settings.reminderInterval
        )
        isPaused = (try? container.decode(Bool.self, forKey: .isPaused)) ?? false
        snoozedUntil = try? container.decode(Date.self, forKey: .snoozedUntil)
    }
}

public struct HydrationSnapshot: Equatable, Sendable {
    public let status: HydrationStatus
    public let reminderLevel: ReminderLevel
    public let detailsExpanded: Bool
    public let settings: HydrationSettings
    public let records: [DrinkRecord]
    public let cycle: HydrationCycle
    public let todayEstimatedMilliliters: Int
    public let remainingTimeUntilReminder: TimeInterval
    public let snoozedUntil: Date?
    public let undoableDrinkRecord: DrinkRecord?

    public init(
        status: HydrationStatus,
        reminderLevel: ReminderLevel,
        detailsExpanded: Bool,
        settings: HydrationSettings,
        records: [DrinkRecord],
        cycle: HydrationCycle,
        todayEstimatedMilliliters: Int,
        remainingTimeUntilReminder: TimeInterval,
        snoozedUntil: Date?,
        undoableDrinkRecord: DrinkRecord?
    ) {
        self.status = status
        self.reminderLevel = reminderLevel
        self.detailsExpanded = detailsExpanded
        self.settings = settings
        self.records = records
        self.cycle = cycle
        self.todayEstimatedMilliliters = todayEstimatedMilliliters
        self.remainingTimeUntilReminder = remainingTimeUntilReminder
        self.snoozedUntil = snoozedUntil
        self.undoableDrinkRecord = undoableDrinkRecord
    }
}

private struct RecoverableValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
