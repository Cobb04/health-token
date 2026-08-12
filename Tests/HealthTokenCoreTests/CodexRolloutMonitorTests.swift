import Foundation
import Testing
@testable import HealthTokenCore

@Test("startup restores only recent demonstrably unresolved attention")
func startupRestoresOnlyUnresolvedAttention() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-attention.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:20Z","type":"session_meta","payload":{"id":"interactive-root","source":"cli","instructions":"synthetic private prompt","cwd":"/synthetic/private/code"}}
        {"timestamp":"2027-01-15T07:59:30Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"question-call","questions":[{"question":"synthetic private question","options":[{"label":"synthetic private option"}]}]}}
        {"timestamp":"2027-01-15T07:59:31Z","type":"event_msg","payload":{"type":"exec_approval_request","call_id":"permission-call","command":["synthetic private tool arguments"]}}
        {"timestamp":"2027-01-15T07:59:32Z","type":"response_item","payload":{"type":"function_call_output","call_id":"permission-call","output":"synthetic private assistant output","secret":"synthetic secret"}}

        """.utf8
    ).write(to: rolloutURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-1)],
        ofItemAtPath: rolloutURL.path
    )
    let monitor = CodexRolloutMonitor(sessionsURL: directory)

    let events = try monitor.poll(
        observedAt: observedAt
    )

    #expect(events.count == 1)
    #expect(events.first?.kind == .attentionChanged)
    #expect(events.first?.attention == .required)
    #expect(events.first?.sessionID == "interactive-root")
    #expect(events.first?.parentSessionID == nil)
    #expect(events.first?.role == .root)
    let encoded = try JSONEncoder().encode(events)
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    for privateValue in [
        "synthetic private prompt",
        "/synthetic/private/code",
        "synthetic private question",
        "synthetic private option",
        "synthetic private tool arguments",
        "synthetic private assistant output",
        "synthetic secret"
    ] {
        #expect(!encodedText.contains(privateValue))
    }

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"question-call","output":"synthetic private answer"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)
    let resolved = try monitor.poll(
        observedAt: observedAt.addingTimeInterval(1)
    )
    #expect(resolved.count == 1)
    #expect(resolved.first?.kind == .attentionChanged)
    #expect(resolved.first?.attention == AgentAttention.none)
}

@Test("startup never replays historical prompt tool or Subagent work")
func startupNeverReplaysHistoricalAutonomousWork() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-active-child.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:20Z","type":"session_meta","payload":{"id":"child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}
        {"timestamp":"2027-01-15T07:59:21Z","type":"event_msg","payload":{"type":"user_message","message":"synthetic private prompt"}}
        {"timestamp":"2027-01-15T07:59:22Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"synthetic private tool arguments"}}
        {"timestamp":"2027-01-15T07:59:23Z","type":"event_msg","payload":{"type":"agent_message","message":"synthetic private assistant output"}}

        """.utf8
    ).write(to: rolloutURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-1)],
        ofItemAtPath: rolloutURL.path
    )

    #expect(
        try CodexRolloutMonitor(sessionsURL: directory)
            .poll(observedAt: observedAt)
            .isEmpty
    )
}

@Test("steady-state Codex Desktop tool calls emit privacy-safe activity")
func steadyStateDesktopToolCallsEmitActivity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-desktop.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:20Z","type":"session_meta","payload":{"id":"desktop-root","source":"app-server","cwd":"/synthetic/private/code"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live-call","input":"synthetic private command"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
    let event = try #require(events.first)
    let encodedText = try #require(
        String(data: JSONEncoder().encode(event), encoding: .utf8)
    )

    #expect(events.count == 1)
    #expect(event.kind == .toolUsed)
    #expect(event.toolClassification == .ordinary)
    #expect(!encodedText.contains("synthetic private command"))
    #expect(!encodedText.contains("live-call"))
}

