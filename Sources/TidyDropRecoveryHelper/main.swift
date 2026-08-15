import Foundation
import TidyDropUpdateRecovery

private enum HelperCommand: String {
    case status
    case install
    case recover
    case rollback
}

private func usage() -> Never {
    FileHandle.standardError.write(Data(
        "Usage: tidydrop-recovery-helper <status|install|recover|rollback> WORKSPACE TRANSACTION_ID [DESTINATION_PARENT]\n".utf8
    ))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 || arguments.count == 4,
      let command = HelperCommand(rawValue: arguments[0]) else {
    usage()
}
let locator = ExternalRecoveryTransactionLocator(
    workspaceURL: URL(fileURLWithPath: arguments[1], isDirectory: true),
    transactionID: arguments[2]
)

do {
    if command == .status {
        guard arguments.count == 3 else { usage() }
        let journal = try CurrentBundleRetentionBuilder.loadRecovering(locator: locator)
        print("state=\(journal.state.rawValue) sequence=\(journal.sequence) apply_enabled=false")
        exit(0)
    }
    guard arguments.count == 4 else { usage() }
    let parent = URL(fileURLWithPath: arguments[3], isDirectory: true)
    let outcome: DestinationVolumeReplacementOutcome
    switch command {
    case .install:
        outcome = try DestinationVolumeReplacementProtocol.install(
            locator: locator,
            destinationParentURL: parent
        )
    case .recover:
        outcome = try DestinationVolumeReplacementProtocol.recover(
            locator: locator,
            destinationParentURL: parent
        )
    case .rollback:
        outcome = try DestinationVolumeReplacementProtocol.rollback(
            locator: locator,
            destinationParentURL: parent
        )
    case .status:
        usage()
    }
    print("outcome=\(outcome) apply_enabled=false")
} catch {
    FileHandle.standardError.write(Data("recovery-helper-failed: \(error)\n".utf8))
    exit(1)
}
