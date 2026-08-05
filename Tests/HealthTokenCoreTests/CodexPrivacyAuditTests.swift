import Foundation
import Testing
@testable import HealthTokenCore

@Test("privacy audit keeps private Codex fields out of events diagnostics inbox and hydration persistence")
func codexObservationPrivacyAudit() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inboxURL = directory.appendingPathComponent("inbox", isDirectory: true)
    let hydrationURL = directory.appendingPathComponent("hydration.json")
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let privateValues = [
        "audit-private-prompt",
        "audit-private-source-code",
        "audit-private-tool-arguments",
        "audit-private-assistant-output",
        "audit-private-secret"
    ]
    let payload = Data(
        """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "privacy-audit-root",
          "tool_name": "Bash",
          "prompt": "audit-private-prompt",
          "source_code": "audit-private-source-code",
          "tool_input": {"command": "audit-private-tool-arguments"},
          "tool_response": "audit-private-assistant-output",
          "secret": "audit-private-secret"
        }
        """.utf8
    )
    let event = try #require(
        AgentEventAdapter.normalizeHook(payload, observedAt: observedAt)
    )
    let encodedEvent = try JSONEncoder().encode(event)
    let eventObject = try #require(
        try JSONSerialization.jsonObject(with: encodedEvent) as? [String: Any]
    )
    #expect(
        Set(eventObject.keys) == [
            "kind",
            "sessionID",
            "timestamp",
            "role",
            "attention",
            "toolClassification"
        ]
    )

    let inbox = CodexEventInbox(directoryURL: inboxURL)
    try inbox.enqueue(event)
    let inboxFile = try #require(
        FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil
        ).first
    )
    let inboxData = try Data(contentsOf: inboxFile)

    let monitor = CodexRolloutMonitor(
        sessionsURL: directory.appendingPathComponent("missing-sessions")
    )
    _ = try monitor.poll(observedAt: observedAt)
    let diagnosticFields = Mirror(reflecting: monitor.lastPollMetrics).children
    #expect(diagnosticFields.allSatisfy { $0.value is Int })

    let clock = PrivacyAuditClock(now: observedAt)
    let store = FileHydrationStore(fileURL: hydrationURL)
    let engine = try HydrationEngine(clock: clock, store: store)
    _ = try engine.send(.agentEvent(event))
    _ = try engine.send(.setReminderInterval(45 * 60))
    let hydrationData = try Data(contentsOf: hydrationURL)

    let auditedTexts = try [encodedEvent, inboxData, hydrationData].map {
        try #require(String(data: $0, encoding: .utf8))
    }
    let diagnosticText = String(describing: monitor.lastPollMetrics)
    for privateValue in privateValues {
        #expect(auditedTexts.allSatisfy { !$0.contains(privateValue) })
        #expect(!diagnosticText.contains(privateValue))
    }
}

private final class PrivacyAuditClock: HydrationClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
