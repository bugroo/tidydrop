import Foundation

private struct MoveCandidate {
    let url: URL
    let probeStartSnapshot: FileSnapshot
    let decision: ClassificationDecision
}

public final class StewardEngine {
    private let resolved: ResolvedConfiguration
    private let classifier: FileClassifier
    private let exclusions: ExclusionEvaluator
    private let nowProvider: () -> Date
    private let sleepProvider: (TimeInterval) -> Void
    private let fileManager: FileManager
    private let moveOperation: (URL, URL, FileSnapshot) throws -> Void

    public init(
        configuration: ResolvedConfiguration,
        mimeDetector: MIMETypeDetecting = SystemMIMETypeDetector(),
        nowProvider: @escaping () -> Date = Date.init,
        sleepProvider: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        fileManager: FileManager = .default,
        moveOperation: @escaping (URL, URL, FileSnapshot) throws -> Void = {
            try FileSystemSecurity.moveRegularFileExclusively(
                from: $0,
                to: $1,
                expectedSnapshot: $2
            )
        }
    ) throws {
        self.resolved = configuration
        self.classifier = try FileClassifier(config: configuration.config.classification, detector: mimeDetector)
        self.exclusions = try ExclusionEvaluator(config: configuration.config.exclusions)
        self.nowProvider = nowProvider
        self.sleepProvider = sleepProvider
        self.fileManager = fileManager
        self.moveOperation = moveOperation
    }

    public func run(
        mode: ExecutionMode,
        recordEmptyRun: Bool = true,
        suppressUnchangedDryRunPlans: Bool = false
    ) throws -> RunSummary {
        try preflightSource()
        try FileSystemSecurity.ensurePrivateDirectory(resolved.paths.stateDirectory)
        try FileSystemSecurity.ensurePrivateDirectory(resolved.paths.logDirectory)
        let lock = try ProcessFileLock(url: resolved.paths.lockFile)
        _ = lock

        let runID = RunIdentifier.make(now: nowProvider())
        var summary = RunSummary(runID: runID, mode: mode)
        let logger = try AuditLogger(
            humanLogURL: resolved.paths.humanLogFile,
            auditLogURL: resolved.paths.auditLogFile,
            maxFileBytes: resolved.config.logging.maxFileBytes,
            rotatedFileCount: resolved.config.logging.rotatedFileCount
        )
        let stability = try StabilityStore(url: resolved.paths.stabilityStateFile)
        let dryRunCache: ScheduledDryRunCache?
        if mode == .dryRun, suppressUnchangedDryRunPlans {
            dryRunCache = try ScheduledDryRunCache(
                url: resolved.paths.scheduledDryRunCacheFile,
                planSignature: try scheduledDryRunPlanSignature()
            )
        } else {
            dryRunCache = nil
        }
        var retainedDryRunCachePaths = Set<String>()
        let transactionStore = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let start = nowProvider()
        var didRecordRunStart = false

        func recordRunStartIfNeeded() throws {
            guard !didRecordRunStart else { return }
            try logger.record(AuditEvent(
                timestamp: start,
                runID: runID,
                level: "info",
                mode: mode.rawValue,
                action: "run_started",
                detail: "source=\(resolved.paths.sourceDirectory.path)"
            ))
            didRecordRunStart = true
        }

        func recordRunEvent(_ event: AuditEvent) throws {
            try recordRunStartIfNeeded()
            try logger.record(event)
        }

        if recordEmptyRun {
            try recordRunStartIfNeeded()
        }

        let recoveryEvents = try transactionStore.reconcileInterruptedTransactions(
            fileManager: fileManager,
            now: nowProvider()
        )
        let ambiguousRecoveryCount = recoveryEvents.filter { $0.outcome == .ambiguous }.count
        if !recoveryEvents.isEmpty {
            try recordRunStartIfNeeded()
        }
        try recordRecoveryEvents(recoveryEvents, logger: logger, operationRunID: runID, mode: mode.rawValue)
        if ambiguousRecoveryCount > 0 {
            summary.errors += ambiguousRecoveryCount
            if mode == .apply {
                try recordRunEvent(AuditEvent(
                    runID: runID,
                    level: "error",
                    mode: mode.rawValue,
                    action: "run_aborted",
                    reason: "ambiguous_interrupted_transaction",
                    detail: "count=\(ambiguousRecoveryCount); revisa state/transactions antes de aplicar nuevos movimientos"
                ))
                throw StewardError.commandFailed(
                    "Hay \(ambiguousRecoveryCount) movimiento(s) interrumpido(s) ambiguo(s). " +
                    "No se aplicaron movimientos nuevos; revisa los manifiestos de transacciones."
                )
            }
        }

        _ = try transactionStore.pruneTerminalManifests(
            retaining: resolved.config.logging.transactionManifestLimit,
            fileManager: fileManager
        )

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]

