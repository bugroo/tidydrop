import Foundation

public enum AgentSchedulingPolicy {
    public static let eventDebounceSeconds: TimeInterval = 2
    public static let lockRetrySeconds: TimeInterval = 10
    public static let transientErrorRetrySeconds: TimeInterval = 60

    public static func sourceEventRequiresRun(
        eventPath: String,
        sourceDirectory: URL,
        requiresFullScan: Bool
    ) -> Bool {
        if requiresFullScan { return true }
        let source = ConfigurationIO.canonicalURL(sourceDirectory).path
        let event = ConfigurationIO.canonicalEventURL(
            URL(fileURLWithPath: eventPath)
        ).path
        if event == source { return true }
        return URL(fileURLWithPath: event).deletingLastPathComponent().path == source
    }

    public static func followUpDelay(
        after record: ScheduledRunRecord,
        stability: StabilityConfig
    ) -> TimeInterval? {
        switch record.outcome {
        case .lockBusy:
            return lockRetrySeconds
        case .error:
            return transientErrorRetrySeconds
        case .sourceUnavailable:
            return nil
        case .success:
            guard (record.deferred ?? 0) > 0 else { return nil }
            return max(eventDebounceSeconds, stability.minimumAgeSeconds + 1)
        }
    }
}
