import Darwin
import Foundation
@_spi(Testing) import TidyDropUpdateRecovery

private enum HelperCommand: String {
    case status
    case install
    case recover
    case rollback
    case restoreState = "restore-state"
}

private enum ConfiguredTestCheckpoint: Equatable {
    case bundle(DestinationVolumeReplacementCheckpoint)
    case state(DryRunStateRestorationCheckpoint)

    var rawValue: String {
        switch self {
        case let .bundle(checkpoint): checkpoint.rawValue
        case let .state(checkpoint): checkpoint.rawValue
        }
    }

    var markerFileName: String {
        switch self {
        case let .bundle(checkpoint): checkpoint.markerFileName
        case let .state(checkpoint): checkpoint.markerFileName
        }
    }
}

private enum HelperFailure: Error {
    case invalidTestCheckpoint
    case unsafeTestWorkspace
    case checkpointMarkerFailed
}

private let testCheckpointEnvironment = "TIDYDROP_RECOVERY_TEST_STOP_AFTER"
private let integrationRootPrefix = "/private/tmp/TidyDropIntegration."

private func configuredTestCheckpoint(
    command: HelperCommand
) throws -> ConfiguredTestCheckpoint? {
    guard let rawValue = ProcessInfo.processInfo.environment[testCheckpointEnvironment] else {
        return nil
    }
    if command == .restoreState {
        guard let checkpoint = DryRunStateRestorationCheckpoint(rawValue: rawValue) else {
            throw HelperFailure.invalidTestCheckpoint
        }
        return .state(checkpoint)
    }
    guard let checkpoint = DestinationVolumeReplacementCheckpoint(rawValue: rawValue) else {
        throw HelperFailure.invalidTestCheckpoint
    }
    let allowed: Bool
    switch (command, checkpoint) {
    case (.install, .replacementStarted), (.install, .installSwapSynchronized),
         (.rollback, .rollbackStarted), (.rollback, .rollbackSwapSynchronized):
        allowed = true
    default:
        allowed = false
    }
    guard allowed else {
        throw HelperFailure.invalidTestCheckpoint
    }
    return .bundle(checkpoint)
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw HelperFailure.checkpointMarkerFailed
        }
        var written = 0
        while written < bytes.count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: written),
                bytes.count - written
            )
            guard result > 0 else {
                throw HelperFailure.checkpointMarkerFailed
            }
            written += result
        }
    }
}

private func stopAtCheckpoint(
    _ checkpoint: ConfiguredTestCheckpoint,
    locator: ExternalRecoveryTransactionLocator
) throws -> Never {
    var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = resolvedBuffer.withUnsafeMutableBufferPointer { storage in
        locator.workspaceURL.path.withCString { path in
            Darwin.realpath(path, storage.baseAddress)
        }
    }
    guard resolved != nil,
          let canonicalPath = resolvedBuffer.withUnsafeBufferPointer({ storage -> String? in
              guard let baseAddress = storage.baseAddress else { return nil }
              return String(validatingCString: baseAddress)
          }),
          canonicalPath.hasPrefix(integrationRootPrefix) else {
        throw HelperFailure.unsafeTestWorkspace
    }

    let workspaceDescriptor = canonicalPath.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard workspaceDescriptor >= 0 else {
        throw HelperFailure.unsafeTestWorkspace
    }
    defer { _ = Darwin.close(workspaceDescriptor) }

    var workspaceMetadata = stat()
    guard Darwin.fstat(workspaceDescriptor, &workspaceMetadata) == 0,
          (workspaceMetadata.st_mode & S_IFMT) == S_IFDIR,
          workspaceMetadata.st_uid == Darwin.geteuid(),
          workspaceMetadata.st_mode & 0o077 == 0,
          workspaceMetadata.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
        throw HelperFailure.unsafeTestWorkspace
    }

    let markerName = checkpoint.markerFileName
    let markerDescriptor = markerName.withCString {
        Darwin.openat(
            workspaceDescriptor,
            $0,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
    }
    guard markerDescriptor >= 0 else {
        throw HelperFailure.checkpointMarkerFailed
    }
    defer { _ = Darwin.close(markerDescriptor) }

    try writeAll(Data("\(checkpoint.rawValue)\n".utf8), to: markerDescriptor)
    guard Darwin.fsync(markerDescriptor) == 0,
          Darwin.fsync(workspaceDescriptor) == 0 else {
        throw HelperFailure.checkpointMarkerFailed
    }

    _ = Darwin.raise(SIGSTOP)
    Darwin._exit(90)
}

