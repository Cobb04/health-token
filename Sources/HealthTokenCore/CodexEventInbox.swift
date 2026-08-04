import Foundation

public final class CodexEventInbox {
    public let directoryURL: URL

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.sortedKeys]
    }

    public static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("HealthToken", isDirectory: true)
            .appendingPathComponent("codex-events", isDirectory: true)
    }

    public func enqueue(_ event: AgentEvent) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let eventURL = directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try encoder.encode(event).write(to: eventURL, options: .atomic)
    }

    public func drain() throws -> [AgentEvent] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let eventURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var events: [AgentEvent] = []
        for eventURL in eventURLs {
            if
                let data = try? Data(contentsOf: eventURL),
                let event = try? decoder.decode(AgentEvent.self, from: data)
            {
                events.append(event)
            }
            try? fileManager.removeItem(at: eventURL)
        }
        events.sort { $0.timestamp < $1.timestamp }
        return events
    }
}