@Test("a live Codex task start immediately escalates hydration that is already due")
func liveTaskStartEscalatesDueHydration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-desktop-start.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:20Z","type":"session_meta","payload":{"id":"desktop-root","source":"app-server","cwd":"/synthetic/private/code"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"private-turn","private":"synthetic private prompt"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
    let event = try #require(events.first)
    #expect(events.count == 1)
    #expect(event.kind == .promptSubmitted)
    let encoded = try #require(String(data: JSONEncoder().encode(event), encoding: .utf8))
    #expect(!encoded.contains("private-turn"))
    #expect(!encoded.contains("synthetic private prompt"))

    let settings = HydrationSettings()
    let engine = try HydrationEngine(
        clock: RolloutTestClock(now: observedAt.addingTimeInterval(1)),
        store: InMemoryHydrationStore(
            persistence: HydrationPersistence(
                settings: settings,
                records: [],
                cycle: HydrationCycle(
                    startedAt: observedAt.addingTimeInterval(-settings.reminderInterval),
                    reminderInterval: settings.reminderInterval
                )
            )
        )
    )
    let reminder = try engine.send(.agentEvent(event))

    #expect(reminder.status == .dueStrong)
    #expect(reminder.reminderLevel == .strong)
}

@Test("large Codex Desktop session metadata still anchors live tool activity")
func largeDesktopSessionMetadataAnchorsLiveActivity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-large-desktop.jsonl")
    // Mirrors the 43,672-byte session_meta record emitted by Codex Desktop 0.147.
    let privateMetadata = String(repeating: "x", count: 43_500)
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:20Z","type":"session_meta","payload":{"id":"large-desktop-root","source":"app-server","private":"\(privateMetadata)"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"synthetic private command"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))

    #expect(events.count == 1)
    #expect(events.first?.sessionID == "large-desktop-root")
    #expect(events.first?.kind == .toolUsed)
}

@Test("a newly created large Subagent rollout preserves verified parent identity")
func liveLargeSubagentMetadataPreservesIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    let childID = "019fef56-dcc6-7533-a6c2-2bb4a45081a9"
    let parentID = "019fef56-dcc6-7533-a6c2-2bb4a45081b0"
    let rolloutURL = directory.appendingPathComponent(
        "rollout-2027-01-15T08-00-01-\(childID).jsonl"
    )
    let privateMetadata = String(repeating: "x", count: 44_500)
    try Data(
        """
        {"timestamp":"2027-01-15T08:00:01Z","type":"session_meta","payload":{"id":"\(childID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentID)"}}},"private":"\(privateMetadata)"}}
        {"timestamp":"2027-01-15T08:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live","input":"private"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(2))

    #expect(events.map(\.kind) == [.sessionStarted, .toolUsed])
    #expect(events.allSatisfy { $0.sessionID == childID })
    #expect(events.allSatisfy { $0.role == .subagent })
    #expect(events.allSatisfy { $0.parentSessionID == parentID })
}

@Test("metadata cannot replace the session identity anchored by the rollout filename")
func mismatchedMetadataCannotClaimSubagentIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    let filenameID = "019fef56-dcc6-7533-a6c2-2bb4a45081a9"
    let payloadID = "019fef56-dcc6-7533-a6c2-2bb4a45081aa"
    let rolloutURL = directory.appendingPathComponent(
        "rollout-2027-01-15T08-00-01-\(filenameID).jsonl"
    )
    try Data(
        """
        {"timestamp":"2027-01-15T08:00:01Z","type":"session_meta","payload":{"id":"\(payloadID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}
        {"timestamp":"2027-01-15T08:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live","input":"private"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(2))

    #expect(events.isEmpty)
}

@Test("large session metadata reading stops after the complete first line")
func largeSessionMetadataReadStopsAtFirstLine() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-large-child.jsonl")
    let privateMetadata = String(repeating: "x", count: 18 * 1024)
    let unrelatedRecord = String(repeating: "y", count: 20 * 1024)
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:20Z","type":"session_meta","payload":{"id":"large-child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}},"private":"\(privateMetadata)"}}
        {"timestamp":"2027-01-15T07:59:21Z","type":"event_msg","payload":{"type":"unknown","private":"\(unrelatedRecord)"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)

    #expect(try monitor.poll(observedAt: observedAt).isEmpty)
    #expect(monitor.lastPollMetrics.maximumFileBytesRead < 32 * 1024)
}

