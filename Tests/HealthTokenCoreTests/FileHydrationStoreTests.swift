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
        settings: HydrationSettings(reminderInterval: 45 * 60, sipEstimate: .large),
        records: [
            DrinkRecord(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                estimatedMilliliters: 35,
                sourceAction: .sipConfirmation
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
