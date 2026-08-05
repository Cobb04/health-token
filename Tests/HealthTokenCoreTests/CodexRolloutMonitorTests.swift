import Foundation
import Testing
@testable import HealthTokenCore

@Test("startup restores only a recent active verified Subagent")
func startupRestoresOnlyActiveVerifiedSubagent() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    let activeURL = directory.appendingPathComponent("rollout-active.jsonl")
    try Data(
        #"{"type":"session_meta","payload":{"id":"active-child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"active-parent"}}}}}"#.utf8
    ).write(to: activeURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-1)],
        ofItemAtPath: activeURL.path
    )

    let events = try CodexRolloutMonitor(sessionsURL: directory).poll(
        observedAt: observedAt
    )

    #expect(events.count == 1)
    #expect(events.first?.kind == .sessionStarted)
    #expect(events.first?.sessionID == "active-child")
    #expect(events.first?.parentSessionID == "active-parent")
    #expect(events.first?.role == .subagent)
}

@Test("startup does not replay completed or stale Subagent sessions")
func startupDoesNotReplayInactiveSubagents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let metadata = #"{"type":"session_meta","payload":{"id":"child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#

    let completedURL = directory.appendingPathComponent("rollout-completed.jsonl")
    try Data(
        (metadata + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n").utf8
    ).write(to: completedURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-1)],
        ofItemAtPath: completedURL.path
    )

    let staleURL = directory.appendingPathComponent("rollout-stale.jsonl")
    try Data(metadata.replacingOccurrences(of: "\"child\"", with: "\"stale-child\"").utf8)
        .write(to: staleURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-5 * 60)],
        ofItemAtPath: staleURL.path
    )

    #expect(
        try CodexRolloutMonitor(sessionsURL: directory)
            .poll(observedAt: observedAt)
            .isEmpty
    )
}

@Test("explicit thread-spawn metadata starts a verified Subagent session")
func explicitThreadSpawnStartsSubagentSession() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    let rolloutURL = directory.appendingPathComponent("rollout-subagent.jsonl")
    try Data(
        """
        {"type":"session_meta","payload":{"id":"child-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}},"instructions":"synthetic private instructions","cwd":"/synthetic/private/path"}}

        """.utf8
    ).write(to: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))

    #expect(events.count == 1)
    #expect(events.first?.kind == .sessionStarted)
    #expect(events.first?.sessionID == "child-session")
    #expect(events.first?.parentSessionID == "parent-session")
    #expect(events.first?.role == .subagent)
    let encoded = try JSONEncoder().encode(events[0])
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    let encodedObject = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(
        Set(encodedObject.keys) == [
            "kind",
            "sessionID",
            "parentSessionID",
            "timestamp",
            "role",
            "attention"
        ]
    )
    #expect(!encodedText.contains("synthetic private instructions"))
    #expect(!encodedText.contains("/synthetic/private/path"))

    #expect(
        try monitor.poll(
            observedAt: observedAt.addingTimeInterval(2)
        ).isEmpty
    )
    try appendAbort(reason: "synthetic private reason", to: rolloutURL)
    let aborts = try monitor.poll(
        observedAt: observedAt.addingTimeInterval(3)
    )
    #expect(aborts.count == 1)
    #expect(aborts.first?.kind == .aborted)
    #expect(aborts.first?.sessionID == "child-session")
    #expect(aborts.first?.parentSessionID == "parent-session")
    #expect(aborts.first?.role == .subagent)
}