@Test("startup rejects stale resolved terminal malformed partial oversized and out-of-order attention")
func startupAttentionEvidenceFailsClosed() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let fixtures: [(String, [String], Int)] = [
        (
            "stale",
            [
                #"{"timestamp":"2027-01-15T07:55:00Z","type":"session_meta","payload":{"id":"stale-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:55:01Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"stale-call","questions":[{"question":"private"}]}}"#
            ],
            64 * 1024
        ),
        (
            "resolved",
            [
                #"{"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"resolved-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:59:01Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"resolved-call","questions":[{"question":"private"}]}}"#,
                #"{"timestamp":"2027-01-15T07:59:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"resolved-call","output":"private"}}"#
            ],
            64 * 1024
        ),
        (
            "terminal",
            [
                #"{"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"terminal-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:59:01Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"terminal-call","questions":[{"question":"private"}]}}"#,
                #"{"timestamp":"2027-01-15T07:59:02Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"private"}}"#
            ],
            64 * 1024
        ),
        (
            "malformed",
            [
                #"{"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"malformed-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:59:01Z","type":"event_msg","payload":{"type":"request_user_input","questions":[{"question":"private"}]}}"#
            ],
            64 * 1024
        ),
        (
            "partial",
            [
                #"{"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"partial-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:59:01Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"partial-call","questions":[{"question":"private"}]}}"#,
                #"{"timestamp":"2027-01-15T07:59:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"partial-call""#
            ],
            64 * 1024
        ),
        (
            "oversized",
            [
                #"{"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"oversized-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:59:01Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"oversized-call","questions":[{"question":""#
                    + String(repeating: "private", count: 100)
                    + #""}]}}"#
            ],
            256
        ),
        (
            "out-of-order",
            [
                #"{"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"unordered-root","source":"cli"}}"#,
                #"{"timestamp":"2027-01-15T07:59:30Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"first-call","questions":[{"question":"private"}]}}"#,
                #"{"timestamp":"2027-01-15T07:59:20Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"second-call","questions":[{"question":"private"}]}}"#
            ],
            64 * 1024
        )
    ]

    for (name, lines, maxRecordBytes) in fixtures {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let rolloutURL = directory.appendingPathComponent("rollout-\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rolloutURL)
        try FileManager.default.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(-1)],
            ofItemAtPath: rolloutURL.path
        )
        let limits = CodexObservationLimits(maxRecordBytes: maxRecordBytes)
        let events = try CodexRolloutMonitor(
            sessionsURL: directory,
            limits: limits
        ).poll(observedAt: observedAt)
        #expect(events.isEmpty, "fixture \(name) must not recover attention")
    }
}

@Test("startup discovery obeys candidate age file count and read budgets")
func startupDiscoveryIsBounded() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<5 {
        let url = directory.appendingPathComponent("rollout-\(index).jsonl")
        let lines = """
        {"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"root-\(index)","source":"cli"}}
        {"timestamp":"2027-01-15T07:59:30Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-\(index)","questions":[{"question":"synthetic private question \(index)"}]}}

        """
        try Data(lines.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(-Double(index + 1))],
            ofItemAtPath: url.path
        )
    }
    let oldURL = directory.appendingPathComponent("rollout-old.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"old-root","source":"cli"}}
        {"timestamp":"2027-01-15T07:59:30Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"old-call"}}

        """.utf8
    ).write(to: oldURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-61)],
        ofItemAtPath: oldURL.path
    )

    let limits = CodexObservationLimits(
        maxCandidateFiles: 2,
        maxScannedEntries: 16,
        maxCandidateAge: 60,
        maxBytesPerFile: 400,
        maxTotalBytesPerPoll: 600,
        maxRecordBytes: 300
    )
    let monitor = CodexRolloutMonitor(sessionsURL: directory, limits: limits)

    let events = try monitor.poll(observedAt: observedAt)
    let metrics = monitor.lastPollMetrics

    #expect(events.count <= 2)
    #expect(events.allSatisfy { $0.kind == .attentionChanged })
    #expect(metrics.scannedEntries <= 16)
    #expect(metrics.candidateFiles == 2)
    #expect(metrics.activeFiles == 2)
    #expect(metrics.filesRead <= 2)
    #expect(metrics.bytesRead <= 600)
    #expect(metrics.maximumFileBytesRead <= 400)
    #expect(metrics.retainedRemainderBytes <= 2 * 300)
    #expect(metrics.pendingAttentionRequests <= 2 * limits.maxPendingAttentionRequests)
}

@Test("stale candidate files are excluded even when their request timestamp is recent")
func staleCandidateFilesAreExcluded() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-stale-file.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"stale-file-root","source":"cli"}}
        {"timestamp":"2027-01-15T07:59:59Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"recent-call"}}

        """.utf8
    ).write(to: rolloutURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(-61)],
        ofItemAtPath: rolloutURL.path
    )
    let monitor = CodexRolloutMonitor(
        sessionsURL: directory,
        limits: CodexObservationLimits(maxCandidateAge: 60)
    )

    #expect(try monitor.poll(observedAt: observedAt).isEmpty)
    #expect(monitor.lastPollMetrics.candidateFiles == 0)
    #expect(monitor.lastPollMetrics.bytesRead == 0)
}