        let items = try fileManager.contentsOfDirectory(
            at: resolved.paths.sourceDirectory,
            includingPropertiesForKeys: keys,
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var candidates: [MoveCandidate] = []
        let maximum = resolved.config.safety.maxFilesPerRun
        for item in items {
            if summary.scanned >= maximum {
                summary.errors += 1
                try recordRunEvent(AuditEvent(
                    runID: runID,
                    level: "error",
                    mode: mode.rawValue,
                    action: "scan_limit_reached",
                    detail: "max_files_per_run=\(maximum)"
                ))
                break
            }
            summary.scanned += 1

            do {
                let facts = try FileSystemSecurity.itemFacts(for: item)
                if let reason = exclusions.exclusionReason(url: item, facts: facts) {
                    summary.skipped += 1
                    if resolved.config.logging.logSkippedFiles {
                        try recordRunEvent(AuditEvent(
                            runID: runID,
                            level: "info",
                            mode: mode.rawValue,
                            action: "skipped",
                            source: item.path,
                            reason: reason
                        ))
                    }
                    continue
                }

                guard let snapshot = facts.snapshot else {
                    summary.skipped += 1
                    continue
                }

                // A cached entry can only come from an earlier, fully stable dry-run
                // under the same configuration signature. Consult it before touching
                // stability.json so an unchanged scheduled pass performs no needless
                // probe, classification, log, or state write. Apply mode never creates
                // or reads this cache.
                if let dryRunCache,
                   dryRunCache.contains(path: item.path, snapshot: snapshot) {
                    summary.planned += 1
                    retainedDryRunCachePaths.insert(item.path)
                    continue
                }

                let observedAt = nowProvider()
                let evaluation = stability.observe(
                    path: item.path,
                    snapshot: snapshot,
                    now: observedAt,
                    minimumObservations: resolved.config.stability.minimumStableObservations,
                    minimumAgeSeconds: resolved.config.stability.minimumAgeSeconds
                )
                if !evaluation.isStable {
                    summary.deferred += 1
                    try recordRunEvent(AuditEvent(
                        timestamp: observedAt,
                        runID: runID,
                        level: "info",
                        mode: mode.rawValue,
                        action: "deferred",
                        source: item.path,
                        reason: evaluation.reason,
                        detail: "observations=\(evaluation.observations) age_seconds=\(String(format: "%.3f", evaluation.ageSeconds))"
                    ))
                    continue
                }

                let probeStartSnapshot = try FileSystemSecurity.freshSnapshot(of: item)
                guard probeStartSnapshot == snapshot else {
                    summary.deferred += 1
                    _ = stability.observe(
                        path: item.path,
                        snapshot: probeStartSnapshot,
                        now: nowProvider(),
                        minimumObservations: resolved.config.stability.minimumStableObservations,
                        minimumAgeSeconds: resolved.config.stability.minimumAgeSeconds
                    )
                    try recordRunEvent(AuditEvent(
                        runID: runID,
                        level: "info",
                        mode: mode.rawValue,
                        action: "deferred",
                        source: item.path,
                        reason: "changed_before_probe"
                    ))
                    continue
                }

                candidates.append(
                    MoveCandidate(
                        url: item,
                        probeStartSnapshot: probeStartSnapshot,
                        decision: classifier.classify(item)
                    )
                )
            } catch {
                summary.errors += 1
                try recordRunEvent(AuditEvent(
                    runID: runID,
                    level: "error",
                    mode: mode.rawValue,
                    action: "item_error",
                    source: item.path,
                    detail: String(describing: error)
                ))
            }
        }

        stability.prune(now: nowProvider(), retentionSeconds: resolved.config.stability.stateRetentionSeconds)
        try stability.save()

        if !candidates.isEmpty, resolved.config.stability.probeDelayMilliseconds > 0 {
            sleepProvider(Double(resolved.config.stability.probeDelayMilliseconds) / 1_000.0)
        }

        var transaction: TransactionManifest?
        if mode == .apply, !candidates.isEmpty {
            let manifest = TransactionManifest(runID: runID, mode: .apply, startedAt: start)
            try transactionStore.save(manifest)
            transaction = manifest
        }

        for candidate in candidates {
            do {
                let currentSnapshot = try FileSystemSecurity.freshSnapshot(of: candidate.url)
                guard currentSnapshot == candidate.probeStartSnapshot else {
                    summary.deferred += 1
                    _ = stability.observe(
                        path: candidate.url.path,
                        snapshot: currentSnapshot,
                        now: nowProvider(),
                        minimumObservations: resolved.config.stability.minimumStableObservations,
                        minimumAgeSeconds: resolved.config.stability.minimumAgeSeconds
                    )
                    try recordRunEvent(AuditEvent(
                        runID: runID,
                        level: "info",
                        mode: mode.rawValue,
                        action: "deferred",
                        source: candidate.url.path,
                        category: candidate.decision.category,
                        reason: "changed_during_probe"
                    ))
                    continue
                }

                let categoryDirectory = resolved.paths.destinationRoot
                    .appendingPathComponent(candidate.decision.category, isDirectory: true)
                try assertDestination(categoryDirectory)
                if mode == .apply {
                    try ensureDestinationDirectory(categoryDirectory)
                    try assertDestination(categoryDirectory)
                }
                let destination = try collisionSafeDestination(
                    for: candidate.url,
                    in: categoryDirectory,
                    matchedExtension: candidate.decision.matchedExtension
                )

                summary.planned += 1
                try recordRunEvent(AuditEvent(
                    runID: runID,
                    level: "info",
                    mode: mode.rawValue,
                    action: mode == .dryRun ? "would_move" : "move_planned",
                    source: candidate.url.path,
                    destination: destination.path,
                    category: candidate.decision.category,
                    reason: candidate.decision.reason
                ))

                guard mode == .apply else {
                    dryRunCache?.remember(
                        path: candidate.url.path,
                        snapshot: currentSnapshot
                    )
                    retainedDryRunCachePaths.insert(candidate.url.path)
                    continue
                }
                guard var manifest = transaction else {
                    throw StewardError.commandFailed("Falta el manifiesto transaccional")
                }

                let finalSnapshot = try FileSystemSecurity.freshSnapshot(of: candidate.url)
                guard finalSnapshot == currentSnapshot else {
                    summary.deferred += 1
                    try recordRunEvent(AuditEvent(
                        runID: runID,
                        level: "info",
                        mode: mode.rawValue,
                        action: "deferred",
                        source: candidate.url.path,
                        destination: destination.path,
                        category: candidate.decision.category,
                        reason: "changed_before_move"
                    ))
                    continue
                }

                try assertSameFilesystem(
                    file: candidate.url,
                    directory: categoryDirectory,
                    operation: "move"
                )

                let moveRecord = MoveRecord(
                    source: candidate.url.path,
                    destination: destination.path,
                    category: candidate.decision.category,
                    reason: candidate.decision.reason,
                    sourceSnapshot: finalSnapshot
                )
                manifest.moves.append(moveRecord)
                transaction = manifest
                try transactionStore.save(manifest)

                let immediatelyBeforeRename = try FileSystemSecurity.freshSnapshot(of: candidate.url)
                guard immediatelyBeforeRename == finalSnapshot else {
                    if let index = manifest.moves.firstIndex(where: { $0.id == moveRecord.id }) {
                        manifest.moves[index].executionStatus = .failed
                        manifest.moves[index].executionError = "changed_before_move"
                    }
                    transaction = manifest
                    try transactionStore.save(manifest)
                    summary.deferred += 1
                    try recordRunEvent(AuditEvent(
                        runID: runID,
                        level: "info",
                        mode: mode.rawValue,
                        action: "deferred",
                        source: candidate.url.path,
                        destination: destination.path,
                        category: candidate.decision.category,
                        reason: "changed_before_move"
                    ))
                    continue
                }

                do {
                    try moveOperation(candidate.url, destination, immediatelyBeforeRename)
                } catch StewardError.commandFailed(let detail) where detail == "changed_before_move" {
                    if let index = manifest.moves.firstIndex(where: { $0.id == moveRecord.id }) {
                        manifest.moves[index].executionStatus = .failed
                        manifest.moves[index].executionError = detail
                    }
                    transaction = manifest
                    try transactionStore.save(manifest)
                    summary.deferred += 1
                    try recordRunEvent(AuditEvent(
                        runID: runID,
                        level: "info",
                        mode: mode.rawValue,
                        action: "deferred",
                        source: candidate.url.path,
                        destination: destination.path,
                        category: candidate.decision.category,
                        reason: detail
                    ))
                    continue
                } catch {
                    // The move primitive may report an error after the filesystem has
                    // already renamed the item. Keep the journal entry planned;
                    // the next reconciliation determines the physical outcome.
                    if let index = manifest.moves.firstIndex(where: { $0.id == moveRecord.id }) {
                        manifest.moves[index].executionError =
                            "move_call_error_pending_reconciliation: \(error)"
                    }
                    transaction = manifest
                    try? transactionStore.save(manifest)
                    throw error
                }

                guard let index = manifest.moves.firstIndex(where: { $0.id == moveRecord.id }) else {
                    throw StewardError.commandFailed("No se encontró el movimiento recién registrado")
                }
                manifest.moves[index].executionStatus = .completed
                manifest.moves[index].movedAt = nowProvider()
                manifest.moves[index].executionError = nil
                transaction = manifest
                summary.moved += 1
                try transactionStore.save(manifest)

                stability.remove(path: candidate.url.path)
                try recordRunEvent(AuditEvent(
                    runID: runID,
                    level: "info",
                    mode: mode.rawValue,
                    action: "moved",
                    source: candidate.url.path,
                    destination: destination.path,
                    category: candidate.decision.category,
                    reason: candidate.decision.reason
                ))
            } catch {
                summary.errors += 1
                if mode == .apply, var manifest = transaction {
                    manifest.errors.append("\(candidate.url.path): \(error)")
                    transaction = manifest
                    try? transactionStore.save(manifest)
                }
                try recordRunEvent(AuditEvent(
                    runID: runID,
                    level: "error",
                    mode: mode.rawValue,
                    action: "move_error",
                    source: candidate.url.path,
                    category: candidate.decision.category,
                    detail: String(describing: error)
                ))
            }
        }

        try stability.save()
        dryRunCache?.retain(paths: retainedDryRunCachePaths)
        try dryRunCache?.save()

        if var manifest = transaction {
            if manifest.moves.contains(where: { $0.executionStatus == .planned }) {
                // At least one move has an uncertain physical outcome. Preserve
                // in_progress so the next run must reconcile it before applying.
                manifest.status = .inProgress
                manifest.finishedAt = nil
            } else {
                manifest.finishedAt = nowProvider()
                manifest.status = manifest.errors.isEmpty && summary.errors == 0
                    ? .completed
                    : .completedWithErrors
            }
            try transactionStore.save(manifest)
        }

        _ = try transactionStore.pruneTerminalManifests(
            retaining: resolved.config.logging.transactionManifestLimit,
            fileManager: fileManager
        )

        if didRecordRunStart || logger.recordCount > 0 || summary.errors > 0 {
            try recordRunEvent(AuditEvent(
                runID: runID,
                level: summary.errors == 0 ? "info" : "error",
                mode: mode.rawValue,
                action: "run_finished",
                detail: "scanned=\(summary.scanned) planned=\(summary.planned) moved=\(summary.moved) deferred=\(summary.deferred) skipped=\(summary.skipped) errors=\(summary.errors)"
            ))
        }
        return summary
    }

