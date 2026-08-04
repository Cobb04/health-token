import Foundation
import HealthTokenCore

@main
enum HealthTokenHook {
    static func main() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let event = AgentEventAdapter.normalizeHook(input, observedAt: Date()) {
            let inbox = CodexEventInbox(
                directoryURL: CodexEventInbox.defaultDirectoryURL()
            )
            try? inbox.enqueue(event)
        }

        FileHandle.standardOutput.write(Data("{}\n".utf8))
    }
}
