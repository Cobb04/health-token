import Foundation

public enum HydrationStatus: String, Codable, Equatable, Sendable {
    case accumulating
    case dueAmbient
}

public enum ReminderLevel: String, Codable, Equatable, Sendable {
    case hidden
    case ambient
}

public enum SipEstimate: Int, Codable, CaseIterable, Equatable, Sendable {
    case small = 15
    case regular = 25
    case large = 35

    public var milliliters: Int { rawValue }
}

public struct HydrationSettings: Codable, Equatable, Sendable {
    public var reminderInterval: TimeInterval
    public var sipEstimate: SipEstimate

    public init(
        reminderInterval: TimeInterval = 30 * 60,
        sipEstimate: SipEstimate = .regular
    ) {
        self.reminderInterval = reminderInterval
        self.sipEstimate = sipEstimate
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
}

public struct DrinkRecord: Codable, Equatable, Identifiable, Sendable {
    public enum SourceAction: String, Codable, Equatable, Sendable {
        case sipConfirmation
    }

    public let id: UUID
    public let timestamp: Date
    public let estimatedMilliliters: Int
    public let sourceAction: SourceAction

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
}

public struct HydrationPersistence: Codable, Equatable, Sendable {
    public var settings: HydrationSettings
    public var records: [DrinkRecord]
    public var cycle: HydrationCycle

    public init(
        settings: HydrationSettings,
        records: [DrinkRecord],
        cycle: HydrationCycle
    ) {
        self.settings = settings
        self.records = records
        self.cycle = cycle
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

    public init(
        status: HydrationStatus,
        reminderLevel: ReminderLevel,
        detailsExpanded: Bool,
        settings: HydrationSettings,
        records: [DrinkRecord],
        cycle: HydrationCycle,
        todayEstimatedMilliliters: Int
    ) {
        self.status = status
        self.reminderLevel = reminderLevel
        self.detailsExpanded = detailsExpanded
        self.settings = settings
        self.records = records
        self.cycle = cycle
        self.todayEstimatedMilliliters = todayEstimatedMilliliters
    }
}
