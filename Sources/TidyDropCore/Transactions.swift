import Foundation

public enum TransactionStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case completed
    case completedWithErrors = "completed_with_errors"
    case fullyUndone = "fully_undone"
    case partiallyUndone = "partially_undone"
}

public enum MoveExecutionStatus: String, Codable, Sendable {
    case planned
    case completed
    case failed
}

public enum MoveUndoStatus: String, Codable, Sendable {
    case pending
    case undone
    case failed
}

public struct MoveRecord: Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var destination: String
    public var category: String
    public var reason: String
    public var sourceSnapshot: FileSnapshot?
    public var movedAt: Date?
    public var executionStatus: MoveExecutionStatus
    public var executionError: String?
    public var recoveryNote: String?
    public var undoStatus: MoveUndoStatus
    public var undoneAt: Date?
    public var undoError: String?
    public var undoRecoveryNote: String?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case destination
        case category
        case reason
        case sourceSnapshot = "source_snapshot"
        case movedAt = "moved_at"
        case executionStatus = "execution_status"
        case executionError = "execution_error"
        case recoveryNote = "recovery_note"
        case undoStatus = "undo_status"
        case undoneAt = "undone_at"
        case undoError = "undo_error"
        case undoRecoveryNote = "undo_recovery_note"
    }

    public init(
        id: String = UUID().uuidString,
        source: String,
        destination: String,
        category: String,
        reason: String,
        sourceSnapshot: FileSnapshot? = nil,
        movedAt: Date? = nil,
        executionStatus: MoveExecutionStatus = .planned,
        executionError: String? = nil,
        recoveryNote: String? = nil,
        undoStatus: MoveUndoStatus = .pending,
        undoneAt: Date? = nil,
        undoError: String? = nil,
        undoRecoveryNote: String? = nil
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.category = category
        self.reason = reason
        self.sourceSnapshot = sourceSnapshot
        self.movedAt = movedAt
        self.executionStatus = executionStatus
        self.executionError = executionError
        self.recoveryNote = recoveryNote
        self.undoStatus = undoStatus
        self.undoneAt = undoneAt
        self.undoError = undoError
        self.undoRecoveryNote = undoRecoveryNote
    }
}

public struct TransactionManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var runID: String
    public var mode: ExecutionMode
    public var status: TransactionStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var moves: [MoveRecord]
    public var errors: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case runID = "run_id"
        case mode
        case status
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case moves
        case errors
    }

    public init(
        version: Int = 1,
        runID: String,
        mode: ExecutionMode,
        status: TransactionStatus = .inProgress,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        moves: [MoveRecord] = [],
        errors: [String] = []
    ) {
        self.version = version
        self.runID = runID
        self.mode = mode
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.moves = moves
        self.errors = errors
    }
}

public enum TransactionRecoveryOutcome: String, Codable, Sendable {
    case recoveredCompleted = "recovered_completed"
    case recoveredNotMoved = "recovered_not_moved"
    case recoveredConflict = "recovered_conflict"
    case recoveredMissing = "recovered_missing"
    case recoveredUndoCompleted = "recovered_undo_completed"
    case ambiguous
}

public struct TransactionRecoveryEvent: Equatable, Sendable {
    public let runID: String
    public let moveID: String
    public let source: String
    public let destination: String
    public let outcome: TransactionRecoveryOutcome
    public let detail: String

    public init(
        runID: String,
        moveID: String,
        source: String,
        destination: String,
        outcome: TransactionRecoveryOutcome,
        detail: String
    ) {
        self.runID = runID
        self.moveID = moveID
        self.source = source
        self.destination = destination
        self.outcome = outcome
        self.detail = detail
    }
}

