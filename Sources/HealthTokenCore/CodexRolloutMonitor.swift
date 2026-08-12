import Foundation

public enum CodexObservationPolicy {
    public static let presentationPollInterval: TimeInterval = 1
}

public struct CodexObservationLimits: Equatable, Sendable {
    public let maxCandidateFiles: Int
    public let maxScannedEntries: Int
    public let maxCandidateAge: TimeInterval
    public let maxBytesPerFile: Int
    public let maxTotalBytesPerPoll: Int
    public let maxSessionMetadataBytes: Int
    public let maxRecordBytes: Int
    public let maxPendingAttentionRequests: Int
    public let startupRecoveryInterval: TimeInterval
    public let activeSessionInterval: TimeInterval

    public init(
        maxCandidateFiles: Int = 8,
        maxScannedEntries: Int = 512,
        maxCandidateAge: TimeInterval = 10 * 60,
        maxBytesPerFile: Int = 4 * 1024 * 1024,
        maxTotalBytesPerPoll: Int = 16 * 1024 * 1024,
        maxSessionMetadataBytes: Int = 256 * 1024,
        maxRecordBytes: Int = 32 * 1024,
        maxPendingAttentionRequests: Int = 32,
        startupRecoveryInterval: TimeInterval = 2 * 60,
        activeSessionInterval: TimeInterval = 5 * 60
    ) {
        precondition(maxCandidateFiles > 0)
        precondition(maxScannedEntries > 0)
        precondition(maxCandidateAge > 0)
        precondition(maxBytesPerFile > 0)
        precondition(maxTotalBytesPerPoll > 0)
        precondition(maxSessionMetadataBytes > 0)
        precondition(maxRecordBytes > 0)
        precondition(maxPendingAttentionRequests > 0)
        precondition(startupRecoveryInterval > 0)
        precondition(activeSessionInterval > 0)
        self.maxCandidateFiles = maxCandidateFiles
        self.maxScannedEntries = maxScannedEntries
        self.maxCandidateAge = maxCandidateAge
        self.maxBytesPerFile = maxBytesPerFile
        self.maxTotalBytesPerPoll = maxTotalBytesPerPoll
        self.maxSessionMetadataBytes = maxSessionMetadataBytes
        self.maxRecordBytes = maxRecordBytes
        self.maxPendingAttentionRequests = maxPendingAttentionRequests
        self.startupRecoveryInterval = startupRecoveryInterval
        self.activeSessionInterval = activeSessionInterval
    }
}

public struct CodexObservationMetrics: Equatable, Sendable {
    public internal(set) var scannedEntries = 0
    public internal(set) var candidateFiles = 0
    public internal(set) var activeFiles = 0
    public internal(set) var filesRead = 0
    public internal(set) var bytesRead = 0
    public internal(set) var maximumFileBytesRead = 0
    public internal(set) var recordsParsed = 0
    public internal(set) var discardedRecords = 0
    public internal(set) var retainedRemainderBytes = 0
    public internal(set) var pendingAttentionRequests = 0

    public init() {}
}

public final class CodexRolloutMonitor {
    private struct SessionContext {
        let sessionID: String
        let role: AgentRole
        let parentSessionID: String?
    }

    private struct AttentionCorrelation {
        private var pendingRequestIDs = Set<String>()
        private var overflowed = false
        private var lastActivityAt: Date?

        var pendingCount: Int {
            overflowed ? 1 : pendingRequestIDs.count
        }

        mutating func normalize(
            _ data: Data,
            sessionID: String,
            role: AgentRole,
            parentSessionID: String?,
            observedAt: Date,
            maxPendingRequests: Int
        ) -> AgentEvent? {
            if overflowed {
                var ignoredRequestIDs = Set<String>()
                let event = AgentEventAdapter.normalizeRolloutLine(
                    data,
                    sessionID: sessionID,
                    role: role,
                    parentSessionID: parentSessionID,
                    observedAt: observedAt,
                    pendingAttentionRequestIDs: &ignoredRequestIDs
                )
                if event?.kind == .completed || event?.kind == .aborted {
                    reset()
                    return event
                }
                if event?.attention == .required {
                    lastActivityAt = observedAt
                    return event
                }
                return nil
            }

            let previousRequestIDs = pendingRequestIDs
            let event = AgentEventAdapter.normalizeRolloutLine(
                data,
                sessionID: sessionID,
                role: role,
                parentSessionID: parentSessionID,
                observedAt: observedAt,
                pendingAttentionRequestIDs: &pendingRequestIDs
            )
            if pendingRequestIDs.count > maxPendingRequests {
                pendingRequestIDs.removeAll(keepingCapacity: false)
                overflowed = true
                lastActivityAt = observedAt
                return event
            }
            if pendingRequestIDs != previousRequestIDs {
                lastActivityAt = pendingRequestIDs.isEmpty ? nil : observedAt
            }
            return event
        }

