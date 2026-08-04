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