private func usage() -> Never {
    FileHandle.standardError.write(Data(
        "Usage: tidydrop-recovery-helper <status|install|recover|rollback> WORKSPACE TRANSACTION_ID [DESTINATION_PARENT]\n       tidydrop-recovery-helper restore-state WORKSPACE TRANSACTION_ID CONFIGURATION HOME\n".utf8
    ))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (3...5).contains(arguments.count),
      let command = HelperCommand(rawValue: arguments[0]) else {
    usage()
}
let locator = ExternalRecoveryTransactionLocator(
    workspaceURL: URL(fileURLWithPath: arguments[1], isDirectory: true),
    transactionID: arguments[2]
)

do {
    let testCheckpoint = try configuredTestCheckpoint(command: command)
    switch command {
    case .status:
        guard arguments.count == 3 else { usage() }
        let journal = try CurrentBundleRetentionBuilder.loadRecovering(locator: locator)
        print("state=\(journal.state.rawValue) sequence=\(journal.sequence) apply_enabled=false")
    case .install:
        guard arguments.count == 4 else { usage() }
        let parent = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let expectedCheckpoint: DestinationVolumeReplacementCheckpoint?
        if case let .bundle(checkpoint) = testCheckpoint {
            expectedCheckpoint = checkpoint
        } else {
            expectedCheckpoint = nil
        }
        let outcome = try DestinationVolumeReplacementProtocol.install(
            locator: locator,
            destinationParentURL: parent,
            fault: .none,
            checkpointHandler: { checkpoint in
                guard checkpoint == expectedCheckpoint else { return }
                try stopAtCheckpoint(.bundle(checkpoint), locator: locator)
            }
        )
        print("outcome=\(outcome) apply_enabled=false")
    case .recover:
        guard arguments.count == 4, testCheckpoint == nil else { usage() }
        let parent = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let outcome = try DestinationVolumeReplacementProtocol.recover(
            locator: locator,
            destinationParentURL: parent
        )
        print("outcome=\(outcome) apply_enabled=false")
    case .rollback:
        guard arguments.count == 4 else { usage() }
        let parent = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let expectedCheckpoint: DestinationVolumeReplacementCheckpoint?
        if case let .bundle(checkpoint) = testCheckpoint {
            expectedCheckpoint = checkpoint
        } else {
            expectedCheckpoint = nil
        }
        let outcome = try DestinationVolumeReplacementProtocol.rollback(
            locator: locator,
            destinationParentURL: parent,
            fault: .none,
            checkpointHandler: { checkpoint in
                guard checkpoint == expectedCheckpoint else { return }
                try stopAtCheckpoint(.bundle(checkpoint), locator: locator)
            }
        )
        print("outcome=\(outcome) apply_enabled=false")
    case .restoreState:
        guard arguments.count == 5 else { usage() }
        let configurationURL = URL(fileURLWithPath: arguments[3])
        let homeDirectory = URL(fileURLWithPath: arguments[4], isDirectory: true)
        let expectedCheckpoint: DryRunStateRestorationCheckpoint?
        if case let .state(checkpoint) = testCheckpoint {
            expectedCheckpoint = checkpoint
        } else {
            expectedCheckpoint = nil
        }
        let outcome = try DryRunStateRestorationProtocol.restore(
            locator: locator,
            configurationURL: configurationURL,
            homeDirectory: homeDirectory,
            supportedConfigurationSchemaVersion: 1,
            supportedActivitySchemaVersion: 1,
            fault: .none,
            checkpointHandler: { checkpoint in
                guard checkpoint == expectedCheckpoint else { return }
                try stopAtCheckpoint(.state(checkpoint), locator: locator)
            }
        )
        print("outcome=\(outcome.state.rawValue) apply_enabled=\(outcome.applyEnabled)")
    }
} catch {
    FileHandle.standardError.write(Data("recovery-helper-failed: \(error)\n".utf8))
    exit(1)
}