@Test("steady state reads only appends and never reparses unchanged files")
func steadyStateReadsOnlyAppendedBytes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-incremental.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:00Z","type":"session_meta","payload":{"id":"incremental-root","source":"cli"}}

        """.utf8
    ).write(to: rolloutURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt],
        ofItemAtPath: rolloutURL.path
    )
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    #expect(try monitor.poll(observedAt: observedAt.addingTimeInterval(1)).isEmpty)
    #expect(monitor.lastPollMetrics.filesRead == 0)
    #expect(monitor.lastPollMetrics.bytesRead == 0)
    #expect(monitor.lastPollMetrics.recordsParsed == 0)

    let appended = #"{"timestamp":"2027-01-15T08:00:02Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"synthetic private reason"}}"# + "\n"
    try appendData(Data(appended.utf8), to: rolloutURL)
    try FileManager.default.setAttributes(
        [.modificationDate: observedAt.addingTimeInterval(2)],
        ofItemAtPath: rolloutURL.path
    )
    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(2))

    #expect(events.map(\.kind) == [.aborted])
    #expect(monitor.lastPollMetrics.filesRead == 1)
    #expect(monitor.lastPollMetrics.bytesRead == appended.utf8.count)
    #expect(monitor.lastPollMetrics.recordsParsed == 1)

    #expect(try monitor.poll(observedAt: observedAt.addingTimeInterval(3)).isEmpty)
    #expect(monitor.lastPollMetrics.filesRead == 0)
    #expect(monitor.lastPollMetrics.bytesRead == 0)
    #expect(monitor.lastPollMetrics.recordsParsed == 0)
}

@Test("active files aggregate reads and in-memory parser state stay bounded")
func activeFileAndMemoryBudgetsAreBounded() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let limits = CodexObservationLimits(
        maxCandidateFiles: 2,
        maxScannedEntries: 16,
        maxCandidateAge: 60,
        maxBytesPerFile: 160,
        maxTotalBytesPerPoll: 256,
        maxSessionMetadataBytes: 96,
        maxRecordBytes: 96,
        maxPendingAttentionRequests: 2
    )
    let monitor = CodexRolloutMonitor(sessionsURL: directory, limits: limits)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    for index in 0..<3 {
        let url = directory.appendingPathComponent("rollout-live-\(index).jsonl")
        let privatePadding = String(repeating: "p", count: 220)
        try Data(
            """
            {"timestamp":"2027-01-15T08:00:0\(index)Z","type":"session_meta","payload":{"id":"child-\(index)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}},"private":"\(privatePadding)"}}

            """.utf8
        ).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(Double(index + 1))],
            ofItemAtPath: url.path
        )
    }

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(4))
    let metrics = monitor.lastPollMetrics
    #expect(!events.contains { $0.kind == .sessionStarted })
    #expect(metrics.activeFiles == 2)
    #expect(metrics.filesRead <= 2)
    #expect(metrics.bytesRead <= 256)
    #expect(metrics.maximumFileBytesRead <= 160)
    #expect(metrics.retainedRemainderBytes <= 2 * 96)
    #expect(metrics.pendingAttentionRequests <= 2 * 2)
}

@Test("pending attention IDs and partial record memory remain bounded")
func correlationAndRemainderMemoryAreBounded() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let limits = CodexObservationLimits(
        maxBytesPerFile: 4 * 1024,
        maxTotalBytesPerPoll: 4 * 1024,
        maxRecordBytes: 256,
        maxPendingAttentionRequests: 2
    )
    let monitor = CodexRolloutMonitor(sessionsURL: directory, limits: limits)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    let rolloutURL = directory.appendingPathComponent("rollout-memory.jsonl")
    let requests = (0..<5).map { index in
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-\#(index)","questions":[{"question":"private"}]}}"#
    }
    let completePrefix = ([
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"session_meta","payload":{"id":"memory-root","source":"cli"}}"#
    ] + requests).joined(separator: "\n") + "\n"
    let partial = #"{"timestamp":"2027-01-15T08:00:01Z","type":"event_msg","payload":{"type":"unknown","private":"bounded-partial""#
    try Data((completePrefix + partial).utf8).write(to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let required = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
    #expect(required.allSatisfy { $0.attention == .required })
    #expect(monitor.lastPollMetrics.pendingAttentionRequests <= 2)
    #expect(monitor.lastPollMetrics.retainedRemainderBytes == partial.utf8.count)
    #expect(monitor.lastPollMetrics.retainedRemainderBytes <= 256)

    let suffix = #"}}"# + "\n"
    try appendData(Data(suffix.utf8), to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(2), for: rolloutURL)
    #expect(try monitor.poll(observedAt: observedAt.addingTimeInterval(2)).isEmpty)
    #expect(monitor.lastPollMetrics.bytesRead == suffix.utf8.count)
    #expect(monitor.lastPollMetrics.recordsParsed == 1)
    #expect(monitor.lastPollMetrics.retainedRemainderBytes == 0)

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:03Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(3), for: rolloutURL)
    #expect(
        try monitor.poll(observedAt: observedAt.addingTimeInterval(3))
            .map(\.kind) == [.completed]
    )
    #expect(monitor.lastPollMetrics.pendingAttentionRequests == 0)
}

@Test("partial or malformed live batches never start a Subagent")
func ambiguousLiveBatchesCannotStartSubagents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)
    let metadata = #"{"timestamp":"2027-01-15T08:00:01Z","type":"session_meta","payload":{"id":"ambiguous-child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#

    let partialURL = directory.appendingPathComponent("rollout-partial.jsonl")
    try Data((metadata + "\n" + #"{"type":"event_msg","payload":{"type":"unknown""#).utf8)
        .write(to: partialURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: partialURL)

    let malformedURL = directory.appendingPathComponent("rollout-malformed.jsonl")
    try Data(("not-json\n" + metadata + "\n").utf8).write(to: malformedURL)
    try setModificationDate(observedAt.addingTimeInterval(2), for: malformedURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(2))

    #expect(!events.contains { $0.kind == .sessionStarted })
    #expect(monitor.lastPollMetrics.discardedRecords >= 1)
}

@Test("representative synthetic observation stays within the two-second presentation SLA")
func representativeObservationMeetsLatencyBudget() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<8 {
        let url = directory.appendingPathComponent("rollout-load-\(index).jsonl")
        let lines = (0..<120).map { record in
            #"{"timestamp":"2027-01-15T07:59:30Z","type":"event_msg","payload":{"type":"unknown","sequence":"\#(record)","private":""#
                + String(repeating: "x", count: 120)
                + #""}}"#
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: observedAt.addingTimeInterval(-Double(index))],
            ofItemAtPath: url.path
        )
    }
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    let startedAt = ContinuousClock.now

    _ = try monitor.poll(observedAt: observedAt)

    let elapsed = startedAt.duration(to: .now)
    #expect(elapsed < .seconds(1))
    #expect(CodexObservationPolicy.presentationPollInterval == 1)
    #expect(CodexObservationPolicy.presentationPollInterval + 1 <= 2)
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
        {"timestamp":"2027-01-15T08:00:01Z","type":"session_meta","payload":{"id":"child-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}},"instructions":"synthetic private instructions","cwd":"/synthetic/private/path"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

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
    try setModificationDate(observedAt.addingTimeInterval(3), for: rolloutURL)
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
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"session_meta","payload":{"id":"child-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}"#,
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"event_msg","payload":{"type":"task_complete"}}"#
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
    let startupObservedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try setModificationDate(startupObservedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)

    #expect(
        try monitor.poll(
            observedAt: startupObservedAt
        ).isEmpty
    )

    try appendAbort(reason: "live private reason", to: rolloutURL)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_001)
    try setModificationDate(observedAt, for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt)

    #expect(events.count == 1)
    #expect(events[0].kind == .aborted)
    #expect(events[0].sessionID == "synthetic-session")
    #expect(events[0].timestamp == observedAt)
    #expect(events[0].role == .root)

    monitor.reset()
    try appendAbort(reason: "disabled private reason", to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)
    #expect(
        try monitor.poll(observedAt: observedAt.addingTimeInterval(1)).isEmpty
    )

    try appendAbort(reason: "resumed private reason", to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(2), for: rolloutURL)
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
    try setModificationDate(observedAt, for: rolloutURL)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try FileManager.default.removeItem(at: rolloutURL)
    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))

    #expect(events.count == 1)
    #expect(events.first?.kind.rawValue == "sessionRemoved")
    #expect(events.first?.sessionID == "removed-session")
}

@Test("rollout attention resolves only after every matching output arrives")
func rolloutAttentionResolutionIsCorrelated() throws {
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

    let rolloutURL = directory.appendingPathComponent("rollout-attention.jsonl")
    try Data(
        """
        {"type":"session_meta","payload":{"id":"interactive-root","source":"cli"}}
        {"type":"event_msg","payload":{"type":"request_user_input","call_id":"question-call","questions":[{"question":"synthetic private question","options":[{"label":"synthetic private option"}]}]}}
        {"type":"event_msg","payload":{"type":"exec_approval_request","call_id":"permission-call","command":["synthetic-private-command"]}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let required = try monitor.poll(
        observedAt: observedAt.addingTimeInterval(1)
    )
    #expect(required.count == 2)
    #expect(required.allSatisfy { $0.kind == .attentionChanged })
    #expect(required.allSatisfy { $0.attention == .required })

    try appendRolloutLine(
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"other-call","output":"synthetic unrelated private output"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(2), for: rolloutURL)
    #expect(
        try monitor.poll(
            observedAt: observedAt.addingTimeInterval(2)
        ).isEmpty
    )

    try appendRolloutLine(
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"question-call","output":"synthetic private answer"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(3), for: rolloutURL)
    #expect(
        try monitor.poll(
            observedAt: observedAt.addingTimeInterval(3)
        ).isEmpty
    )

    try appendRolloutLine(
        #"{"type":"event_msg","payload":{"type":"exec_command_begin","call_id":"permission-call","command":["synthetic-private-command"]}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(4), for: rolloutURL)
    let resolved = try monitor.poll(
        observedAt: observedAt.addingTimeInterval(4)
    )
    #expect(resolved.count == 1)
    #expect(resolved.first?.kind == .attentionChanged)
    #expect(resolved.first?.attention == AgentAttention.none)
    let encodedText = try #require(
        String(data: JSONEncoder().encode(resolved), encoding: .utf8)
    )
    #expect(!encodedText.contains("synthetic private question"))
    #expect(!encodedText.contains("synthetic private option"))
    #expect(!encodedText.contains("synthetic private answer"))
    #expect(!encodedText.contains("synthetic private command"))
}