        mutating func expire(at observedAt: Date, after interval: TimeInterval) {
            guard let lastActivityAt,
                  observedAt.timeIntervalSince(lastActivityAt) >= interval
            else {
                return
            }
            reset()
        }

        mutating func reset() {
            pendingRequestIDs.removeAll(keepingCapacity: false)
            overflowed = false
            lastActivityAt = nil
        }

        mutating func restore(
            requestIDs: Set<String>,
            lastActivityAt: Date,
            maxPendingRequests: Int
        ) {
            if requestIDs.count > maxPendingRequests {
                pendingRequestIDs.removeAll(keepingCapacity: false)
                overflowed = true
            } else {
                pendingRequestIDs = requestIDs
                overflowed = false
            }
            self.lastActivityAt = lastActivityAt
        }
    }

    private struct Cursor {
        var offset: UInt64
        var sessionID: String?
        var role: AgentRole
        var parentSessionID: String?
        var attentionCorrelation = AttentionCorrelation()
        var remainder = Data()
        var discardingOversizedRecord = false
        var isReadingFirstRecord = true
        var lastRecordTimestamp: Date?
        var minimumEventTimestamp: Date?
        var hasAnnouncedSubagent = false
    }

    private struct PollReadState {
        var metrics = CodexObservationMetrics()
        var fileBytes: [URL: Int] = [:]
        var filesRead = Set<URL>()

        mutating func allowedCount(
            requested: Int,
            for url: URL,
            limits: CodexObservationLimits
        ) -> Int {
            let fileRemaining = max(
                0,
                limits.maxBytesPerFile - (fileBytes[url] ?? 0)
            )
            let totalRemaining = max(
                0,
                limits.maxTotalBytesPerPoll - metrics.bytesRead
            )
            return min(max(0, requested), fileRemaining, totalRemaining)
        }

        mutating func recordRead(_ count: Int, from url: URL) {
            guard count > 0 else { return }
            filesRead.insert(url)
            fileBytes[url, default: 0] += count
            metrics.bytesRead += count
            metrics.filesRead = filesRead.count
            metrics.maximumFileBytesRead = max(
                metrics.maximumFileBytesRead,
                fileBytes[url] ?? 0
            )
        }
    }

    private struct StartupRecovery {
        let requestIDs: Set<String>
        let lastActivityAt: Date
    }

    public let sessionsURL: URL
    public let limits: CodexObservationLimits
    public private(set) var lastPollMetrics = CodexObservationMetrics()

    private let fileManager: FileManager
    private var cursors: [URL: Cursor] = [:]
    private var initialized = false
    private var startedAt: Date?
    private var pollRotation = 0

    public init(
        sessionsURL: URL,
        fileManager: FileManager = .default,
        limits: CodexObservationLimits = CodexObservationLimits()
    ) {
        self.sessionsURL = sessionsURL
        self.fileManager = fileManager
        self.limits = limits
    }

    public convenience init(
        sessionsURL: URL,
        fileManager: FileManager = .default,
        maxBytesPerFile: Int
    ) {
        self.init(
            sessionsURL: sessionsURL,
            fileManager: fileManager,
            limits: CodexObservationLimits(
                maxBytesPerFile: maxBytesPerFile,
                maxRecordBytes: maxBytesPerFile
            )
        )
    }

