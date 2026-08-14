import Foundation

public enum LaunchAgentStatusResolver {
    public static func accessStatus(
        agentInstalled: Bool,
        scheduledRecord: ScheduledRunRecord?
    ) -> String {
        guard agentInstalled else { return "not_installed" }
        guard let scheduledRecord else { return "installed_not_verified" }
        if scheduledRecord.outcome == .success, scheduledRecord.agentReady == false {
            return "watcher_starting"
        }
        return scheduledRecord.outcome.rawValue
    }
}