@Test("oversized tool output is skipped without erasing neighboring live activity")
func oversizedToolOutputPreservesLiveActivity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-oversized-output.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:59Z","type":"session_meta","payload":{"id":"stable-root","source":"app-server"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(
        sessionsURL: directory,
        limits: CodexObservationLimits(
            maxBytesPerFile: 4 * 1024,
            maxTotalBytesPerPoll: 4 * 1024,
            maxRecordBytes: 256
        )
    )
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    let privateOutput = String(repeating: "private-output", count: 100)
    let batch = [
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"first","input":"private"}}"#,
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"first","output":"\#(privateOutput)"}}"#,
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"function_call","name":"wait","call_id":"second","arguments":"private"}}"#
    ].joined(separator: "\n") + "\n"
    try appendData(Data(batch.utf8), to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))

    #expect(events.map(\.kind) == [.toolUsed, .toolUsed])
    #expect(events.allSatisfy { $0.sessionID == "stable-root" })
    #expect(!events.contains { $0.kind == .sessionRemoved })
    #expect(monitor.lastPollMetrics.discardedRecords == 1)
}

@Test("a multi-chunk oversized record is discarded with bounded memory")
func oversizedRecordIsSkippedAcrossBoundedPolls() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-bounded-output.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:59Z","type":"session_meta","payload":{"id":"bounded-root","source":"app-server"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(
        sessionsURL: directory,
        limits: CodexObservationLimits(
            maxBytesPerFile: 512,
            maxTotalBytesPerPoll: 512,
            maxRecordBytes: 256
        )
    )
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    let oversizedLine = #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"huge","output":""#
        + String(repeating: "x", count: 600)
        + #""}}"#
    let validLine = #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live","input":"private"}}"#
    try appendData(Data((oversizedLine + "\n" + validLine + "\n").utf8), to: rolloutURL)
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    #expect(try monitor.poll(observedAt: observedAt.addingTimeInterval(1)).isEmpty)
    #expect(monitor.lastPollMetrics.bytesRead <= 512)
    #expect(monitor.lastPollMetrics.retainedRemainderBytes <= 256)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(2))
    #expect(events.map(\.kind) == [.toolUsed])
    #expect(events.first?.sessionID == "bounded-root")
    #expect(monitor.lastPollMetrics.retainedRemainderBytes == 0)
}

