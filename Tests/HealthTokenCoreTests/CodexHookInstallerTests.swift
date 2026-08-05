import Foundation
import Testing
@testable import HealthTokenCore

@Test("enabling and disabling observation preserves unrelated Codex hooks")
func hookConfigurationIsScopedAndReversible() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let hooksURL = directory.appendingPathComponent("hooks.json")
    let unrelated: [String: Any] = [
        "description": "Keep this description",
        "hooks": [
            "PreToolUse": [
                [
                    "matcher": "Bash",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "/usr/bin/existing-hook",
                            "timeout": 12
                        ]
                    ]
                ]
            ]
        ]
    ]
    try JSONSerialization.data(
        withJSONObject: unrelated,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: hooksURL)
    let command = "'/Applications/Health Token.app/Contents/MacOS/HealthTokenHook'"
    let installer = CodexHookInstaller(hooksURL: hooksURL)

    try installer.enable(command: command)
    try installer.enable(command: command)

    let enabled = try hooksObject(at: hooksURL)
    let enabledHooks = try #require(enabled["hooks"] as? [String: Any])
    #expect(enabled["description"] as? String == "Keep this description")
    #expect(
        healthTokenCommandCount(in: enabledHooks, command: command)
            == CodexHookEvent.allCases.count
    )
    #expect(containsCommand(enabledHooks, command: "/usr/bin/existing-hook"))
    #expect(installer.isInstalled(command: command))

    try installer.disable(command: command)

    let disabled = try hooksObject(at: hooksURL)
    let disabledHooks = try #require(disabled["hooks"] as? [String: Any])
    #expect(disabled["description"] as? String == "Keep this description")
    #expect(healthTokenCommandCount(in: disabledHooks, command: command) == 0)
    #expect(containsCommand(disabledHooks, command: "/usr/bin/existing-hook"))
    #expect(!installer.isInstalled(command: command))

    try FileManager.default.removeItem(at: hooksURL)
    try installer.disable(command: command)
    #expect(!FileManager.default.fileExists(atPath: hooksURL.path))
}

@Test("integration health distinguishes connected, fallback-only, and unavailable")
func integrationHealthReflectsAvailableObservation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let hooksURL = directory.appendingPathComponent("codex/hooks.json")
    let sessionsURL = directory.appendingPathComponent("codex/sessions")
    let command = "'/Applications/Health Token.app/Contents/MacOS/HealthTokenHook'"
    let installer = CodexHookInstaller(
        hooksURL: hooksURL,
        sessionsURL: sessionsURL
    )

    #expect(installer.health(command: command) == .unavailable)

    try FileManager.default.createDirectory(
        at: sessionsURL,
        withIntermediateDirectories: true
    )
    #expect(installer.health(command: command) == .fallbackOnly)

    try installer.enable(command: command)
    #expect(installer.health(command: command) == .fallbackOnly)
    #expect(
        installer.health(
            command: command,
            recentlyObservedEvent: true
        ) == .connected
    )
    #expect(
        installer.health(
            command: command,
            recentlyObservedEvent: true,
            observationFailed: true
        ) == .fallbackOnly
    )

    var partial = try hooksObject(at: hooksURL)
    var partialHooks = try #require(partial["hooks"] as? [String: Any])
    partialHooks.removeValue(forKey: CodexHookEvent.sessionStart.rawValue)
    partial["hooks"] = partialHooks
    try JSONSerialization.data(
        withJSONObject: partial,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: hooksURL)
    #expect(!installer.isInstalled(command: command))
    #expect(
        installer.health(
            command: command,
            recentlyObservedEvent: true
        ) == .fallbackOnly
    )
}

private func hooksObject(at url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}

private func healthTokenCommandCount(
    in hooks: [String: Any],
    command: String
) -> Int {
    hooks.values.reduce(0) { count, value in
        guard let groups = value as? [[String: Any]] else { return count }
        return count + groups.reduce(0) { groupCount, group in
            guard let handlers = group["hooks"] as? [[String: Any]] else {
                return groupCount
            }
            return groupCount + handlers.filter {
                $0["command"] as? String == command
            }.count
        }
    }
}

private func containsCommand(_ hooks: [String: Any], command: String) -> Bool {
    healthTokenCommandCount(in: hooks, command: command) > 0
}
