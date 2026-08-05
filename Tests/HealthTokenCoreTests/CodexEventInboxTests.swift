import Foundation
import Testing
@testable import HealthTokenCore

@Test("the event inbox persists only normalized events and drains them once")
func eventInboxDrainsNormalizedEventsOnce() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = CodexEventInbox(directoryURL: directory)
    let event = AgentEvent(
        kind: .planUpdated,
        sessionID: "synthetic-session",
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        role: .root,
        attention: .none,
        toolClassification: .plan
    )

    try inbox.enqueue(event)

    let storedURLs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(storedURLs.count == 1)
    let storedText = try String(contentsOf: storedURLs[0], encoding: .utf8)
    #expect(storedText.contains("synthetic-session"))
    #expect(!storedText.contains("prompt"))
    #expect(!storedText.contains("arguments"))
    #expect(!storedText.contains("output"))

    #expect(try inbox.drain() == [event])
    #expect(try inbox.drain().isEmpty)
}

@Test("malformed inbox files fail quietly and are not replayed")
func malformedInboxEventsFailClosed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data("private malformed payload".utf8).write(
        to: directory.appendingPathComponent("malformed.json")
    )
    let inbox = CodexEventInbox(directoryURL: directory)

    #expect(try inbox.drain().isEmpty)
    #expect(try inbox.drain().isEmpty)
}

@Test("the event inbox drains events in timestamp order")
func eventInboxPreservesLifecycleOrder() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let earlier = AgentEvent(
        kind: .attentionChanged,
        sessionID: "synthetic-session",
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        role: .root,
        attention: .required,
        toolClassification: .userInput
    )
    let later = AgentEvent(
        kind: .completed,
        sessionID: "synthetic-session",
        timestamp: Date(timeIntervalSince1970: 1_800_000_001),
        role: .root,
        attention: .none
    )
    let encoder = JSONEncoder()
    try encoder.encode(later).write(
        to: directory.appendingPathComponent("a-later.json")
    )
    try encoder.encode(earlier).write(
        to: directory.appendingPathComponent("z-earlier.json")
    )

    #expect(try CodexEventInbox(directoryURL: directory).drain() == [earlier, later])
}

@Test("permission and question payloads never enter the persistent inbox")
func attentionPayloadsAreNotPersisted() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = CodexEventInbox(directoryURL: directory)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let privateValues = [
        "synthetic-secret-command",
        "synthetic-private-question",
        "synthetic-private-option",
        "synthetic-private-description"
    ]
    let payloads = [
        Data(
            #"{"hook_event_name":"PermissionRequest","session_id":"permission-root","tool_name":"Bash","tool_input":{"command":"synthetic-secret-command"}}"#.utf8
        ),
        Data(
            #"{"hook_event_name":"PreToolUse","session_id":"question-root","tool_name":"request_user_input","tool_input":{"questions":[{"question":"synthetic-private-question","options":[{"label":"synthetic-private-option","description":"synthetic-private-description"}]}]}}"#.utf8
        )
    ]

    for payload in payloads {
        let event = try #require(
            AgentEventAdapter.normalizeHook(payload, observedAt: observedAt)
        )
        try inbox.enqueue(event)
    }

    let storedURLs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(storedURLs.count == 2)
    for storedURL in storedURLs {
        let storedText = try String(contentsOf: storedURL, encoding: .utf8)
        for privateValue in privateValues {
            #expect(!storedText.contains(privateValue))
        }
    }

    let events = try inbox.drain()
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.kind == .attentionChanged })
    #expect(events.allSatisfy { $0.attention == .required })
}