@Test("a malformed record does not erase a verified session")
func malformedRecordDoesNotEraseSession() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let rolloutURL = directory.appendingPathComponent("rollout-malformed-live.jsonl")
    try Data(
        """
        {"timestamp":"2027-01-15T07:59:59Z","type":"session_meta","payload":{"id":"malformed-root","source":"app-server"}}

        """.utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try appendData(
        Data(("not-json\n" + #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live","input":"private"}}"# + "\n").utf8),
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
    #expect(events.map(\.kind) == [.toolUsed])
    #expect(events.first?.sessionID == "malformed-root")
}

@Test("a valid rollout filename recovers root identity only")
func rootActivityUsesRolloutFilenameIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = "019fef56-dcc6-7533-a6c2-2bb4a45081a9"
    let rolloutURL = directory.appendingPathComponent(
        "rollout-2026-08-11T13-41-15-\(sessionID).jsonl"
    )
    try Data(
        (#"{"timestamp":"2027-01-15T07:59:59Z","type":"event_msg","payload":{"type":"token_count"}}"# + "\n").utf8
    ).write(to: rolloutURL)
    try setModificationDate(observedAt, for: rolloutURL)
    let monitor = CodexRolloutMonitor(sessionsURL: directory)
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live","input":"private"}}"#,
        to: rolloutURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
    #expect(events.map(\.kind) == [.toolUsed])
    #expect(events.first?.sessionID == sessionID)
    #expect(events.first?.role == .root)
}

@Test("a late-discovered old rollout emits only activity after monitor startup")
func lateDiscoveredOldRolloutDoesNotReplayHistory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let targetID = "019fef56-dcc6-7533-a6c2-2bb4a45081a9"
    let targetURL = directory.appendingPathComponent(
        "rollout-2027-01-15T07-00-00-\(targetID).jsonl"
    )
    try Data(
        """
        {"timestamp":"2027-01-15T07:00:00Z","type":"session_meta","payload":{"id":"\(targetID)","source":"app-server"}}
        {"timestamp":"2027-01-15T07:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"historical-one","input":"private"}}
        {"timestamp":"2027-01-15T07:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"historical-two","input":"private"}}

        """.utf8
    ).write(to: targetURL)
    try setModificationDate(observedAt.addingTimeInterval(-30), for: targetURL)
    for index in 0..<2 {
        let decoyURL = directory.appendingPathComponent("rollout-decoy-\(index).jsonl")
        try Data(
            """
            {"timestamp":"2027-01-15T07:59:5\(index)Z","type":"session_meta","payload":{"id":"decoy-\(index)","source":"cli"}}

            """.utf8
        ).write(to: decoyURL)
        try setModificationDate(
            observedAt.addingTimeInterval(Double(index - 2)),
            for: decoyURL
        )
    }
    let monitor = CodexRolloutMonitor(
        sessionsURL: directory,
        limits: CodexObservationLimits(maxCandidateFiles: 2)
    )
    #expect(try monitor.poll(observedAt: observedAt).isEmpty)

    try appendRolloutLine(
        #"{"timestamp":"2027-01-15T08:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"live","input":"private"}}"#,
        to: targetURL
    )
    try setModificationDate(observedAt.addingTimeInterval(1), for: targetURL)

    let events = try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
    let toolEvents = events.filter { $0.kind == .toolUsed }

    #expect(toolEvents.count == 1)
    #expect(toolEvents.first?.sessionID == targetID)
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

private func appendRolloutLine(_ line: String, to url: URL) throws {
    try appendData(Data((line + "\n").utf8), to: url)
}

private func appendData(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: url.path
    )
}

private final class RolloutTestClock: HydrationClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
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
    try setModificationDate(observedAt.addingTimeInterval(1), for: rolloutURL)
    return try monitor.poll(observedAt: observedAt.addingTimeInterval(1))
}
