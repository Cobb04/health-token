import Foundation
import Testing
@testable import HealthTokenCore

@Test("session-start hooks normalize to the small AgentEvent contract")
func sessionStartHookNormalizes() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = try #require(
        """
        {
          "hook_event_name": "SessionStart",
          "session_id": "synthetic-root",
          "timestamp": "1999-01-01T00:00:00Z",
          "source": "startup",
          "cwd": "/synthetic/project",
          "model": "synthetic-model",
          "transcript_path": "/private/synthetic-rollout.jsonl"
        }
        """.data(using: .utf8)
    )

    let event = try #require(
        AgentEventAdapter.normalizeHook(payload, observedAt: observedAt)
    )

    #expect(event.kind == .sessionStarted)
    #expect(event.sessionID == "synthetic-root")
    #expect(event.timestamp == observedAt)
    #expect(event.role == .root)
    #expect(event.attention == .none)
    #expect(event.toolClassification == nil)
}

@Test("prompt, plan, tool, and completion hooks normalize")
func lifecycleHooksNormalize() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let fixtures: [(String, AgentEvent.Kind, AgentToolClassification?)] = [
        (
            #"{"hook_event_name":"UserPromptSubmit","session_id":"root","prompt":"private prompt"}"#,
            .promptSubmitted,
            nil
        ),
        (
            #"{"hook_event_name":"UserPromptSubmit","session_id":"root","permission_mode":"plan","prompt":"private plan prompt"}"#,
            .promptSubmitted,
            .plan
        ),
        (
            #"{"hook_event_name":"PostToolUse","session_id":"root","tool_name":"update_plan","tool_input":{"plan":["private step"]}}"#,
            .planUpdated,
            .plan
        ),
        (
            #"{"hook_event_name":"PostToolUse","session_id":"root","tool_name":"Bash","tool_input":{"command":"private source"},"tool_response":"private output"}"#,
            .toolUsed,
            .ordinary
        ),
        (
            #"{"hook_event_name":"Stop","session_id":"root","last_assistant_message":"private output"}"#,
            .completed,
            nil
        )
    ]

    for (fixture, expectedKind, expectedTool) in fixtures {
        let data = try #require(fixture.data(using: .utf8))
        let event = try #require(
            AgentEventAdapter.normalizeHook(data, observedAt: observedAt)
        )

        #expect(event.kind == expectedKind)
        #expect(event.sessionID == "root")
        #expect(event.timestamp == observedAt)
        #expect(event.role == .root)
        #expect(event.attention == .none)
        #expect(event.toolClassification == expectedTool)
    }
}

@Test("permission and user-input hooks report attention without answering")
func attentionHooksNormalizeReadOnly() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let fixtures: [(String, AgentEvent.Kind, AgentAttention)] = [
        (
            #"{"hook_event_name":"PermissionRequest","session_id":"root","tool_name":"Bash","tool_input":{"command":"private command"}}"#,
            .attentionChanged,
            .required
        ),
        (
            #"{"hook_event_name":"PreToolUse","session_id":"root","tool_name":"request_user_input","tool_input":{"questions":["private question"]}}"#,
            .attentionChanged,
            .required
        ),
        (
            #"{"hook_event_name":"PostToolUse","session_id":"root","tool_name":"request_user_input","tool_response":{"answers":["private answer"]}}"#,
            .toolUsed,
            .none
        )
    ]

    for (fixture, expectedKind, expectedAttention) in fixtures {
        let data = try #require(fixture.data(using: .utf8))
        let event = try #require(
            AgentEventAdapter.normalizeHook(data, observedAt: observedAt)
        )

        #expect(event.kind == expectedKind)
        #expect(event.attention == expectedAttention)
        #expect(event.toolClassification == .userInput)
    }
}

@Test("subagent hooks use explicit subagent identity and role")
func subagentHooksNormalize() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let startData = try #require(
        #"{"hook_event_name":"SubagentStart","session_id":"root","agent_id":"synthetic-subagent","agent_type":"worker"}"#.data(using: .utf8)
    )
    let stopData = try #require(
        #"{"hook_event_name":"SubagentStop","session_id":"root","agent_id":"synthetic-subagent","last_assistant_message":"private output"}"#.data(using: .utf8)
    )

    let started = try #require(
        AgentEventAdapter.normalizeHook(startData, observedAt: observedAt)
    )
    let stopped = try #require(
        AgentEventAdapter.normalizeHook(stopData, observedAt: observedAt)
    )

    #expect(started.kind == .sessionStarted)
    #expect(stopped.kind == .completed)
    #expect(started.sessionID == "synthetic-subagent")
    #expect(stopped.sessionID == "synthetic-subagent")
    #expect(started.parentSessionID == "root")
    #expect(stopped.parentSessionID == "root")
    #expect(started.role == .subagent)
    #expect(stopped.role == .subagent)
}

