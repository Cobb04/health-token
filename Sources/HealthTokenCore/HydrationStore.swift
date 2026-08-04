import Foundation

public protocol HydrationStore: AnyObject {
    func load() throws -> HydrationPersistence?
    func save(_ persistence: HydrationPersistence) throws
}

public final class InMemoryHydrationStore: HydrationStore {
    public private(set) var persistence: HydrationPersistence?

    public init(persistence: HydrationPersistence? = nil) {
        self.persistence = persistence
    }

    public func load() throws -> HydrationPersistence? {
        persistence
    }

    public func save(_ persistence: HydrationPersistence) throws {
        self.persistence = persistence
    }
}

public final class FileHydrationStore: HydrationStore {
    public let fileURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> HydrationPersistence? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(
            HydrationPersistence.self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func save(_ persistence: HydrationPersistence) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(persistence).write(to: fileURL, options: .atomic)
    }
}