    public func undoLatest(mode: UndoMode) throws -> UndoSummary {
        try FileSystemSecurity.ensurePrivateDirectory(resolved.paths.stateDirectory)
        try FileSystemSecurity.ensurePrivateDirectory(resolved.paths.logDirectory)
        let lock = try ProcessFileLock(url: resolved.paths.lockFile)
        _ = lock

        let transactionStore = try TransactionStore(directory: resolved.paths.transactionsDirectory)
        let logger = try AuditLogger(
            humanLogURL: resolved.paths.humanLogFile,
            auditLogURL: resolved.paths.auditLogFile,
            maxFileBytes: resolved.config.logging.maxFileBytes,
            rotatedFileCount: resolved.config.logging.rotatedFileCount
        )
        let undoRunID = "undo-\(RunIdentifier.make(now: nowProvider()))"
        let recoveryEvents = try transactionStore.reconcileInterruptedTransactions(
            fileManager: fileManager,
            now: nowProvider()
        )
        try recordRecoveryEvents(
            recoveryEvents,
            logger: logger,
            operationRunID: undoRunID,
            mode: "undo-\(mode.rawValue)"
        )
        let ambiguousRecoveryCount = recoveryEvents.filter { $0.outcome == .ambiguous }.count
        if ambiguousRecoveryCount > 0 {
            throw StewardError.commandFailed(
                "Hay \(ambiguousRecoveryCount) movimiento(s) interrumpido(s) ambiguo(s). " +
                "Undo se detuvo sin mover archivos; revisa los manifiestos de transacciones."
            )
        }

        var manifest = try transactionStore.latestUndoable(fileManager: fileManager)
        var summary = UndoSummary(transactionID: manifest.runID, mode: mode)

        try logger.record(AuditEvent(
            runID: undoRunID,
            level: "info",
            mode: "undo-\(mode.rawValue)",
            action: "undo_started",
            detail: "transaction=\(manifest.runID)"
        ))

        for index in manifest.moves.indices.reversed() {
            if manifest.moves[index].undoStatus == .undone || manifest.moves[index].executionStatus != .completed {
                continue
            }

            let move = manifest.moves[index]
            let source = URL(fileURLWithPath: move.source)
            let destination = URL(fileURLWithPath: move.destination)
            do {
                try assertUndoPaths(source: source, destination: destination)
                let sourceExists = fileManager.fileExists(atPath: source.path)
                let destinationExists = fileManager.fileExists(atPath: destination.path)

                if sourceExists || !destinationExists {
                    let detail: String
                    if sourceExists && destinationExists {
                        detail = "source_and_destination_both_exist"
                    } else if sourceExists {
                        detail = "source_already_exists"
                    } else {
                        detail = "destination_missing"
                    }
                    summary.skipped += 1
                    if mode == .apply {
                        manifest.moves[index].undoStatus = .failed
                        manifest.moves[index].undoError = detail
                        manifest.status = .partiallyUndone
                        try transactionStore.save(manifest)
                    }
                    try logger.record(AuditEvent(
                        runID: undoRunID,
                        level: "error",
                        mode: "undo-\(mode.rawValue)",
                        action: "undo_skipped",
                        source: destination.path,
                        destination: source.path,
                        category: move.category,
                        reason: detail
                    ))
                    continue
                }

                let destinationSnapshot = try FileSystemSecurity.snapshot(of: destination)
                guard let journaledSnapshot = move.sourceSnapshot,
                      journaledSnapshot.matchesJournaledSnapshot(destinationSnapshot) else {
                    let detail = move.sourceSnapshot == nil
                        ? "undo_missing_source_snapshot"
                        : "undo_destination_identity_mismatch"
                    summary.skipped += 1
                    if mode == .apply {
                        manifest.moves[index].undoStatus = .failed
                        manifest.moves[index].undoError = detail
                        manifest.status = .partiallyUndone
                        try transactionStore.save(manifest)
                    }
                    try logger.record(AuditEvent(
                        runID: undoRunID,
                        level: "error",
                        mode: "undo-\(mode.rawValue)",
                        action: "undo_skipped",
                        source: destination.path,
                        destination: source.path,
                        category: move.category,
                        reason: detail
                    ))
                    continue
                }
                try assertSameFilesystem(
                    file: destination,
                    directory: source.deletingLastPathComponent(),
                    operation: "undo"
                )
                summary.planned += 1
                try logger.record(AuditEvent(
                    runID: undoRunID,
                    level: "info",
                    mode: "undo-\(mode.rawValue)",
                    action: mode == .preview ? "would_restore" : "restore_planned",
                    source: destination.path,
                    destination: source.path,
                    category: move.category,
                    reason: "undo_transaction:\(manifest.runID)"
                ))

                guard mode == .apply else { continue }
                do {
                    try moveOperation(destination, source, destinationSnapshot)
                } catch {
                    // As with apply, keep the state pending until path and
                    // identity reconciliation can determine whether rename ran.
                    manifest.moves[index].undoError =
                        "undo_move_call_error_pending_reconciliation: \(error)"
                    manifest.status = .partiallyUndone
                    try? transactionStore.save(manifest)
                    throw error
                }
                manifest.moves[index].executionStatus = .completed
                manifest.moves[index].undoStatus = .undone
                manifest.moves[index].undoneAt = nowProvider()
                manifest.moves[index].undoError = nil
                summary.restored += 1
                try transactionStore.save(manifest)
                try logger.record(AuditEvent(
                    runID: undoRunID,
                    level: "info",
                    mode: "undo-apply",
                    action: "restored",
                    source: destination.path,
                    destination: source.path,
                    category: move.category,
                    reason: "undo_transaction:\(manifest.runID)"
                ))
            } catch {
                summary.errors += 1
                try logger.record(AuditEvent(
                    runID: undoRunID,
                    level: "error",
                    mode: "undo-\(mode.rawValue)",
                    action: "undo_error",
                    source: destination.path,
                    destination: source.path,
                    category: move.category,
                    detail: String(describing: error)
                ))
            }
        }

        if mode == .apply {
            let remaining = manifest.moves.contains {
                $0.executionStatus == .completed && $0.undoStatus != .undone
            }
            manifest.status = remaining || summary.errors > 0 || summary.skipped > 0 ? .partiallyUndone : .fullyUndone
            manifest.finishedAt = nowProvider()
            try transactionStore.save(manifest)
        }

        try logger.record(AuditEvent(
            runID: undoRunID,
            level: summary.errors == 0 ? "info" : "error",
            mode: "undo-\(mode.rawValue)",
            action: "undo_finished",
            detail: "transaction=\(manifest.runID) planned=\(summary.planned) restored=\(summary.restored) skipped=\(summary.skipped) errors=\(summary.errors)"
        ))
        _ = try transactionStore.pruneTerminalManifests(
            retaining: resolved.config.logging.transactionManifestLimit,
            fileManager: fileManager
        )
        return summary
    }

