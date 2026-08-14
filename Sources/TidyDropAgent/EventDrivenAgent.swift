import Darwin
import Foundation
import TidyDropCore

final class EventDrivenAgent: @unchecked Sendable {
    private let configurationURL: URL
    private let queue = DispatchQueue(label: "io.github.bugroo.tidydrop.agent.events", qos: .utility)
    private var watcher: FSEventsWatcher?
    private var timer: DispatchSourceTimer?
    private var terminationSources: [DispatchSourceSignal] = []
    private var sourceDirectory: URL?
    private var retryCount = 0

    init(configurationURL: URL) {
        self.configurationURL = configurationURL.standardizedFileURL
    }

    func run() -> Never {
        installTerminationHandlers()
        queue.async { [self] in
            do {
                performRun(reason: "startup_reconciliation", agentReady: false)
                try rebuildWatcher()
                timer?.cancel()
                timer = nil
                performRun(reason: "watcher_ready", agentReady: true)
            } catch {
                fputs("TidyDrop agent failed to start: \(error)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }

    private func installTerminationHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.timer?.cancel()
                self?.timer = nil
                self?.watcher?.stop()
                self?.watcher = nil
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    private func rebuildWatcher() throws {
        let resolved = try ConfigurationIO.load(from: configurationURL)
        let source = ConfigurationIO.canonicalURL(resolved.paths.sourceDirectory)
        var paths = [source.path, configurationURL.deletingLastPathComponent().path]
        if ConfigurationIO.isSameOrDescendant(source, of: URL(fileURLWithPath: "/Volumes")) {
            paths.append("/Volumes")
        }
        watcher?.stop()
        watcher = nil
        sourceDirectory = source
        watcher = try FSEventsWatcher(paths: Array(Set(paths)).sorted(), queue: queue) { [weak self] events in
            self?.handle(events)
        }
    }

    private func handle(_ events: [FileSystemEvent]) {
        guard let sourceDirectory else { return }
        let canonicalConfigurationURL = ConfigurationIO.canonicalEventURL(configurationURL)
        let configurationPath = canonicalConfigurationURL.path
        let configurationDirectory = canonicalConfigurationURL.deletingLastPathComponent()
        let configurationTemporaryPrefix = ".\(configurationURL.lastPathComponent).tmp."
        let requestPath: String?
        let requestTemporaryPrefix: String?
        if let resolved = try? ConfigurationIO.load(from: configurationURL) {
            requestPath = resolved.paths.agentRunRequestFile.path
            requestTemporaryPrefix = ".\(resolved.paths.agentRunRequestFile.lastPathComponent).tmp."
        } else {
            requestPath = nil
            requestTemporaryPrefix = nil
        }
        var configurationChanged = false
        var sourceChanged = false

        for event in events {
            let eventURL = ConfigurationIO.canonicalEventURL(URL(fileURLWithPath: event.path))
            if eventURL.path == configurationPath
                || (eventURL.deletingLastPathComponent() == configurationDirectory
                    && eventURL.lastPathComponent.hasPrefix(configurationTemporaryPrefix)) {
                configurationChanged = true
            }
            if let requestPath {
                let requestURL = ConfigurationIO.canonicalEventURL(URL(fileURLWithPath: requestPath))
                let requestDirectory = requestURL.deletingLastPathComponent()
                let matchesRequest = eventURL == requestURL
                    || eventURL == requestDirectory
                    || (eventURL.deletingLastPathComponent() == requestDirectory
                        && requestTemporaryPrefix.map(eventURL.lastPathComponent.hasPrefix) == true)
                if matchesRequest,
                   AgentRunRequestSignal.consumeIfValid(
                       at: requestURL,
                       sourceDirectory: sourceDirectory
                   ) {
                    sourceChanged = true
                }
            }
            if AgentSchedulingPolicy.sourceEventRequiresRun(
                eventPath: event.path,
                sourceDirectory: sourceDirectory,
                requiresFullScan: event.requiresFullScan
            ) {
                sourceChanged = true
            }
            if event.requiresFullScan,
               ConfigurationIO.isSameOrDescendant(sourceDirectory, of: URL(fileURLWithPath: "/Volumes")) {
                sourceChanged = true
            }
        }

        guard configurationChanged || sourceChanged else { return }
        retryCount = 0
        if configurationChanged {
            do {
                try rebuildWatcher()
            } catch {
                fputs("TidyDrop agent could not reload configuration: \(error)\n", stderr)
                schedule(after: AgentSchedulingPolicy.transientErrorRetrySeconds, reason: "configuration_retry")
                return
            }
        }
        schedule(after: AgentSchedulingPolicy.eventDebounceSeconds, reason: "filesystem_event")
    }

    private func schedule(after delay: TimeInterval, reason: String) {
        timer?.cancel()
        let next = DispatchSource.makeTimerSource(queue: queue)
        let milliseconds = max(1, Int(delay * 1_000))
        let leewayMilliseconds = min(2_000, max(250, milliseconds / 10))
        next.schedule(
            deadline: .now() + .milliseconds(milliseconds),
            leeway: .milliseconds(leewayMilliseconds)
        )
        next.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.performRun(reason: reason, agentReady: true)
        }
        timer = next
        next.resume()
    }

    private func performRun(reason: String, agentReady: Bool) {
        let exitCode = ScheduledExecution.run(
            configurationURL: configurationURL,
            agentReady: agentReady
        )
        guard exitCode == 0 else {
            scheduleBoundedErrorRetry(reason: "\(reason)_exit_\(exitCode)")
            return
        }
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            let currentSource = ConfigurationIO.canonicalURL(resolved.paths.sourceDirectory)
            if currentSource != sourceDirectory {
                try rebuildWatcher()
            }
            let record = try JSONFile.load(
                ScheduledRunRecord.self,
                from: resolved.paths.scheduledStatusFile,
                default: ScheduledRunRecord(outcome: .error, runID: "missing")
            )
            if record.outcome == .success || record.outcome == .sourceUnavailable {
                retryCount = 0
            }
            guard let delay = AgentSchedulingPolicy.followUpDelay(
                after: record,
                stability: resolved.config.stability
            ) else { return }
            if record.outcome == .error || record.outcome == .lockBusy {
                retryCount += 1
                guard retryCount <= 3 else { return }
            }
            schedule(after: delay, reason: record.outcome.rawValue)
        } catch {
            scheduleBoundedErrorRetry(reason: "\(reason)_status_read")
        }
    }

    private func scheduleBoundedErrorRetry(reason: String) {
        retryCount += 1
        guard retryCount <= 3 else {
            fputs("TidyDrop agent stopped retrying after repeated errors: \(reason)\n", stderr)
            return
        }
        schedule(after: AgentSchedulingPolicy.transientErrorRetrySeconds, reason: reason)
    }
}
