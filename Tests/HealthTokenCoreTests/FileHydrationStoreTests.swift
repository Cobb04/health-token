import Foundation
import Testing
@testable import HealthTokenCore

@Test("the local store round-trips settings, cycle, and drink records")
func fileStoreRoundTripsHydrationState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("hydration.json")
    let store = FileHydrationStore(fileURL: fileURL)
    let expected = HydrationPersistence(
        settings: HydrationSettings(
            reminderInterval: 45 * 60,
            sipEstimate: .large,
            bottleCapacityMilliliters: 750
        ),
        records: [
            DrinkRecord(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                sipEstimate: .large,
                sourceAction: .sipConfirmation
            ),
            DrinkRecord(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1_800_000_100),
                estimatedMilliliters: 615,
                sourceAction: .bottleReconciliation
            )
        ],
        cycle: HydrationCycle(
            startedAt: Date(timeIntervalSince1970: 1_800_000_100),
            reminderInterval: 45 * 60
        )
    )

    try store.save(expected)

    #expect(try FileHydrationStore(fileURL: fileURL).load() == expected)
}

@Test("invalid persisted settings recover to defaults without losing valid records")
func invalidPersistedSettingsRecover() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("hydration.json")
    let store = FileHydrationStore(fileURL: fileURL)
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let record = DrinkRecord(
        id: UUID(),
        timestamp: startedAt,
        sipEstimate: .regular,
        sourceAction: .sipConfirmation
    )
    try store.save(
        HydrationPersistence(
            settings: HydrationSettings(),
            records: [record],
            cycle: HydrationCycle(startedAt: startedAt, reminderInterval: 30 * 60)
        )
    )

    var json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
            as? [String: Any]
    )
    var settings = try #require(json["settings"] as? [String: Any])
    settings["reminderInterval"] = -60
    settings["sipEstimate"] = 99
    settings["bottleCapacityMilliliters"] = 0
    settings["noAgentFallbackEnabled"] = "invalid"
    json["settings"] = settings
    var cycle = try #require(json["cycle"] as? [String: Any])
    cycle["reminderInterval"] = -60
    json["cycle"] = cycle
    var records = try #require(json["records"] as? [[String: Any]])
    var invalidRecord = try #require(records.first)
    invalidRecord["estimatedMilliliters"] = "invalid"
    records.append(invalidRecord)
    json["records"] = records
    json["isPaused"] = "invalid"
    json["snoozedUntil"] = "invalid"
    try JSONSerialization.data(withJSONObject: json).write(to: fileURL)

    let loaded = try store.load()
    let recovered = try #require(loaded)

    #expect(recovered.settings == HydrationSettings())
    #expect(recovered.settings.bottleCapacityMilliliters == 1_000)
    #expect(recovered.records == [record])
    #expect(recovered.cycle.startedAt == startedAt)
    #expect(recovered.cycle.reminderInterval == HydrationSettings.defaultReminderInterval)
    #expect(!recovered.isPaused)
    #expect(recovered.snoozedUntil == nil)
}
