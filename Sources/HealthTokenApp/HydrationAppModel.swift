import AppKit
import Foundation
import HealthTokenCore

@MainActor
final class HydrationAppModel: ObservableObject {
    @Published private(set) var snapshot: HydrationSnapshot
    @Published private(set) var persistenceError: String?

    private let engine: HydrationEngine

    init() {
        let clock = SystemHydrationClock()
        let fileURL = Self.applicationSupportURL

        do {
            engine = try HydrationEngine(
                clock: clock,
                store: FileHydrationStore(fileURL: fileURL)
            )
            snapshot = engine.snapshot
        } catch {
            let fallbackStore = InMemoryHydrationStore()
            engine = try! HydrationEngine(clock: clock, store: fallbackStore)
            snapshot = engine.snapshot
            persistenceError = "本地记录暂时无法读取；本次运行不会写入磁盘。"
        }
    }

    func refresh() {
        send(.timeAdvanced)
    }

    func openReminder() {
        send(.openReminder)
    }

    func closeReminder() {
        send(.closeReminder)
    }

    func confirmSip() {
        send(.confirmSip)
    }

    private func send(_ action: HydrationEngine.Action) {
        do {
            snapshot = try engine.send(action)
            persistenceError = nil
        } catch {
            persistenceError = "无法保存本地记录，请稍后重试。"
        }
    }

    private static var applicationSupportURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return baseURL
            .appendingPathComponent("HealthToken", isDirectory: true)
            .appendingPathComponent("hydration.json")
    }
}
