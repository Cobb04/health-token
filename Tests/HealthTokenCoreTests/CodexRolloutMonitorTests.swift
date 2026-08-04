import Foundation
import Testing
@testable import HealthTokenCore

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

private func appendAbort(reason: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    let line = """
    {"type":"event_msg","payload":{"type":"turn_aborted","reason":"\(reason)"}}

    """
    try handle.write(contentsOf: Data(line.utf8))
}
