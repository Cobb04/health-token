import Foundation

public enum AgentEventAdapter {
    public static func normalizeHook(
        _ data: Data,
        observedAt: Date
    ) -> AgentEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any],
            let eventName = payload["hook_event_name"] as? String,
            let hookEvent = CodexHookEvent(rawValue: eventName),
            let sessionID = payload["session_id"] as? String,
            !sessionID.isEmpty
        else {
            return nil
        }

        let isSubagent = hookEvent == .subagentStart || hookEvent == .subagentStop
        var normalizedSessionID = sessionID
        if isSubagent {
            guard
                let agentID = payload["agent_id"] as? String,
                !agentID.isEmpty
            else {
                return nil
            }
            normalizedSessionID = agentID
        }

        let kind: AgentEvent.Kind
        let toolClassification: AgentToolClassification?

        switch hookEvent {
        case .sessionStart:
            kind = .sessionStarted
            toolClassification = planClassification(in: payload)
        case .userPromptSubmit:
            kind = .promptSubmitted
            toolClassification = planClassification(in: payload)
        case .permissionRequest:
            kind = .attentionChanged
            toolClassification = .userInput
        case .preToolUse:
            guard
                let toolName = payload["tool_name"] as? String,
                isUserInputTool(toolName)
            else {
                return nil
            }
            kind = .attentionChanged
            toolClassification = .userInput
        case .postToolUse:
            guard let toolName = payload["tool_name"] as? String else {
                return nil
            }
            if isMetadataTool(toolName) {
                return nil
            } else if isUserInputTool(toolName) {
                kind = .attentionChanged
                toolClassification = .userInput
            } else if toolName == "update_plan" || toolName.hasSuffix("__update_plan") {
                kind = .planUpdated
                toolClassification = .plan
            } else {
                kind = .toolUsed
                toolClassification = planClassification(in: payload) ?? .ordinary
            }
        case .stop:
            kind = .completed
            toolClassification = nil
        case .subagentStart:
            kind = .sessionStarted
            toolClassification = nil
        case .subagentStop:
            kind = .completed
            toolClassification = nil
        }

        return AgentEvent(
            kind: kind,
            sessionID: normalizedSessionID,
            timestamp: observedAt,
            role: isSubagent ? .subagent : .root,
            attention: attention(for: hookEvent),
            toolClassification: toolClassification
        )
    }

    public static func normalizeRolloutLine(
        _ data: Data,
        sessionID: String,
        role: AgentRole,
        observedAt: Date
    ) -> AgentEvent? {
        guard
            !sessionID.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let record = object as? [String: Any],
            record["type"] as? String == "event_msg",
            let payload = record["payload"] as? [String: Any],
            payload["type"] as? String == "turn_aborted"
        else {
            return nil
        }

        return AgentEvent(
            kind: .aborted,
            sessionID: sessionID,
            timestamp: observedAt,
            role: role,
            attention: .none
        )
    }

    private static func attention(for hookEvent: CodexHookEvent) -> AgentAttention {
        if hookEvent == .permissionRequest || hookEvent == .preToolUse {
            return .required
        }
        return .none
    }

    private static func isUserInputTool(_ toolName: String) -> Bool {
        toolName == "request_user_input" || toolName.hasSuffix("__request_user_input")
    }

    private static func isMetadataTool(_ toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized.contains("telemetry")
            || normalized.contains("metrics")
            || normalized.contains("metadata")
            || normalized.contains("health_token")
            || normalized.contains("healthtoken")
    }

    private static func planClassification(
        in payload: [String: Any]
    ) -> AgentToolClassification? {
        payload["permission_mode"] as? String == "plan" ? .plan : nil
    }
}