@Test("normalization fails closed and excludes arbitrary upstream payloads")
func normalizationEnforcesPrivacyBoundary() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let privateValues = [
        "synthetic private prompt",
        "synthetic private source",
        "synthetic private arguments",
        "synthetic private assistant output",
        "synthetic arbitrary payload"
    ]
    let payload = try #require(
        """
        {
          "hook_event_name": "PostToolUse",
          "session_id": "root",
          "tool_name": "Bash",
          "prompt": "synthetic private prompt",
          "source_code": "synthetic private source",
          "tool_input": {"command": "synthetic private arguments"},
          "tool_response": "synthetic private assistant output",
          "unknown": "synthetic arbitrary payload"
        }
        """.data(using: .utf8)
    )
    let event = try #require(
        AgentEventAdapter.normalizeHook(payload, observedAt: observedAt)
    )
    let encoded = try JSONEncoder().encode(event)
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    let encodedObject = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    #expect(
        Set(encodedObject.keys) == [
            "kind",
            "sessionID",
            "timestamp",
            "role",
            "attention",
            "toolClassification"
        ]
    )
    for privateValue in privateValues {
        #expect(!encodedText.contains(privateValue))
    }

    let malformed = Data(#"{"hook_event_name":"PostToolUse"}"#.utf8)
    let excludedToolNames = [
        "telemetry_write",
        "metadata_read",
        "update_metadata",
        "health_token_event_enqueue"
    ]
    #expect(AgentEventAdapter.normalizeHook(malformed, observedAt: observedAt) == nil)
    for toolName in excludedToolNames {
        let data = Data(
            """
            {"hook_event_name":"PostToolUse","session_id":"root","tool_name":"\(toolName)"}
            """.utf8
        )
        #expect(AgentEventAdapter.normalizeHook(data, observedAt: observedAt) == nil)
    }
}

@Test("synthetic rollout aborts normalize without retaining payload data")
func rolloutAbortNormalizes() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let line = Data(
        #"{"timestamp":"1999-01-01T00:00:00Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"synthetic private reason","arbitrary":"synthetic private payload"}}"#.utf8
    )

    let event = try #require(
        AgentEventAdapter.normalizeRolloutLine(
            line,
            sessionID: "synthetic-session",
            role: .root,
            parentSessionID: "synthetic-parent",
            observedAt: observedAt
        )
    )
    let encodedText = try #require(
        String(data: JSONEncoder().encode(event), encoding: .utf8)
    )

    #expect(event.kind == .aborted)
    #expect(event.sessionID == "synthetic-session")
    #expect(event.parentSessionID == "synthetic-parent")
    #expect(event.timestamp == observedAt)
    #expect(event.role == .root)
    #expect(event.attention == .none)
    #expect(event.toolClassification == nil)
    #expect(!encodedText.contains("synthetic private reason"))
    #expect(!encodedText.contains("synthetic private payload"))
}

@Test("synthetic rollout completion normalizes without retaining output")
func rolloutCompletionNormalizes() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let line = Data(
        #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"synthetic private output"}}"#.utf8
    )

    let event = try #require(
        AgentEventAdapter.normalizeRolloutLine(
            line,
            sessionID: "synthetic-child",
            role: .subagent,
            parentSessionID: "synthetic-parent",
            observedAt: observedAt
        )
    )
    let encodedText = try #require(
        String(data: JSONEncoder().encode(event), encoding: .utf8)
    )

    #expect(event.kind == .completed)
    #expect(event.sessionID == "synthetic-child")
    #expect(event.parentSessionID == "synthetic-parent")
    #expect(event.role == .subagent)
    #expect(!encodedText.contains("synthetic private output"))
}

@Test("local user-input rollout records normalize without content")
func rolloutUserInputNormalizesWithoutContent() throws {
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var pendingRequestIDs = Set<String>()
    let request = Data(
        #"{"type":"event_msg","payload":{"type":"request_user_input","call_id":"synthetic-call","questions":[{"question":"synthetic private question","options":[{"label":"synthetic private option"}]}]}}"#.utf8
    )
    let unrelatedOutput = Data(
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"other-call","output":"synthetic unrelated private output"}}"#.utf8
    )
    let answer = Data(
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"synthetic-call","output":"synthetic private answer"}}"#.utf8
    )

    let required = try #require(
        AgentEventAdapter.normalizeRolloutLine(
            request,
            sessionID: "synthetic-root",
            role: .root,
            observedAt: observedAt,
            pendingAttentionRequestIDs: &pendingRequestIDs
        )
    )
    let unrelated = AgentEventAdapter.normalizeRolloutLine(
        unrelatedOutput,
        sessionID: "synthetic-root",
        role: .root,
        observedAt: observedAt,
        pendingAttentionRequestIDs: &pendingRequestIDs
    )
    let resolved = try #require(
        AgentEventAdapter.normalizeRolloutLine(
            answer,
            sessionID: "synthetic-root",
            role: .root,
            observedAt: observedAt,
            pendingAttentionRequestIDs: &pendingRequestIDs
        )
    )
    let encoded = try JSONEncoder().encode([required, resolved])
    let encodedText = try #require(String(data: encoded, encoding: .utf8))

    #expect(required.kind == .attentionChanged)
    #expect(required.attention == .required)
    #expect(unrelated == nil)
    #expect(resolved.kind == .attentionChanged)
    #expect(resolved.attention == .none)
    #expect(pendingRequestIDs.isEmpty)
    #expect(!encodedText.contains("synthetic private question"))
    #expect(!encodedText.contains("synthetic private option"))
    #expect(!encodedText.contains("synthetic private answer"))
}