    public func poll(observedAt: Date) throws -> [AgentEvent] {
        if startedAt == nil {
            startedAt = observedAt
        }
        var readState = PollReadState()
        let rolloutURLs = try recentRolloutURLs(
            observedAt: observedAt,
            readState: &readState
        )
        readState.metrics.activeFiles = rolloutURLs.count

        let events: [AgentEvent]
        if initialized {
            events = try pollSteadyState(
                rolloutURLs: rolloutURLs,
                observedAt: observedAt,
                readState: &readState
            )
        } else {
            events = try pollStartup(
                rolloutURLs: rolloutURLs,
                observedAt: observedAt,
                readState: &readState
            )
            initialized = true
        }

        readState.metrics.retainedRemainderBytes = cursors.values.reduce(0) {
            $0 + $1.remainder.count
        }
        readState.metrics.pendingAttentionRequests = cursors.values.reduce(0) {
            $0 + $1.attentionCorrelation.pendingCount
        }
        lastPollMetrics = readState.metrics
        return events
    }

    public func reset() {
        cursors.removeAll()
        initialized = false
        startedAt = nil
        pollRotation = 0
        lastPollMetrics = CodexObservationMetrics()
    }

    private func pollStartup(
        rolloutURLs: [URL],
        observedAt: Date,
        readState: inout PollReadState
    ) throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for rolloutURL in rolloutURLs {
            let size = try fileSize(of: rolloutURL)
            let metadata = try sessionContext(
                in: rolloutURL,
                size: size,
                readState: &readState
            )
            let context = metadata.context
            let rootSessionID = metadata.hasIdentityMismatch
                ? nil
                : context?.sessionID ?? sessionIDFromRolloutFilename(rolloutURL)
            var cursor = Cursor(
                offset: size,
                sessionID: rootSessionID,
                role: context?.role ?? .root,
                parentSessionID: context?.parentSessionID
            )
            cursor.isReadingFirstRecord = size == 0
            if let context,
               context.role == .root,
               let recovered = try recoverAttention(
                   in: rolloutURL,
                   size: size,
                   context: context,
                   observedAt: observedAt,
                   readState: &readState
               ) {
                cursor.attentionCorrelation.restore(
                    requestIDs: recovered.requestIDs,
                    lastActivityAt: recovered.lastActivityAt,
                    maxPendingRequests: limits.maxPendingAttentionRequests
                )
                events.append(AgentEvent(
                    kind: .attentionChanged,
                    sessionID: context.sessionID,
                    timestamp: observedAt,
                    role: .root,
                    attention: .required,
                    toolClassification: .userInput
                ))
            }
            cursors[rolloutURL] = cursor
        }
        return events
    }

    private func pollSteadyState(
        rolloutURLs: [URL],
        observedAt: Date,
        readState: inout PollReadState
    ) throws -> [AgentEvent] {
        let activeURLs = Set(rolloutURLs)
        var events: [AgentEvent] = []
        var removedSessionIDs = Set<String>()
        for (url, cursor) in cursors where !activeURLs.contains(url) {
            if let sessionID = cursor.sessionID,
               removedSessionIDs.insert(sessionID).inserted {
                events.append(sessionRemovedEvent(from: cursor, observedAt: observedAt))
            }
        }
        cursors = cursors.filter { activeURLs.contains($0.key) }

        let orderedURLs = rotated(rolloutURLs)
        if !rolloutURLs.isEmpty {
            pollRotation = (pollRotation + 1) % rolloutURLs.count
        }

        for rolloutURL in orderedURLs {
            let size = try fileSize(of: rolloutURL)
            var cursor = try cursors[rolloutURL] ?? liveAttachmentCursor(
                for: rolloutURL,
                size: size,
                observedAt: observedAt,
                readState: &readState
            )
            if cursor.offset > size {
                if cursor.sessionID != nil {
                    events.append(sessionRemovedEvent(from: cursor, observedAt: observedAt))
                }
                cursor = Cursor(
                    offset: size,
                    sessionID: sessionIDFromRolloutFilename(rolloutURL),
                    role: .root,
                    parentSessionID: nil
                )
                cursor.isReadingFirstRecord = size == 0
                cursors[rolloutURL] = cursor
                continue
            }

            cursor.attentionCorrelation.expire(
                at: observedAt,
                after: limits.activeSessionInterval
            )
            let available = size - cursor.offset
            guard available > 0 else {
                cursors[rolloutURL] = cursor
                continue
            }

            let requested = min(
                Int(min(available, UInt64(Int.max))),
                limits.maxBytesPerFile
            )
            let allowedCount = readState.allowedCount(
                requested: requested,
                for: rolloutURL,
                limits: limits
            )
            guard allowedCount > 0 else {
                cursors[rolloutURL] = cursor
                continue
            }
            let chunk = try read(
                rolloutURL,
                offset: cursor.offset,
                requestedCount: allowedCount,
                readState: &readState
            )
            guard !chunk.isEmpty else {
                cursors[rolloutURL] = cursor
                continue
            }
            cursor.offset += UInt64(chunk.count)
            let parsed = completeLines(
                in: chunk,
                remainder: &cursor.remainder,
                discardingOversizedRecord: &cursor.discardingOversizedRecord,
                isReadingFirstRecord: &cursor.isReadingFirstRecord
            )
            readState.metrics.discardedRecords += parsed.discardedRecords
            let malformedRecordCount = parsed.lines.filter {
                !isStructurallyValidRecord($0)
            }.count
            readState.metrics.discardedRecords += malformedRecordCount
            let batchHasAmbiguousFraming = parsed.hasPartialRecord
                || parsed.discardedRecords > 0
                || malformedRecordCount > 0

            for line in parsed.lines {
                guard isStructurallyValidRecord(line) else { continue }
                readState.metrics.recordsParsed += 1
                if let minimumEventTimestamp = cursor.minimumEventTimestamp {
                    guard let timestamp = recordTimestamp(from: line),
                          timestamp >= minimumEventTimestamp
                    else {
                        continue
                    }
                }
                let filenameSessionID = sessionIDFromRolloutFilename(rolloutURL)
                if hasMismatchedSessionIdentity(
                    in: line,
                    expectedSessionID: filenameSessionID
                ) {
                    cursor.sessionID = nil
                    cursor.role = .root
                    cursor.parentSessionID = nil
                    cursor.attentionCorrelation.reset()
                    continue
                }
                if let context = sessionContext(
                    from: line,
                    expectedSessionID: filenameSessionID
                ) {
                    let timestamp = recordTimestamp(from: line)
                    let isOrdered = timestamp.map { timestamp in
                        cursor.lastRecordTimestamp.map { lastTimestamp in
                            lastTimestamp <= timestamp
                        } ?? true
                    } ?? false
                    let isRecent = timestamp.map {
                        let age = observedAt.timeIntervalSince($0)
                        return age >= 0 && age <= limits.activeSessionInterval
                    } ?? false
                    let canStartSubagent = !batchHasAmbiguousFraming
                        && context.role == .subagent
                        && isOrdered
                        && isRecent
                    let effectiveContext = canStartSubagent
                        ? context
                        : SessionContext(
                            sessionID: context.sessionID,
                            role: .root,
                            parentSessionID: nil
                        )
                    let isNewSession = cursor.sessionID != effectiveContext.sessionID
                    let isNewSubagentIdentity = canStartSubagent
                        && (!cursor.hasAnnouncedSubagent
                            || isNewSession
                            || cursor.role != .subagent
                            || cursor.parentSessionID != effectiveContext.parentSessionID)
                    if isNewSession {
                        cursor.attentionCorrelation.reset()
                    }
                    cursor.sessionID = effectiveContext.sessionID
                    cursor.role = effectiveContext.role
                    cursor.parentSessionID = effectiveContext.parentSessionID
                    if let timestamp, isOrdered {
                        cursor.lastRecordTimestamp = timestamp
                    }
                    if isNewSubagentIdentity {
                        events.append(sessionStartedEvent(
                            for: effectiveContext,
                            observedAt: observedAt
                        ))
                        cursor.hasAnnouncedSubagent = true
                    }
                    continue
                }

                guard let sessionID = cursor.sessionID else { continue }
                if hasInvalidCorrelationID(in: line) {
                    readState.metrics.discardedRecords += 1
                    continue
                }
                if let event = cursor.attentionCorrelation.normalize(
                    line,
                    sessionID: sessionID,
                    role: cursor.role,
                    parentSessionID: cursor.parentSessionID,
                    observedAt: observedAt,
                    maxPendingRequests: limits.maxPendingAttentionRequests
                ) {
                    events.append(event)
                }
            }
            if cursor.offset >= size,
               cursor.remainder.isEmpty,
               !cursor.discardingOversizedRecord {
                cursor.minimumEventTimestamp = nil
            }
            cursors[rolloutURL] = cursor
        }

        return events
    }

    private func recentRolloutURLs(
        observedAt: Date,
        readState: inout PollReadState
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return [] }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        func scan(_ directory: URL, depth: Int) throws {
            guard readState.metrics.scannedEntries < limits.maxScannedEntries,
                  depth <= 6
            else {
                return
            }
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent > $1.lastPathComponent }

            for url in entries {
                guard readState.metrics.scannedEntries < limits.maxScannedEntries else {
                    return
                }
                readState.metrics.scannedEntries += 1
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey]
                )
                if values.isDirectory == true {
                    try scan(url, depth: depth + 1)
                } else if url.pathExtension == "jsonl",
                          url.lastPathComponent.hasPrefix("rollout-"),
                          let modifiedAt = values.contentModificationDate {
                    let age = observedAt.timeIntervalSince(modifiedAt)
                    if age >= 0 && age <= limits.maxCandidateAge {
                        candidates.append((url, modifiedAt))
                    }
                }
            }
        }
        try scan(sessionsURL, depth: 0)

        let urls = candidates
            .sorted {
                if $0.modifiedAt == $1.modifiedAt {
                    return $0.url.path > $1.url.path
                }
                return $0.modifiedAt > $1.modifiedAt
            }
            .prefix(limits.maxCandidateFiles)
            .map(\.url)
        readState.metrics.candidateFiles = urls.count
        return urls
    }

    private func sessionContext(
        in url: URL,
        size: UInt64,
        readState: inout PollReadState
    ) throws -> (
        context: SessionContext?,
        hasIdentityMismatch: Bool,
        timestamp: Date?
    ) {
        let chunkBytes = 8 * 1024
        var prefix = Data()
        while prefix.count < limits.maxSessionMetadataBytes,
              UInt64(prefix.count) < size {
            let fileRemaining = Int(min(
                size - UInt64(prefix.count),
                UInt64(Int.max)
            ))
            let requested = min(
                chunkBytes,
                limits.maxSessionMetadataBytes - prefix.count,
                fileRemaining
            )
            let chunk = try read(
                url,
                offset: UInt64(prefix.count),
                requestedCount: requested,
                readState: &readState
            )
            guard !chunk.isEmpty else { return (nil, false, nil) }
            prefix.append(chunk)
            guard let newline = prefix.firstIndex(of: 0x0A) else { continue }
            let line = Data(prefix[..<newline])
            guard line.count <= limits.maxSessionMetadataBytes else {
                return (nil, false, nil)
            }
            let expectedSessionID = sessionIDFromRolloutFilename(url)
            let hasMismatch = hasMismatchedSessionIdentity(
                in: line,
                expectedSessionID: expectedSessionID
            )
            return (
                hasMismatch ? nil : sessionContext(
                    from: line,
                    expectedSessionID: expectedSessionID
                ),
                hasMismatch,
                recordTimestamp(from: line)
            )
        }
        return (nil, false, nil)
    }

    private func liveAttachmentCursor(
        for url: URL,
        size: UInt64,
        observedAt: Date,
        readState: inout PollReadState
    ) throws -> Cursor {
        let metadata = try sessionContext(
            in: url,
            size: size,
            readState: &readState
        )
        let replayBoundary = (startedAt ?? observedAt).addingTimeInterval(-1.5)
        let isPreexisting = metadata.timestamp.map { $0 < replayBoundary } ?? false
        let tailBudget = min(limits.maxBytesPerFile, limits.maxTotalBytesPerPoll)
        let initialOffset: UInt64
        if isPreexisting, size > UInt64(tailBudget) {
            initialOffset = size - UInt64(tailBudget)
        } else {
            initialOffset = 0
        }
        let sessionID = metadata.hasIdentityMismatch
            ? nil
            : metadata.context?.sessionID ?? sessionIDFromRolloutFilename(url)
        var cursor = Cursor(
            offset: initialOffset,
            sessionID: sessionID,
            role: metadata.context?.role ?? .root,
            parentSessionID: metadata.context?.parentSessionID
        )
        cursor.discardingOversizedRecord = initialOffset > 0
        cursor.isReadingFirstRecord = initialOffset == 0
        cursor.minimumEventTimestamp = isPreexisting ? replayBoundary : nil
        return cursor
    }

    private func sessionContext(
        from data: Data,
        expectedSessionID: String? = nil
    ) -> SessionContext? {
        guard data.count <= limits.maxSessionMetadataBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String,
              isValidOpaqueID(sessionID)
        else {
            return nil
        }
        if let expectedSessionID, sessionID != expectedSessionID {
            return nil
        }
        let parentSessionID = verifiedParentSessionID(in: payload)
        return SessionContext(
            sessionID: sessionID,
            role: parentSessionID == nil ? .root : .subagent,
            parentSessionID: parentSessionID
        )
    }

    private func hasMismatchedSessionIdentity(
        in data: Data,
        expectedSessionID: String?
    ) -> Bool {
        guard let expectedSessionID,
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String,
              isValidOpaqueID(sessionID)
        else {
            return false
        }
        return sessionID != expectedSessionID
    }

    private func verifiedParentSessionID(in payload: [String: Any]) -> String? {
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let threadSpawn = subagent["thread_spawn"] as? [String: Any],
              let parentSessionID = threadSpawn["parent_thread_id"] as? String,
              isValidOpaqueID(parentSessionID)
        else {
            return nil
        }
        return parentSessionID
    }

    private func sessionIDFromRolloutFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("rollout-"), stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        guard UUID(uuidString: candidate) != nil else { return nil }
        return candidate
    }

    private func isValidOpaqueID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func sessionRemovedEvent(
        from cursor: Cursor,
        observedAt: Date
    ) -> AgentEvent {
        AgentEvent(
            kind: .sessionRemoved,
            sessionID: cursor.sessionID ?? "unavailable-session",
            parentSessionID: cursor.parentSessionID,
            timestamp: observedAt,
            role: cursor.role,
            attention: .none
        )
    }

    private func recoverAttention(
        in url: URL,
        size: UInt64,
        context: SessionContext,
        observedAt: Date,
        readState: inout PollReadState
    ) throws -> StartupRecovery? {
        let alreadyRead = readState.fileBytes[url] ?? 0
        let fileRemaining = max(0, limits.maxBytesPerFile - alreadyRead)
        guard fileRemaining > 0 else { return nil }
        let requested = min(Int(min(size, UInt64(Int.max))), fileRemaining)
        let start = size > UInt64(requested) ? size - UInt64(requested) : 0
        let tail = try read(
            url,
            offset: start,
            requestedCount: requested,
            readState: &readState
        )
        guard tail.last == 0x0A || tail.isEmpty else { return nil }
        var lines = tail.split(separator: 0x0A).map { Data($0) }
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        var pendingRequestIDs = Set<String>()
        var requestTimestamps: [String: Date] = [:]
        var lastRelevantTimestamp: Date?

        for line in lines {
            guard line.count <= limits.maxRecordBytes,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let record = object as? [String: Any],
                  let recordType = record["type"] as? String,
                  let payload = record["payload"] as? [String: Any],
                  !hasInvalidCorrelationID(recordType: recordType, payload: payload)
            else {
                readState.metrics.discardedRecords += 1
                return nil
            }
            readState.metrics.recordsParsed += 1

            var nextPendingRequestIDs = pendingRequestIDs
            let event = AgentEventAdapter.normalizeRolloutLine(
                line,
                sessionID: context.sessionID,
                role: .root,
                observedAt: observedAt,
                pendingAttentionRequestIDs: &nextPendingRequestIDs
            )
            guard event != nil || nextPendingRequestIDs != pendingRequestIDs else {
                continue
            }
            guard let timestamp = recordTimestamp(in: record),
                  timestamp <= observedAt,
                  lastRelevantTimestamp.map({ timestamp >= $0 }) ?? true
            else {
                readState.metrics.discardedRecords += 1
                return nil
            }
            lastRelevantTimestamp = timestamp
            pendingRequestIDs = nextPendingRequestIDs

            if event?.kind == .attentionChanged,
               event?.attention == .required,
               recordType == "event_msg",
               let callID = payload["call_id"] as? String {
                requestTimestamps[callID] = timestamp
            } else if event?.kind == .completed || event?.kind == .aborted {
                requestTimestamps.removeAll()
            } else {
                requestTimestamps = requestTimestamps.filter {
                    pendingRequestIDs.contains($0.key)
                }
            }
        }

        let cutoff = observedAt.addingTimeInterval(-limits.startupRecoveryInterval)
        let recentRequestIDs = pendingRequestIDs.filter {
            guard let timestamp = requestTimestamps[$0] else { return false }
            return timestamp >= cutoff && timestamp <= observedAt
        }
        guard !recentRequestIDs.isEmpty else { return nil }
        let lastActivityAt = recentRequestIDs.compactMap {
            requestTimestamps[$0]
        }.max() ?? observedAt
        return StartupRecovery(
            requestIDs: recentRequestIDs,
            lastActivityAt: lastActivityAt
        )
    }

    private func recordTimestamp(from data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any]
        else {
            return nil
        }
        return recordTimestamp(in: record)
    }

    private func recordTimestamp(in record: [String: Any]) -> Date? {
        guard let rawTimestamp = record["timestamp"] as? String else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: rawTimestamp)
            ?? ISO8601DateFormatter().date(from: rawTimestamp)
    }

    private func hasInvalidCorrelationID(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              let recordType = record["type"] as? String,
              let payload = record["payload"] as? [String: Any]
        else {
            return false
        }
        return hasInvalidCorrelationID(recordType: recordType, payload: payload)
    }

    private func isStructurallyValidRecord(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              record["type"] is String,
              record["payload"] is [String: Any]
        else {
            return false
        }
        return true
    }

    private func hasInvalidCorrelationID(
        recordType: String,
        payload: [String: Any]
    ) -> Bool {
        let eventType = payload["type"] as? String
        let requiresCorrelationID = recordType == "response_item"
            && eventType == "function_call_output"
            || recordType == "event_msg"
            && [
                "request_user_input",
                "exec_approval_request",
                "apply_patch_approval_request",
                "request_permissions",
                "exec_command_begin",
                "patch_apply_begin",
                "mcp_tool_call_begin"
            ].contains(eventType)
        guard requiresCorrelationID else { return false }
        guard let callID = payload["call_id"] as? String else { return true }
        return !isValidOpaqueID(callID)
    }

    private func completeLines(
        in chunk: Data,
        remainder: inout Data,
        discardingOversizedRecord: inout Bool,
        isReadingFirstRecord: inout Bool
    ) -> (
        lines: [Data],
        discardedRecords: Int,
        hasPartialRecord: Bool
    ) {
        var discardedRecords = 0
        var lines: [Data] = []
        var start = chunk.startIndex

        while start < chunk.endIndex {
            if discardingOversizedRecord {
                guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                    return (lines, discardedRecords, true)
                }
                discardingOversizedRecord = false
                start = chunk.index(after: newline)
                continue
            }

            let recordLimit = isReadingFirstRecord
                ? limits.maxSessionMetadataBytes
                : limits.maxRecordBytes
            guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                let suffix = chunk[start...]
                if remainder.count + suffix.count > recordLimit {
                    remainder.removeAll(keepingCapacity: false)
                    discardingOversizedRecord = true
                    isReadingFirstRecord = false
                    discardedRecords += 1
                } else {
                    remainder.append(contentsOf: suffix)
                }
                return (
                    lines,
                    discardedRecords,
                    !remainder.isEmpty || discardingOversizedRecord
                )
            }

            let segment = chunk[start..<newline]
            if remainder.count + segment.count > recordLimit {
                remainder.removeAll(keepingCapacity: false)
                discardedRecords += 1
            } else {
                remainder.append(contentsOf: segment)
                if !remainder.isEmpty {
                    lines.append(remainder)
                }
                remainder = Data()
            }
            isReadingFirstRecord = false
            start = chunk.index(after: newline)
        }

        return (
            lines,
            discardedRecords,
            !remainder.isEmpty || discardingOversizedRecord
        )
    }

    private func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func read(
        _ url: URL,
        offset: UInt64,
        requestedCount: Int,
        readState: inout PollReadState
    ) throws -> Data {
        let count = readState.allowedCount(
            requested: requestedCount,
            for: url,
            limits: limits
        )
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        readState.recordRead(data.count, from: url)
        return data
    }

    private func rotated(_ urls: [URL]) -> [URL] {
        guard !urls.isEmpty else { return [] }
        let index = pollRotation % urls.count
        return Array(urls[index...]) + Array(urls[..<index])
    }
}