@Test("same-poll Subagent completion remains ordered after session start")
func samePollSubagentCompletionPreservesLifecycleOrder() throws {
    let events = try pollNewRollout(lines: [
        #"{"type":"session_meta","payload":{"id":"child-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}"#,
        #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    ])

    #expect(events.map(\.kind) == [.sessionStarted, .completed])
    #expect(events.map(\.sessionID) == ["child-session", "child-session"])
}

@Test("rollout metadata fails closed unless thread-spawn identity is complete")
func rolloutMetadataFailsClosed() throws {
    let root = try pollNewRollout(lines: [
        #"{"type":"session_meta","payload":{"id":"root-session","source":"cli","nickname":"worker","cwd":"/synthetic/private/path"}}"#,
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    ])
    #expect(root.count == 1)
    #expect(root.first?.kind == .aborted)
    #expect(root.first?.sessionID == "root-session")
    #expect(root.first?.role == .root)
    #expect(root.first?.parentSessionID == nil)

    let unknown = try pollNewRollout(lines: [
        #"{"type":"session_meta","payload":{"id":"unknown-session","source":{"subagent":{"nickname":"worker","timing":"busy","process_count":4,"activity_volume":999}},"cwd":"/synthetic/private/path"}}"#,
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    ])
    #expect(unknown.count == 1)
    #expect(unknown.first?.role == .root)
    #expect(unknown.first?.parentSessionID == nil)

    let incomplete = try pollNewRollout(lines: [
        #"{"type":"session_meta","payload":{"id":"incomplete-session","source":{"subagent":{"thread_spawn":{}}}}}"#,
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    ])
    #expect(incomplete.count == 1)
    #expect(incomplete.first?.role == .root)

    let malformed = try pollNewRollout(lines: [
        #"{"type":"session_meta","payload":{"id":42,"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#,
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    ])
    #expect(malformed.isEmpty)

    let whitespaceParent = try pollNewRollout(lines: [
        #"{"type":"session_meta","payload":{"id":"whitespace-parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"   "}}}}}"#,
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    ])
    #expect(whitespaceParent.count == 1)
    #expect(whitespaceParent.first?.role == .root)
    #expect(whitespaceParent.first?.parentSessionID == nil)

    let oversizedMetadata =
        #"{"type":"session_meta","payload":{"id":"oversized-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}},"arbitrary":""#
        + String(repeating: "x", count: 512)
        + #""}}"#
    let oversized = try pollNewRollout(
        lines: [
            oversizedMetadata,
            #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
        ],
        maxBytesPerFile: 128
    )
    #expect(oversized.isEmpty)
}

@Test("rollout fallback tails live aborts without replaying history")
func rolloutFallbackObservesOnlyLiveAborts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let dayDirectory = directory.appendingPathComponent("2027/01/15")
    try FileManager.default.createDirectory(
        at: dayDirectory,
        withIntermediateDirectories: true
    )
    let rolloutURL = dayDirectory.appendingPathComponent(
        "rollout-2027-01-15T08-00-00-synthetic.jsonl"
    )
    let initialLines = """
    {"type":"session_meta","payload":{"id":"synthetic-session","source":"cli"}}
    {"type":"event_msg","payload":{"type":"turn_aborted","reason":"historical private reason"}}

    """
    try Data(initialLines.utf8).write(to: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)

    #expect(
        try monitor.poll(
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ).isEmpty
    )

    try appendAbort(reason: "live private reason", to: rolloutURL)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_001)

    let events = try monitor.poll(observedAt: observedAt)

    #expect(events.count == 1)
    #expect(events[0].kind == .aborted)
    #expect(events[0].sessionID == "synthetic-session")
    #expect(events[0].timestamp == observedAt)
    #expect(events[0].role == .root)

    monitor.reset()
    try appendAbort(reason: "disabled private reason", to: rolloutURL)
    #expect(
        try monitor.poll(observedAt: observedAt.addingTimeInterval(1)).isEmpty
    )

    try appendAbort(reason: "resumed private reason", to: rolloutURL)
    #expect(
        try monitor.poll(observedAt: observedAt.addingTimeInterval(2)).count == 1
    )
}

@Test("rollout removal emits a session-removed lifecycle event")
func rolloutRemovalEmitsSessionRemoved() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let rolloutURL = directory.appendingPathComponent("rollout-synthetic.jsonl")
    try Data(
        """
        {"type":"session_meta","payload":{"id":"removed-session","source":"cli"}}

        """.utf8
    ).write(to: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try FileManager.default.removeItem(at: rolloutURL)
    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))

    #expect(events.count == 1)
    #expect(events.first?.kind.rawValue == "sessionRemoved")
    #expect(events.first?.sessionID == "removed-session")
}

private func appendAbort(reason: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    let line = """
    {"type":"event_msg","payload":{"type":"turn_aborted","reason":"\(reason)"}}

    """
    try handle.write(contentsOf: Data(line.utf8))
}

private func pollNewRollout(
    lines: [String],
    maxBytesPerFile: Int = 64 * 1024
) throws -> [AgentEvent] {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let monitor = CodexRolloutMonitor(
        sessionsURL: directory,
        maxBytesPerFile: maxBytesPerFile
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)
    let rolloutURL = directory.appendingPathComponent("rollout-fixture.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rolloutURL)
    return try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
}
