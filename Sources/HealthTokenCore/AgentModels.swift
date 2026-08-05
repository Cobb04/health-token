import Foundation

public enum CodexHookEvent: String, CaseIterable, Equatable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
}

public enum AgentRole: String, Codable, Equatable, Sendable {
    case root
    case subagent
}

public enum AgentAttention: String, Codable, Equatable, Sendable {
    case none
    case required
}

public enum AgentToolClassification: String, Codable, Equatable, Sendable {
    case ordinary
    case plan
    case userInput
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case sessionStarted
        case promptSubmitted
        case planUpdated
        case toolUsed
        case attentionChanged
        case completed
        case aborted
        case sessionRemoved
    }

    public let kind: Kind
    public let sessionID: String
    public let timestamp: Date
    public let role: AgentRole
    public let attention: AgentAttention
    public let toolClassification: AgentToolClassification?

    public init(
        kind: Kind,
        sessionID: String,
        timestamp: Date,
        role: AgentRole,
        attention: AgentAttention,
        toolClassification: AgentToolClassification? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.role = role
        self.attention = attention
        self.toolClassification = toolClassification
    }
}
