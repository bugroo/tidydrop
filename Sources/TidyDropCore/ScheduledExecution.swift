import Foundation

public enum ScheduledExecution {
    public static func run(configurationURL: URL = ConfigurationIO.defaultConfigPath()) -> Int32 {
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            let mode: ExecutionMode = resolved.config.automation.applyEnabled ? .apply : .dryRun
            let engine = try StewardEngine(configuration: resolved)

            do {
                let summary = try engine.run(
                    mode: mode,
                    recordEmptyRun: !resolved.config.logging.suppressScheduledNoopAudit,
                    suppressUnchangedDryRunPlans: mode == .dryRun
                        && resolved.config.logging.suppressScheduledNoopAudit
                )
                let outcome: ScheduledRunOutcome = summary.errors == 0 ? .success : .error
                try JSONFile.save(
                    ScheduledRunRecord(
                        outcome: outcome,
                        runID: summary.runID,
                        mode: summary.mode.rawValue,
                        scanned: summary.scanned,
                        planned: summary.planned,
                        moved: summary.moved,
                        deferred: summary.deferred,
                        skipped: summary.skipped,
                        errors: summary.errors,
                        sourceDirectory: resolved.paths.sourceDirectory.path
                    ),
                    to: resolved.paths.scheduledStatusFile
                )
                return summary.errors == 0 ? 0 : 5
            } catch StewardError.lockBusy(let path) {
                try JSONFile.save(
                    ScheduledRunRecord(
                        outcome: .lockBusy,
                        runID: "agent-lock-\(RunIdentifier.make())",
                        detail: path
                    ),
                    to: resolved.paths.scheduledStatusFile
                )
                return 0
            } catch StewardError.sourceUnavailable(let path) {
                try JSONFile.save(
                    ScheduledRunRecord(
                        outcome: .sourceUnavailable,
                        runID: "agent-source-\(RunIdentifier.make())",
                        mode: mode.rawValue,
                        moved: 0,
                        errors: 1,
                        detail: path,
                        sourceDirectory: resolved.paths.sourceDirectory.path
                    ),
                    to: resolved.paths.scheduledStatusFile
                )
                return 0
            }
        } catch {
            recordFailure(error, configurationURL: configurationURL)
            return 2
        }
    }

    private static func recordFailure(_ error: Error, configurationURL: URL) {
        let context = failureContext(configurationURL: configurationURL)
        let detail = String(describing: error)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let runID = "agent-error-\(RunIdentifier.make())"
        try? JSONFile.save(
            ScheduledRunRecord(outcome: .error, runID: runID, detail: detail),
            to: context.statusURL
        )

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) ERROR run=\(runID) detail=\(detail)\n"
        try? FileSystemSecurity.appendBounded(
            Data(line.utf8),
            to: context.errorLogURL,
            maxBytes: context.maxFileBytes,
            retainedFiles: context.rotatedFileCount
        )
    }

    private struct FailureContext {
        let statusURL: URL
        let errorLogURL: URL
        let maxFileBytes: UInt64
        let rotatedFileCount: Int
    }

    private static func failureContext(configurationURL: URL) -> FailureContext {
        if let resolved = try? ConfigurationIO.load(from: configurationURL) {
            return FailureContext(
                statusURL: resolved.paths.scheduledStatusFile,
                errorLogURL: resolved.paths.agentErrorLogFile,
                maxFileBytes: resolved.config.logging.maxFileBytes,
                rotatedFileCount: resolved.config.logging.rotatedFileCount
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home
            .appendingPathComponent("Library/Application Support/TidyDrop", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/TidyDrop", isDirectory: true)
        return FailureContext(
            statusURL: support
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("last-scheduled-run.json"),
            errorLogURL: logs.appendingPathComponent("agent-errors.log"),
            maxFileBytes: 5_242_880,
            rotatedFileCount: 3
        )
    }
}
