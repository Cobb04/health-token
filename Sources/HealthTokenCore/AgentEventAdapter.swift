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
                kind = .toolUsed
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
            parentSessionID: isSubagent ? sessionID : nil,
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
        parentSessionID: String? = nil,
        observedAt: Date
    ) -> AgentEvent? {
        var pendingAttentionRequestIDs = Set<String>()
        return normalizeRolloutLine(
            data,
            sessionID: sessionID,
            role: role,
            parentSessionID: parentSessionID,
            observedAt: observedAt,
            pendingAttentionRequestIDs: &pendingAttentionRequestIDs
        )
    }

    static func normalizeRolloutLine(
        _ data: Data,
        sessionID: String,
        role: AgentRole,
        parentSessionID: String? = nil,
        observedAt: Date,
        pendingAttentionRequestIDs: inout Set<String>
    ) -> AgentEvent? {
        guard
            !sessionID.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let record = object as? [String: Any],
            let recordType = record["type"] as? String,
            let payload = record["payload"] as? [String: Any]
        else {
            return nil
        }

        let kind: AgentEvent.Kind
        let attention: AgentAttention
        let toolClassification: AgentToolClassification?

        if recordType == "response_item" {
            guard let responseType = payload["type"] as? String else {
                return nil
            }
            if responseType == "function_call" || responseType == "custom_tool_call" {
                guard
                    let toolName = payload["name"] as? String,
                    !toolName.isEmpty,
                    !isMetadataTool(toolName)
                else {
                    return nil
                }
                if isPlanTool(toolName, payload: payload) {
                    kind = .planUpdated
                    toolClassification = .plan
                } else {
                    kind = .toolUsed
                    toolClassification = isUserInputTool(toolName) ? .userInput : .ordinary
                }
                attention = .none
            } else if responseType == "function_call_output" {
                guard
                    let callID = payload["call_id"] as? String,
                    pendingAttentionRequestIDs.remove(callID) != nil,
                    pendingAttentionRequestIDs.isEmpty
                else {
                    return nil
                }
                kind = .attentionChanged
                attention = .none
                toolClassification = .userInput
            } else {
                return nil
            }
        } else if recordType == "event_msg",
                  let eventType = payload["type"] as? String {
            switch eventType {
            case "task_started", "user_message":
                kind = .promptSubmitted
                attention = .none
                toolClassification = nil
            case "turn_aborted":
                pendingAttentionRequestIDs.removeAll()
                kind = .aborted
                attention = .none
                toolClassification = nil
            case "task_complete":
                pendingAttentionRequestIDs.removeAll()
                kind = .completed
                attention = .none
                toolClassification = nil
            case "request_user_input",
                 "exec_approval_request",
                 "apply_patch_approval_request",
                 "request_permissions":
                guard
                    let callID = payload["call_id"] as? String,
                    !callID.isEmpty
                else {
                    return nil
                }
                pendingAttentionRequestIDs.insert(callID)
                kind = .attentionChanged
                attention = .required
                toolClassification = .userInput
            case "exec_command_begin",
                 "patch_apply_begin",
                 "mcp_tool_call_begin":
                guard
                    let callID = payload["call_id"] as? String,
                    pendingAttentionRequestIDs.remove(callID) != nil,
                    pendingAttentionRequestIDs.isEmpty
                else {
                    return nil
                }
                kind = .attentionChanged
                attention = .none
                toolClassification = .userInput
            default:
                return nil
            }
        } else {
            return nil
        }

        return AgentEvent(
            kind: kind,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            timestamp: observedAt,
            role: role,
            attention: attention,
            toolClassification: toolClassification
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

    private static func isPlanTool(
        _ toolName: String,
        payload: [String: Any]
    ) -> Bool {
        if toolName == "update_plan" || toolName.hasSuffix("__update_plan") {
            return true
        }
        guard
            (toolName == "exec" || toolName.hasSuffix("__exec")),
            let input = payload["input"] as? String
        else {
            return false
        }
        return input.contains("tools.update_plan(")
            || input.contains("tools.update_plan (")
    }

    private static func planClassification(
        in payload: [String: Any]
    ) -> AgentToolClassification? {
        payload["permission_mode"] as? String == "plan" ? .plan : nil
    }
}
