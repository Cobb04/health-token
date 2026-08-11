import AppKit
import Foundation

@MainActor
final class TemporalRefreshCoordinator {
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let refresh: () -> Void
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        refresh: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.refresh = refresh
    }

    func start() {
        guard notificationTokens.isEmpty else { return }

        let temporalNames: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification
        ]
        notificationTokens = temporalNames.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
        notificationTokens.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        )
    }

    func stop() {
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
            workspaceNotificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll(keepingCapacity: false)
    }
}