public final class TransactionStore {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileSystemSecurity.ensurePrivateDirectory(directory)
    }

    public func url(for runID: String) throws -> URL {
        guard Self.isSafeRunID(runID) else {
            throw StewardError.unsafePath("run_id de transacción inseguro: \(runID)")
        }
        return directory.appendingPathComponent(runID + ".json")
    }

    public func save(_ manifest: TransactionManifest) throws {
        guard manifest.version == 1 else {
            throw StewardError.commandFailed("Versión de manifiesto no soportada: \(manifest.version)")
        }
        guard manifest.mode == .apply else {
            throw StewardError.commandFailed("Solo se persisten transacciones apply")
        }
        try JSONFile.save(manifest, to: try url(for: manifest.runID))
    }

    public func load(runID: String) throws -> TransactionManifest {
        let manifestURL = try url(for: runID)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw StewardError.configurationNotFound(manifestURL.path)
        }
        return try decodeManifest(at: manifestURL)
    }

    /// Reconciles a process interruption after a move was journaled but before
    /// its completion status was persisted. No file is moved by this method.
    public func reconcileInterruptedTransactions(
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> [TransactionRecoveryEvent] {
        let files = try manifestFiles(fileManager: fileManager)
        var events: [TransactionRecoveryEvent] = []

        for file in files {
            var manifest = try decodeManifest(at: file)

            var changed = false
            for index in manifest.moves.indices where manifest.moves[index].executionStatus == .planned {
                let move = manifest.moves[index]
                let sourceURL = URL(fileURLWithPath: move.source)
                let destinationURL = URL(fileURLWithPath: move.destination)
                let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
                let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

                if sourceExists && !destinationExists {
                    let detail = "source_present_destination_absent"
                    manifest.moves[index].executionStatus = .failed
                    manifest.moves[index].executionError = "recovery:\(detail)"
                    manifest.moves[index].recoveryNote = detail
                    manifest.errors.append("\(move.source): interrupted operation did not move the file")
                    changed = true
                    events.append(TransactionRecoveryEvent(
                        runID: manifest.runID,
                        moveID: move.id,
                        source: move.source,
                        destination: move.destination,
                        outcome: .recoveredNotMoved,
                        detail: detail
                    ))
                    continue
                }

                if sourceExists && destinationExists {
                    let detail = "source_and_destination_both_exist"
                    manifest.moves[index].executionStatus = .failed
                    manifest.moves[index].executionError = "recovery:\(detail)"
                    manifest.moves[index].recoveryNote = detail
                    manifest.errors.append("\(move.source): interrupted operation is conflicted; both paths exist")
                    changed = true
                    events.append(TransactionRecoveryEvent(
                        runID: manifest.runID,
                        moveID: move.id,
                        source: move.source,
                        destination: move.destination,
                        outcome: .recoveredConflict,
                        detail: detail
                    ))
                    continue
                }

                if !sourceExists && !destinationExists {
                    let detail = "source_and_destination_both_missing"
                    manifest.moves[index].executionStatus = .failed
                    manifest.moves[index].executionError = "recovery:\(detail)"
                    manifest.moves[index].recoveryNote = detail
                    manifest.errors.append("\(move.source): interrupted operation cannot be recovered; both paths are missing")
                    changed = true
                    events.append(TransactionRecoveryEvent(
                        runID: manifest.runID,
                        moveID: move.id,
                        source: move.source,
                        destination: move.destination,
                        outcome: .recoveredMissing,
                        detail: detail
                    ))
                    continue
                }

                do {
                    let destinationSnapshot = try FileSystemSecurity.snapshot(of: destinationURL)
                    if let sourceSnapshot = move.sourceSnapshot,
                       sourceSnapshot.matchesJournaledSnapshot(destinationSnapshot) {
                        let detail = "source_absent_destination_matches_journal"
                        manifest.moves[index].executionStatus = .completed
                        manifest.moves[index].movedAt = manifest.moves[index].movedAt ?? now
                        manifest.moves[index].executionError = nil
                        manifest.moves[index].recoveryNote = detail
                        changed = true
                        events.append(TransactionRecoveryEvent(
                            runID: manifest.runID,
                            moveID: move.id,
                            source: move.source,
                            destination: move.destination,
                            outcome: .recoveredCompleted,
                            detail: detail
                        ))
                    } else {
                        let detail = move.sourceSnapshot == nil
                            ? "source_absent_destination_present_without_source_snapshot"
                            : "source_absent_destination_snapshot_mismatch"
                        if manifest.moves[index].recoveryNote != detail {
                            manifest.moves[index].recoveryNote = detail
                            changed = true
                        }
                        events.append(TransactionRecoveryEvent(
                            runID: manifest.runID,
                            moveID: move.id,
                            source: move.source,
                            destination: move.destination,
                            outcome: .ambiguous,
                            detail: detail
                        ))
                    }
                } catch {
                    let detail = "destination_present_but_not_a_readable_regular_file: \(error)"
                    if manifest.moves[index].recoveryNote != detail {
                        manifest.moves[index].recoveryNote = detail
                        changed = true
                    }
                    events.append(TransactionRecoveryEvent(
                        runID: manifest.runID,
                        moveID: move.id,
                        source: move.source,
                        destination: move.destination,
                        outcome: .ambiguous,
                        detail: detail
                    ))
                }
            }

            // Reconcile an interruption after undo moved the file back but before
            // undo_status=undone was persisted. This method never moves a file.
            for index in manifest.moves.indices
            where manifest.moves[index].executionStatus == .completed
                && manifest.moves[index].undoStatus != .undone {
                let move = manifest.moves[index]
                let sourceURL = URL(fileURLWithPath: move.source)
                let destinationURL = URL(fileURLWithPath: move.destination)
                let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
                let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

                guard sourceExists && !destinationExists else { continue }

                do {
                    let sourceSnapshot = try FileSystemSecurity.snapshot(of: sourceURL)
                    if let journaledSnapshot = move.sourceSnapshot,
                       journaledSnapshot.matchesJournaledSnapshot(sourceSnapshot) {
                        let detail = "source_restored_destination_absent_matches_journal"
                        manifest.moves[index].undoStatus = .undone
                        manifest.moves[index].undoneAt = manifest.moves[index].undoneAt ?? now
                        manifest.moves[index].undoError = nil
                        manifest.moves[index].undoRecoveryNote = detail
                        changed = true
                        events.append(TransactionRecoveryEvent(
                            runID: manifest.runID,
                            moveID: move.id,
                            source: move.source,
                            destination: move.destination,
                            outcome: .recoveredUndoCompleted,
                            detail: detail
                        ))
                    }
                } catch {
                    // No inference is made when the restored path is not a readable regular file.
                    continue
                }
            }

            let hasPlannedExecution = manifest.moves.contains { $0.executionStatus == .planned }
            let completedMoves = manifest.moves.filter { $0.executionStatus == .completed }
            let hasUndoneMoves = completedMoves.contains { $0.undoStatus == .undone }
            let hasUndoFailures = completedMoves.contains { $0.undoStatus == .failed }
            let hasRemainingUndo = completedMoves.contains { $0.undoStatus != .undone }
            let hasExecutionFailures = !manifest.errors.isEmpty
                || manifest.moves.contains { $0.executionStatus == .failed }

            let derivedStatus: TransactionStatus
            if hasPlannedExecution {
                derivedStatus = .inProgress
            } else if hasUndoneMoves && !hasRemainingUndo && !hasUndoFailures {
                derivedStatus = .fullyUndone
            } else if hasUndoneMoves || hasUndoFailures {
                derivedStatus = .partiallyUndone
            } else {
                derivedStatus = hasExecutionFailures ? .completedWithErrors : .completed
            }

            if manifest.status != derivedStatus {
                manifest.status = derivedStatus
                changed = true
            }
            if derivedStatus != .inProgress, manifest.finishedAt == nil {
                manifest.finishedAt = now
                changed = true
            }
            if changed {
                try save(manifest)
            }
        }

        return events
    }

    public func latestUndoable(fileManager: FileManager = .default) throws -> TransactionManifest {
        let files = try manifestFiles(fileManager: fileManager)
        var manifests: [TransactionManifest] = []
        for file in files {
            let manifest = try decodeManifest(at: file)
            guard manifest.moves.contains(where: {
                $0.executionStatus == .completed && $0.undoStatus != .undone
            }),
            manifest.status != .fullyUndone else {
                continue
            }
            manifests.append(manifest)
        }
        guard let latest = manifests.max(by: { $0.startedAt < $1.startedAt }) else {
            throw StewardError.noUndoableTransaction
        }
        return latest
    }

    /// Limits completed transaction history while preserving every in-progress
    /// manifest and the newest transaction that can still be undone.
    @discardableResult
    public func pruneTerminalManifests(
        retaining maximumTerminalCount: Int,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard maximumTerminalCount >= 1 else {
            throw StewardError.invalidConfiguration("transaction_manifest_limit debe ser >= 1")
        }

        let files = try manifestFiles(fileManager: fileManager)
        var entries: [(url: URL, manifest: TransactionManifest)] = []
        entries.reserveCapacity(files.count)
        for file in files {
            entries.append((file, try decodeManifest(at: file)))
        }

        let terminal = entries
            .filter { $0.manifest.status != .inProgress }
            .sorted { $0.manifest.startedAt > $1.manifest.startedAt }

        var protectedRunIDs = Set(terminal.prefix(maximumTerminalCount).map { $0.manifest.runID })
        if let latestUndoable = terminal.first(where: { entry in
            entry.manifest.status != .fullyUndone
                && entry.manifest.moves.contains {
                    $0.executionStatus == .completed && $0.undoStatus != .undone
                }
        }) {
            protectedRunIDs.insert(latestUndoable.manifest.runID)
        }

        var removed = 0
        for entry in terminal where !protectedRunIDs.contains(entry.manifest.runID) {
            _ = try FileSystemSecurity.regularFileSize(entry.url)
            // APP_OWNED_RETENTION: elimina únicamente manifiestos terminales antiguos.
            try fileManager.removeItem(at: entry.url)
            removed += 1
        }
        return removed
    }

    private func decodeManifest(at file: URL) throws -> TransactionManifest {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw StewardError.commandFailed(
                "No se pudo leer el manifiesto de transacción \(file.path): \(error)"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: TransactionManifest
        do {
            manifest = try decoder.decode(TransactionManifest.self, from: data)
        } catch {
            throw StewardError.commandFailed(
                "Manifiesto de transacción JSON ilegible: \(file.path): \(error)"
            )
        }

        guard manifest.version == 1 else {
            throw StewardError.commandFailed(
                "Versión de manifiesto no soportada en \(file.path): \(manifest.version)"
            )
        }
        guard manifest.mode == .apply else {
            throw StewardError.commandFailed(
                "Modo de manifiesto no válido en \(file.path): \(manifest.mode.rawValue)"
            )
        }
        guard Self.isSafeRunID(manifest.runID) else {
            throw StewardError.unsafePath("run_id inseguro dentro de \(file.path): \(manifest.runID)")
        }
        guard file.deletingPathExtension().lastPathComponent == manifest.runID else {
            throw StewardError.commandFailed(
                "El nombre del manifiesto no coincide con run_id: \(file.lastPathComponent) != \(manifest.runID).json"
            )
        }
        return manifest
    }

    private func manifestFiles(fileManager: FileManager) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { file in
            guard file.pathExtension.lowercased() == "json",
                  let values = try? file.resourceValues(forKeys: keys) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private static func isSafeRunID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 160,
              value != ".",
              value != "..",
              !value.contains("..") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

}

public enum RunIdentifier {
    public static func make(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(formatter.string(from: now))-\(suffix)"
    }
}
