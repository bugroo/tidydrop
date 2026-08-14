import Foundation

public enum BackgroundVerificationPolicy {
    public static func accepts(
        _ record: ScheduledRunRecord,
        sourceDirectory: URL,
        applyEnabled: Bool,
        notOlderThan earliestAcceptedDate: Date? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 600
    ) -> Bool {
        guard record.outcome == .success,
              record.agentReady == true,
              record.errors == 0,
              let recordedSource = record.sourceDirectory,
              URL(fileURLWithPath: recordedSource)
                .resolvingSymlinksInPath().standardizedFileURL.path
                == sourceDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
              record.timestamp <= now.addingTimeInterval(60),
              now.timeIntervalSince(record.timestamp) <= maximumAge else {
            return false
        }

        if let earliestAcceptedDate, record.timestamp < earliestAcceptedDate {
            return false
        }

        if applyEnabled {
            return record.mode == ExecutionMode.apply.rawValue
        }
        return record.mode == ExecutionMode.dryRun.rawValue && record.moved == 0
    }
}