    private func recordRecoveryEvents(
        _ events: [TransactionRecoveryEvent],
        logger: AuditLogger,
        operationRunID: String,
        mode: String
    ) throws {
        for event in events {
            try logger.record(AuditEvent(
                runID: operationRunID,
                level: event.outcome == .ambiguous ? "error" : "warning",
                mode: mode,
                action: "transaction_recovery",
                source: event.source,
                destination: event.destination,
                reason: event.outcome.rawValue,
                detail: "transaction=\(event.runID) move=\(event.moveID) \(event.detail)"
            ))
        }
    }

    private func preflightSource() throws {
        let validation: ActiveFolderValidation
        do {
            validation = try ActiveFolderManager.validate(path: resolved.paths.sourceDirectory.path)
        } catch {
            throw StewardError.sourceUnavailable("\(resolved.paths.sourceDirectory.path): \(error)")
        }
        guard validation.readable else {
            throw StewardError.sourceUnavailable("source_directory no es legible: \(resolved.paths.sourceDirectory.path)")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: resolved.paths.destinationRoot.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StewardError.unsafePath(
                    "destination_root existe pero no es un directorio: \(resolved.paths.destinationRoot.path)"
                )
            }
            let sourceIdentity = try FileSystemSecurity.posixIdentity(of: resolved.paths.sourceDirectory)
            let destinationIdentity = try FileSystemSecurity.posixIdentity(of: resolved.paths.destinationRoot)
            guard sourceIdentity.deviceID == destinationIdentity.deviceID else {
                throw StewardError.unsafePath(
                    "destination_root debe estar en el mismo sistema de archivos que source_directory"
                )
            }
        }
    }

    private func ensureDestinationDirectory(_ url: URL) throws {
        do {
            let metadata = try FileSystemSecurity.freshPOSIXMetadata(of: url)
            guard metadata.kind == .directory else {
                throw StewardError.unsafePath("el destino existe y no es un directorio: \(url.path)")
            }
            return
        } catch StewardError.sourceUnavailable {
            // La categoría aún no existe; se crea dentro del destino ya validado.
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func assertDestination(_ categoryDirectory: URL) throws {
        guard ConfigurationIO.isSameOrDescendant(categoryDirectory, of: resolved.paths.destinationRoot),
              categoryDirectory.deletingLastPathComponent().standardizedFileURL == resolved.paths.destinationRoot.standardizedFileURL else {
            throw StewardError.unsafePath("categoría fuera de destination_root: \(categoryDirectory.path)")
        }
    }

    private func assertUndoPaths(source: URL, destination: URL) throws {
        guard source.deletingLastPathComponent().standardizedFileURL == resolved.paths.sourceDirectory.standardizedFileURL else {
            throw StewardError.unsafePath("origen de undo fuera de source_directory: \(source.path)")
        }
        guard ConfigurationIO.isSameOrDescendant(destination, of: resolved.paths.destinationRoot),
              destination.path != resolved.paths.destinationRoot.path else {
            throw StewardError.unsafePath("destino registrado fuera de destination_root: \(destination.path)")
        }
    }

    private func assertSameFilesystem(file: URL, directory: URL, operation: String) throws {
        let fileIdentity = try FileSystemSecurity.posixIdentity(of: file)
        let directoryIdentity = try FileSystemSecurity.posixIdentity(of: directory)
        guard fileIdentity.deviceID == directoryIdentity.deviceID else {
            throw StewardError.unsafePath(
                "\(operation) entre sistemas de archivos distintos no está permitido: \(file.path) -> \(directory.path)"
            )
        }
    }

    private func collisionSafeDestination(
        for source: URL,
        in directory: URL,
        matchedExtension: String?
    ) throws -> URL {
        let originalName = source.lastPathComponent
        var destination = directory.appendingPathComponent(originalName, isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        let split = splitNameForCollision(originalName, matchedExtension: matchedExtension)
        for attempt in 1...resolved.config.collision.maxAttempts {
            let candidateName = "\(split.base) (\(attempt))\(split.suffix)"
            destination = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: destination.path) {
                return destination
            }
        }
        throw StewardError.commandFailed(
            "No se encontró un nombre libre tras \(resolved.config.collision.maxAttempts) intentos para \(originalName)"
        )
    }

    private func splitNameForCollision(_ filename: String, matchedExtension: String?) -> (base: String, suffix: String) {
        if let matchedExtension {
            let count = matchedExtension.count + 1
            if filename.count > count,
               ConfigurationIO.normalized(filename).hasSuffix("." + matchedExtension) {
                let splitIndex = filename.index(filename.endIndex, offsetBy: -count)
                return (String(filename[..<splitIndex]), String(filename[splitIndex...]))
            }
        }

        let url = URL(fileURLWithPath: filename)
        let pathExtension = url.pathExtension
        if !pathExtension.isEmpty, filename.count > pathExtension.count + 1 {
            let suffix = "." + pathExtension
            return (String(filename.dropLast(suffix.count)), suffix)
        }
        return (filename, "")
    }

    private func scheduledDryRunPlanSignature() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(resolved.config)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
