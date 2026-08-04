import AppKit
import HealthTokenCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: HydrationAppModel

    var body: some View {
        Text(statusText)
        Text("今日估算总量：约 \(model.snapshot.todayEstimatedMilliliters) mL")

        Divider()

        Text("每口估算：约 \(model.snapshot.settings.sipEstimate.milliliters) mL")
        Text("提醒间隔：\(reminderMinutes) 分钟")

        if let persistenceError = model.persistenceError {
            Divider()
            Text(persistenceError)
        }

        Divider()

        Button("退出 Health Token") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusText: String {
        switch model.snapshot.status {
        case .accumulating:
            "下一次低干扰提醒正在计时"
        case .dueAmbient:
            "低干扰饮水提醒已显示"
        }
    }

    private var reminderMinutes: Int {
        Int(model.snapshot.settings.reminderInterval / 60)
    }
}
