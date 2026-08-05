import Foundation

public final class CodexRolloutMonitor {
    private struct SessionContext {
        let sessionID: String
        let role: AgentRole
        let parentSessionID: String?
    }

    private struct AttentionCorrelation {
        private var pendingRequestIDs = Set<String>()
        private var lastActivityAt: Date?

        mutating func normalize(
            _ data: Data,
            sessionID: String,
            role: AgentRole,
            parentSessionID: String?,
            observedAt: Date
        ) -> AgentEvent? {
            let previousRequestIDs = pendingRequestIDs
            let event = AgentEventAdapter.normalizeRolloutLine(
                data,
                sessionID: sessionID,
                role: role,
                parentSessionID: parentSessionID,
                observedAt: observedAt,
                pendingAttentionRequestIDs: &pendingRequestIDs
            )
            if pendingRequestIDs != previousRequestIDs {
                lastActivityAt = pendingRequestIDs.isEmpty ? nil : observedAt
            }
            return event
        }

        mutating func expire(
            at observedAt: Date,
            after interval: TimeInterval
        ) {
            guard
                let lastActivityAt,
                observedAt.timeIntervalSince(lastActivityAt) >= interval
            else {
                return
            }
            reset()
        }

        mutating func reset() {
            pendingRequestIDs.removeAll()
            lastActivityAt = nil
        }
    }

    private struct Cursor {
        static let empty = Cursor(
            offset: 0,
            sessionID: nil,
            role: .root,
            parentSessionID: nil
        )

        var offset: UInt64
        var sessionID: String?
        var role: AgentRole
        var parentSessionID: String?
        var attentionCorrelation = AttentionCorrelation()
        var remainder = Data()
    }

    public let sessionsURL: URL

    private let fileManager: FileManager
    private let maxFiles: Int
    private let maxScannedEntries: Int
    private let maxBytesPerFile: Int
    private let activeSessionInterval: TimeInterval
    private var cursors: [URL: Cursor] = [:]
    private var initialized = false

    public init(
        sessionsURL: URL,
        fileManager: FileManager = .default,
        maxFiles: Int = 8,
        maxScannedEntries: Int = 512,
        maxBytesPerFile: Int = 64 * 1024,
        activeSessionInterval: TimeInterval = 5 * 60
    ) {
        self.sessionsURL = sessionsURL
        self.fileManager = fileManager
        self.maxFiles = maxFiles
        self.maxScannedEntries = maxScannedEntries
        self.maxBytesPerFile = maxBytesPerFile
        self.activeSessionInterval = activeSessionInterval
    }

    public func poll(observedAt: Date) throws -> [AgentEvent] {
        let rolloutURLs = try recentRolloutURLs()
        let activeURLs = Set(rolloutURLs)
        var removedSessionIDs = Set<String>()
        let removedEvents = cursors.compactMap { url, cursor -> AgentEvent? in
            guard
                initialized,
                !fileManager.fileExists(atPath: url.path),
                let sessionID = cursor.sessionID,
                removedSessionIDs.insert(sessionID).inserted
            else {
                return nil
            }
            return AgentEvent(
                kind: .sessionRemoved,
                sessionID: sessionID,
                parentSessionID: cursor.parentSessionID,
                timestamp: observedAt,
                role: cursor.role,
                attention: .none
            )
        }
        cursors = cursors.filter { activeURLs.contains($0.key) }

        if !initialized {
            var events: [AgentEvent] = []
            for rolloutURL in rolloutURLs {
                let size = try fileSize(of: rolloutURL)
                let context = try sessionContext(in: rolloutURL, size: size)
                cursors[rolloutURL] = Cursor(
                    offset: size,
                    sessionID: context?.sessionID,
                    role: context?.role ?? .root,
                    parentSessionID: context?.parentSessionID
                )
                if
                    let context,
                    context.role == .subagent,
                    try isRecentlyActive(rolloutURL, observedAt: observedAt),
                    try !hasTerminalEvent(in: rolloutURL, size: size)
                {
                    events.append(sessionStartedEvent(
                        for: context,
                        observedAt: observedAt
                    ))
                }
            }
            initialized = true
            return events
        }

        var events = removedEvents
        for rolloutURL in rolloutURLs {
            let size = try fileSize(of: rolloutURL)
            var cursor = cursors[rolloutURL] ?? .empty
            if cursor.offset > size {
                cursor = .empty
            }
            cursor.attentionCorrelation.expire(
                at: observedAt,
                after: activeSessionInterval
            )
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
                    let isNewSession = cursor.sessionID != context.sessionID
                    if isNewSession {
                        cursor.attentionCorrelation.reset()
                    }
                    cursor.sessionID = context.sessionID
                    cursor.role = context.role
                    cursor.parentSessionID = context.parentSessionID
                    if isNewSession, context.role == .subagent {
                        events.append(sessionStartedEvent(
                            for: context,
                            observedAt: observedAt
                        ))
                    }
                    continue
                }
                guard let sessionID = cursor.sessionID else { continue }
                if let event = cursor.attentionCorrelation.normalize(
                    line,
                    sessionID: sessionID,
                    role: cursor.role,
                    parentSessionID: cursor.parentSessionID,
                    observedAt: observedAt
                ) {
                    events.append(event)
                }
            }
            cursors[rolloutURL] = cursor
        }

        return events
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
    ) throws -> SessionContext? {
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
    ) -> SessionContext? {
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
        let parentSessionID = verifiedParentSessionID(in: payload)
        return SessionContext(
            sessionID: sessionID,
            role: parentSessionID == nil ? .root : .subagent,
            parentSessionID: parentSessionID
        )
    }

    private func verifiedParentSessionID(
        in payload: [String: Any]
    ) -> String? {
        guard
            let source = payload["source"] as? [String: Any],
            let subagent = source["subagent"] as? [String: Any],
            let threadSpawn = subagent["thread_spawn"] as? [String: Any],
            let parentSessionID = threadSpawn["parent_thread_id"] as? String,
            !parentSessionID.isEmpty,
            parentSessionID == parentSessionID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        else {
            return nil
        }
        return parentSessionID
    }

    private func sessionStartedEvent(
        for context: SessionContext,
        observedAt: Date
    ) -> AgentEvent {
        AgentEvent(
            kind: .sessionStarted,
            sessionID: context.sessionID,
            parentSessionID: context.parentSessionID,
            timestamp: observedAt,
            role: .subagent,
            attention: .none
        )
    }

    private func isRecentlyActive(
        _ url: URL,
        observedAt: Date
    ) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date else {
            return false
        }
        let age = observedAt.timeIntervalSince(modifiedAt)
        return age >= 0 && age < activeSessionInterval
    }

    private func hasTerminalEvent(
        in url: URL,
        size: UInt64
    ) throws -> Bool {
        let start = size > UInt64(maxBytesPerFile)
            ? size - UInt64(maxBytesPerFile)
            : 0
        let tail = try read(url, offset: start, count: Int(size - start))
        var lines = tail.split(separator: 0x0A).map { Data($0) }
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines.contains { line in
            guard let event = AgentEventAdapter.normalizeRolloutLine(
                line,
                sessionID: "startup-inspection",
                role: .root,
                observedAt: .distantPast
            ) else {
                return false
            }
            return event.kind == .completed || event.kind == .aborted
        }
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
