import Foundation

public enum CodexIntegrationHealth: String, Equatable, Sendable {
    case connected
    case fallbackOnly
    case unavailable
}

public enum CodexHookInstallerError: Error, Equatable {
    case invalidConfiguration
}

public final class CodexHookInstaller {
    public let hooksURL: URL
    public let sessionsURL: URL
    private let fileManager: FileManager

    public init(
        hooksURL: URL,
        sessionsURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.hooksURL = hooksURL
        self.sessionsURL = sessionsURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    public func enable(command: String) throws {
        var root = try loadConfiguration()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        remove(command: command, from: &hooks)

        let handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 1
        ]
        for event in CodexHookEvent.allCases {
            var groups = hooks[event.rawValue] as? [[String: Any]] ?? []
            groups.append(["hooks": [handler]])
            hooks[event.rawValue] = groups
        }

        root["hooks"] = hooks
        try saveConfiguration(root)
    }

    public func disable(command: String) throws {
        guard fileManager.fileExists(atPath: hooksURL.path) else { return }
        var root = try loadConfiguration()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        remove(command: command, from: &hooks)
        root["hooks"] = hooks
        try saveConfiguration(root)
    }

    public func isInstalled(command: String) -> Bool {
        guard
            let root = try? loadConfiguration(),
            let hooks = root["hooks"] as? [String: Any]
        else {
            return false
        }

        return CodexHookEvent.allCases.allSatisfy { event in
            guard let groups = hooks[event.rawValue] as? [[String: Any]] else {
                return false
            }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return handlers.contains { $0["command"] as? String == command }
            }
        }
    }

    public func health(
        command: String,
        recentlyObservedEvent: Bool = false
    ) -> CodexIntegrationHealth {
        let installed = isInstalled(command: command)
        if installed && recentlyObservedEvent {
            return .connected
        }

        var isDirectory: ObjCBool = false
        let sessionsAvailable = fileManager.fileExists(
            atPath: sessionsURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: sessionsURL.path)
        if installed || sessionsAvailable {
            return .fallbackOnly
        }

        return .unavailable
    }

    private func loadConfiguration() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: hooksURL.path) else {
            return [
                "description": "Local Codex lifecycle hooks.",
                "hooks": [String: Any]()
            ]
        }

        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: hooksURL)
        )
        guard let root = object as? [String: Any] else {
            throw CodexHookInstallerError.invalidConfiguration
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) {
            throw CodexHookInstallerError.invalidConfiguration
        }
        return root
    }

    private func saveConfiguration(_ configuration: [String: Any]) throws {
        try fileManager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: hooksURL, options: .atomic)
    }

    private func remove(command: String, from hooks: inout [String: Any]) {
        for eventName in Array(hooks.keys) {
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                continue
            }

            let retainedGroups = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return group
                }
                let retainedHandlers = handlers.filter {
                    $0["command"] as? String != command
                }
                guard !retainedHandlers.isEmpty else { return nil }
                var retainedGroup = group
                retainedGroup["hooks"] = retainedHandlers
                return retainedGroup
            }

            if retainedGroups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = retainedGroups
            }
        }
    }
}
