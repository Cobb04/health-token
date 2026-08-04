import Foundation

public final class CodexRolloutMonitor {
    private struct Cursor {
        var offset: UInt64
        var sessionID: String?
        var role: AgentRole
        var remainder = Data()
    }

    public let sessionsURL: URL

    private let fileManager: FileManager
    private let maxFiles: Int
    private let maxScannedEntries: Int
    private let maxBytesPerFile: Int
    private var cursors: [URL: Cursor] = [:]
    private var initialized = false

    public init(
        sessionsURL: URL,
        fileManager: FileManager = .default,
        maxFiles: Int = 8,
        maxScannedEntries: Int = 512,
        maxBytesPerFile: Int = 64 * 1024
    ) {
        self.sessionsURL = sessionsURL
        self.fileManager = fileManager
        self.maxFiles = maxFiles
        self.maxScannedEntries = maxScannedEntries
        self.maxBytesPerFile = maxBytesPerFile
    }

    public func poll(observedAt: Date) throws -> [AgentEvent] {
        let rolloutURLs = try recentRolloutURLs()
        let activeURLs = Set(rolloutURLs)
        cursors = cursors.filter { activeURLs.contains($0.key) }

        if !initialized {
            for rolloutURL in rolloutURLs {
                let size = try fileSize(of: rolloutURL)
                let context = try sessionContext(in: rolloutURL, size: size)
                cursors[rolloutURL] = Cursor(
                    offset: size,
                    sessionID: context?.sessionID,
                    role: context?.role ?? .root
                )
            }
            initialized = true
            return []
        }

        var events: [AgentEvent] = []
        for rolloutURL in rolloutURLs {
            let size = try fileSize(of: rolloutURL)
            var cursor = cursors[rolloutURL]
                ?? Cursor(offset: 0, sessionID: nil, role: .root)
            if cursor.offset > size {
                cursor = Cursor(offset: 0, sessionID: nil, role: .root)
            }
            guard cursor.offset < size else {
                cursors[rolloutURL] = cursor
                continue
            }

            var start = cursor.offset
            if size - start > UInt64(maxBytesPerFile) {
                start = size - UInt64(maxBytesPerFile)
                cursor.remainder = Data()
            }
            let chunk = try read(
                rolloutURL,
                offset: start,
                count: Int(size - start)
            )
            let skippedPrefix = start > cursor.offset
            cursor.offset = size

            var lines = completeLines(
                in: chunk,
                remainder: &cursor.remainder
            )
            if skippedPrefix, !lines.isEmpty {
                lines.removeFirst()
            }

            for line in lines {
                if let context = sessionContext(from: line) {
                    cursor.sessionID = context.sessionID
                    cursor.role = context.role
                    continue
                }
                guard let sessionID = cursor.sessionID else { continue }
                if let event = AgentEventAdapter.normalizeRolloutLine(
                    line,
                    sessionID: sessionID,
                    role: cursor.role,
                    observedAt: observedAt
                ) {
                    events.append(event)
                }
            }
            cursors[rolloutURL] = cursor
        }

        return events.sorted { $0.timestamp < $1.timestamp }
    }

    public func reset() {
        cursors.removeAll()
        initialized = false
    }

    private func recentRolloutURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return [] }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        var scannedEntries = 0
        func scan(_ directory: URL, depth: Int) throws {
            guard scannedEntries < maxScannedEntries, depth <= 6 else { return }
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent > $1.lastPathComponent }

            for url in entries {
                guard scannedEntries < maxScannedEntries else { return }
                scannedEntries += 1
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey]
                )
                if values.isDirectory == true {
                    try scan(url, depth: depth + 1)
                } else if
                    url.pathExtension == "jsonl",
                    url.lastPathComponent.hasPrefix("rollout-")
                {
                    candidates.append((
                        url,
                        values.contentModificationDate ?? .distantPast
                    ))
                }
            }
        }
        try scan(sessionsURL, depth: 0)

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map(\.url)
    }

    private func sessionContext(
        in url: URL,
        size: UInt64
    ) throws -> (sessionID: String, role: AgentRole)? {
        let prefix = try read(
            url,
            offset: 0,
            count: min(Int(size), maxBytesPerFile)
        )
        for line in prefix.split(separator: 0x0A) {
            if let context = sessionContext(from: Data(line)) {
                return context
            }
        }
        return nil
    }

    private func sessionContext(
        from data: Data
    ) -> (sessionID: String, role: AgentRole)? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let record = object as? [String: Any],
            record["type"] as? String == "session_meta",
            let payload = record["payload"] as? [String: Any],
            let sessionID = payload["id"] as? String,
            !sessionID.isEmpty
        else {
            return nil
        }
        let source = payload["source"] as? [String: Any]
        let role: AgentRole = source?["subagent"] == nil ? .root : .subagent
        return (sessionID, role)
    }

    private func completeLines(
        in chunk: Data,
        remainder: inout Data
    ) -> [Data] {
        var combined = remainder
        combined.append(chunk)
        var pieces = combined.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        if combined.last == 0x0A {
            remainder = Data()
            pieces.removeLast()
        } else {
            remainder = pieces.isEmpty ? Data() : Data(pieces.removeLast())
        }
        return pieces.filter { !$0.isEmpty }.map { Data($0) }
    }

    private func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func read(_ url: URL, offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
}
