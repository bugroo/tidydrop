import CryptoKit
import Darwin
import Foundation
import TidyDropCore

public enum DryRunStateRestorationFailure: Error, Equatable, Sendable {
    case invalidRequest
    case journalStateRejected
    case snapshotRejected
    case snapshotManifestBindingRejected
    case configurationBackupRejected
    case activityBackupRejected
    case incompatibleConfigurationSchema
    case incompatibleActivitySchema
    case unsafeDestination
    case liveStateBusy
    case stagingFailed
    case atomicReplacementFailed(Int32)
    case synchronizeFailed
    case restoredStateMismatch
    case injectedFailure
}

@_spi(Testing)
public enum DryRunStateRestorationFault: Equatable, Sendable {
    case none
    case afterStaging
    case afterRestorationStarted
    case afterConfigurationSwap
    case afterConfigurationJournal
    case afterActivitySwap
}

@_spi(Testing)
public enum DryRunStateRestorationCheckpoint: String, CaseIterable, Sendable {
    case candidatesSynchronized = "state_candidates_synchronized"
    case restorationStarted = "state_restoration_started"
    case configurationSwapSynchronized = "state_configuration_swap_synchronized"
    case configurationRestored = "state_configuration_restored"
    case activitySwapSynchronized = "state_activity_swap_synchronized"

    public var markerFileName: String {
        ".tidydrop-recovery-checkpoint-\(rawValue)"
    }
}

public struct DryRunStateRestorationOutcome: Equatable, Sendable {
    public let state: ExternalRecoveryState
    public let configurationRestored: Bool
    public let activityDatabaseRestored: Bool
    public let applyEnabled: Bool
}

/// Non-shipping, forward-only restoration of the state captured by ADR-0019.
///
/// This foundation is hard-limited to owner-private integration fixtures below
/// `/private/tmp`. It never traverses or mutates file-operation transaction
/// manifests, never invokes undo, and never gains installed-app authority.
public enum DryRunStateRestorationProtocol {
    private static let integrationRootPrefix = "/private/tmp/TidyDropIntegration."
    private static let configurationName = "config.json"
    private static let activityName = "activity.sqlite3"
    private static let manifestName = "recovery-manifest.json"
    private static let configurationBackupName = "config.dry-run.json"
    private static let maximumManifestBytes: UInt64 = 128 * 1_024
    private static let renameSwapFlags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
    private static let renameExclusiveFlags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)

    public static func restore(
        locator: ExternalRecoveryTransactionLocator,
        configurationURL: URL,
        homeDirectory: URL
    ) throws -> DryRunStateRestorationOutcome {
        try restore(
            locator: locator,
            configurationURL: configurationURL,
            homeDirectory: homeDirectory,
            supportedConfigurationSchemaVersion: 1,
            supportedActivitySchemaVersion: AgentActivityDatabase.schemaVersion,
            fault: .none
        )
    }

    @_spi(Testing)
    public static func restore(
        locator: ExternalRecoveryTransactionLocator,
        configurationURL: URL,
        homeDirectory: URL,
        supportedConfigurationSchemaVersion: Int,
        supportedActivitySchemaVersion: Int32,
        fault: DryRunStateRestorationFault,
        checkpointHandler: ((DryRunStateRestorationCheckpoint) throws -> Void)? = nil
    ) throws -> DryRunStateRestorationOutcome {
        var journal = try CurrentBundleRetentionBuilder.loadRecovering(locator: locator)
        guard [
            ExternalRecoveryState.rolledBack,
            .stateRestorationStarted,
            .configurationRestored,
            .stateRestored
        ].contains(journal.state) else {
            throw DryRunStateRestorationFailure.journalStateRejected
        }

        let inputs = try loadInputs(
            locator: locator,
            journal: journal,
            homeDirectory: homeDirectory,
            supportedConfigurationSchemaVersion: supportedConfigurationSchemaVersion,
            supportedActivitySchemaVersion: supportedActivitySchemaVersion
        )
        let configurationSlot = try FileSlot(
            liveURL: configurationURL,
            expectedLiveName: configurationName,
            candidateName: ".tidydrop-config-restore-\(journal.transactionID).next",
            maximumBytes: ConfigurationIO.maximumConfigurationBytes,
            liveMayBeAbsent: false
        )
        guard inputs.resolvedConfiguration.paths.activityDatabaseFile.lastPathComponent
                == activityName else {
            throw DryRunStateRestorationFailure.invalidRequest
        }

        let activitySlot: FileSlot?
        if inputs.activityData != nil {
            activitySlot = try FileSlot(
                liveURL: inputs.resolvedConfiguration.paths.activityDatabaseFile,
                expectedLiveName: activityName,
                candidateName: ".tidydrop-activity-restore-\(journal.transactionID).next",
                maximumBytes: AgentActivityDatabase.maximumDatabaseBytes,
                liveMayBeAbsent: true
            )
            if journal.state != .stateRestored,
               try activitySlot!.entryExists(name: activityName) {
                do {
                    try AgentActivityDatabase.quiesceForRecoveryReplacement(
                        at: activitySlot!.liveURL
                    )
                    try preserveSQLiteSidecars(
                        directory: activitySlot!,
                        liveName: activityName,
                        transactionID: journal.transactionID
                    )
                } catch {
                    throw DryRunStateRestorationFailure.liveStateBusy
                }
            }
            try rejectSQLiteSidecars(
                directory: activitySlot!,
                liveName: activityName
            )
        } else {
            activitySlot = nil
        }

        if journal.state == .rolledBack {
            try configurationSlot.ensureCandidate(
                expectedData: inputs.configurationData,
                expectedDigest: inputs.manifest.configurationSHA256
            )
            if let activityData = inputs.activityData,
               let activityDigest = inputs.manifest.activitySHA256,
               let activitySlot {
                try activitySlot.ensureCandidate(
                    expectedData: activityData,
                    expectedDigest: activityDigest
                )
            }
            try checkpointHandler?(.candidatesSynchronized)
            if fault == .afterStaging {
                throw DryRunStateRestorationFailure.injectedFailure
            }
            journal = try CurrentBundleRetentionBuilder.advance(
                locator: locator,
                to: .stateRestorationStarted
            )
            try checkpointHandler?(.restorationStarted)
            if fault == .afterRestorationStarted {
                throw DryRunStateRestorationFailure.injectedFailure
            }
        }

        if journal.state == .stateRestorationStarted {
            try configurationSlot.reconcile(expectedDigest: inputs.manifest.configurationSHA256)
            try checkpointHandler?(.configurationSwapSynchronized)
            if fault == .afterConfigurationSwap {
                throw DryRunStateRestorationFailure.injectedFailure
            }
            journal = try CurrentBundleRetentionBuilder.advance(
                locator: locator,
                to: .configurationRestored
            )
            try checkpointHandler?(.configurationRestored)
            if fault == .afterConfigurationJournal {
                throw DryRunStateRestorationFailure.injectedFailure
            }
        }

        if journal.state == .configurationRestored {
            if let activityDigest = inputs.manifest.activitySHA256,
               let activitySlot {
                try activitySlot.reconcile(expectedDigest: activityDigest)
            }
            try checkpointHandler?(.activitySwapSynchronized)
            if fault == .afterActivitySwap {
                throw DryRunStateRestorationFailure.injectedFailure
            }
            journal = try CurrentBundleRetentionBuilder.advance(
                locator: locator,
                to: .stateRestored
            )
        }

        guard journal.state == .stateRestored else {
            throw DryRunStateRestorationFailure.journalStateRejected
        }
        try verifyRestoredConfiguration(
            at: configurationSlot.liveURL,
            expectedDigest: inputs.manifest.configurationSHA256,
            homeDirectory: homeDirectory
        )
        if let activityDigest = inputs.manifest.activitySHA256,
           let activitySlot {
            guard try activitySlot.liveDigest() == activityDigest,
                  try AgentActivityDatabase.verifyRecoveryDatabase(
                    at: activitySlot.liveURL
                  ) == supportedActivitySchemaVersion else {
                throw DryRunStateRestorationFailure.restoredStateMismatch
            }
        }
        return DryRunStateRestorationOutcome(
            state: journal.state,
            configurationRestored: true,
            activityDatabaseRestored: inputs.activityData != nil,
            applyEnabled: false
        )
    }

    private struct Inputs {
        let manifest: UpdateRecoverySnapshotManifest
        let configurationData: Data
        let activityData: Data?
        let resolvedConfiguration: ResolvedConfiguration
    }

    private static func loadInputs(
        locator: ExternalRecoveryTransactionLocator,
        journal: ExternalRecoveryJournal,
        homeDirectory: URL,
        supportedConfigurationSchemaVersion: Int,
        supportedActivitySchemaVersion: Int32
    ) throws -> Inputs {
        guard locator.workspaceURL.isFileURL,
              journal.applyEnabled == false,
              journal.stateSnapshotManifestName == manifestName else {
            throw DryRunStateRestorationFailure.invalidRequest
        }
        let workspaceURL = try canonicalPrivateIntegrationDirectory(locator.workspaceURL)
        let manifestURL = workspaceURL.appendingPathComponent(manifestName)
        let manifestData = try readRegular(
            manifestURL,
            maximumBytes: maximumManifestBytes
        )
        guard digest(manifestData) == journal.stateSnapshotManifestSHA256,
              let manifest = try? JSONDecoder().decode(
                UpdateRecoverySnapshotManifest.self,
                from: manifestData
              ),
              manifest.formatVersion == 1,
              manifest.transactionID == journal.transactionID,
              manifest.bundleIdentifier == journal.bundleIdentifier,
              manifest.currentVersion == journal.currentVersion,
              manifest.targetVersion == journal.targetVersion,
              manifest.configurationBackupName == configurationBackupName,
              manifest.applyEnabled == false else {
            throw DryRunStateRestorationFailure.snapshotManifestBindingRejected
        }
        guard manifest.configurationSchemaVersion == supportedConfigurationSchemaVersion else {
            throw DryRunStateRestorationFailure.incompatibleConfigurationSchema
        }

        let configurationURL = workspaceURL.appendingPathComponent(
            configurationBackupName
        )
        let configurationData = try readRegular(
            configurationURL,
            maximumBytes: ConfigurationIO.maximumConfigurationBytes
        )
        guard digest(configurationData) == manifest.configurationSHA256,
              let configuration = try? JSONDecoder().decode(
                StewardConfig.self,
                from: configurationData
              ),
              configuration.version == supportedConfigurationSchemaVersion,
              configuration.automation.applyEnabled == false,
              let resolved = try? ConfigurationIO.resolve(
                configuration,
                homeDirectory: homeDirectory
              ) else {
            throw DryRunStateRestorationFailure.configurationBackupRejected
        }

        let activityFields = (
            manifest.activityBackupName,
            manifest.activitySHA256,
            manifest.activitySchemaVersion
        )
        let activityData: Data?
        switch activityFields {
        case (nil, nil, nil):
            activityData = nil
        case let (.some(name), .some(expectedDigest), .some(schema)):
            guard name == activityName else {
                throw DryRunStateRestorationFailure.activityBackupRejected
            }
            guard schema == supportedActivitySchemaVersion else {
                throw DryRunStateRestorationFailure.incompatibleActivitySchema
            }
            let activityURL = workspaceURL.appendingPathComponent(name)
            let data = try readRegular(
                activityURL,
                maximumBytes: AgentActivityDatabase.maximumDatabaseBytes
            )
            guard digest(data) == expectedDigest,
                  (try? AgentActivityDatabase.verifyRecoveryDatabase(at: activityURL))
                    == supportedActivitySchemaVersion else {
                throw DryRunStateRestorationFailure.activityBackupRejected
            }
            activityData = data
        default:
            throw DryRunStateRestorationFailure.activityBackupRejected
        }
        return Inputs(
            manifest: manifest,
            configurationData: configurationData,
            activityData: activityData,
            resolvedConfiguration: resolved
        )
    }

    private static func verifyRestoredConfiguration(
        at url: URL,
        expectedDigest: String,
        homeDirectory: URL
    ) throws {
        let data = try readRegular(
            url,
            maximumBytes: ConfigurationIO.maximumConfigurationBytes
        )
        guard digest(data) == expectedDigest,
              let resolved = try? ConfigurationIO.load(
                from: url,
                homeDirectory: homeDirectory
              ),
              resolved.config.automation.applyEnabled == false else {
            throw DryRunStateRestorationFailure.restoredStateMismatch
        }
    }

    private static func rejectSQLiteSidecars(
        directory: FileSlot,
        liveName: String
    ) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            if try directory.entryExists(name: liveName + suffix) {
                throw DryRunStateRestorationFailure.liveStateBusy
            }
        }
    }

    private static func preserveSQLiteSidecars(
        directory: FileSlot,
        liveName: String,
        transactionID: String
    ) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            try directory.preserveEntryIfPresent(
                name: liveName + suffix,
                preservedName: ".tidydrop-activity-restore-\(transactionID).previous\(suffix)"
            )
        }
    }

    private static func readRegular(_ url: URL, maximumBytes: UInt64) throws -> Data {
        do {
            return try FileSystemSecurity.readRegularFile(url, maximumBytes: maximumBytes)
        } catch {
            throw DryRunStateRestorationFailure.snapshotRejected
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalPrivateIntegrationDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DryRunStateRestorationFailure.invalidRequest
        }
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = resolvedBuffer.withUnsafeMutableBufferPointer { storage in
            url.path.withCString { path in
                Darwin.realpath(path, storage.baseAddress)
            }
        }
        guard resolved != nil,
              let canonicalPath = resolvedBuffer.withUnsafeBufferPointer({ storage -> String? in
                  guard let baseAddress = storage.baseAddress else { return nil }
                  return String(validatingCString: baseAddress)
              }),
              canonicalPath.hasPrefix(integrationRootPrefix) else {
            throw DryRunStateRestorationFailure.unsafeDestination
        }
        let descriptor = canonicalPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DryRunStateRestorationFailure.unsafeDestination
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw DryRunStateRestorationFailure.unsafeDestination
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private final class FileSlot {
        let liveURL: URL
        let liveName: String
        let candidateName: String
        let maximumBytes: UInt64
        let liveMayBeAbsent: Bool
        private let directoryDescriptor: Int32

        init(
            liveURL: URL,
            expectedLiveName: String,
            candidateName: String,
            maximumBytes: UInt64,
            liveMayBeAbsent: Bool
        ) throws {
            guard liveURL.isFileURL,
                  liveURL.path.hasPrefix("/"),
                  liveURL.lastPathComponent == expectedLiveName,
                  !candidateName.isEmpty,
                  !candidateName.contains("/"),
                  candidateName != ".",
                  candidateName != ".." else {
                throw DryRunStateRestorationFailure.invalidRequest
            }
            let parentURL = liveURL.deletingLastPathComponent()
            var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let resolved = resolvedBuffer.withUnsafeMutableBufferPointer { storage in
                parentURL.path.withCString { path in
                    Darwin.realpath(path, storage.baseAddress)
                }
            }
            guard resolved != nil,
                  let canonicalPath = resolvedBuffer.withUnsafeBufferPointer({ storage -> String? in
                      guard let baseAddress = storage.baseAddress else { return nil }
                      return String(validatingCString: baseAddress)
                  }),
                  (
                    canonicalPath == parentURL.path
                        || (
                            parentURL.path.hasPrefix("/tmp/TidyDropIntegration.")
                                && canonicalPath == "/private\(parentURL.path)"
                        )
                  ),
                  canonicalPath.hasPrefix(integrationRootPrefix) else {
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            let descriptor = canonicalPath.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & 0o077 == 0,
                  metadata.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
                _ = Darwin.close(descriptor)
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            self.liveURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
                .appendingPathComponent(expectedLiveName)
            self.liveName = expectedLiveName
            self.candidateName = candidateName
            self.maximumBytes = maximumBytes
            self.liveMayBeAbsent = liveMayBeAbsent
            self.directoryDescriptor = descriptor
        }

        deinit {
            _ = Darwin.close(directoryDescriptor)
        }

        func ensureCandidate(expectedData: Data, expectedDigest: String) throws {
            if try liveDigest() == expectedDigest { return }
            if let candidateDigest = try digestIfPresent(candidateName) {
                guard candidateDigest == expectedDigest else {
                    throw DryRunStateRestorationFailure.stagingFailed
                }
                return
            }
            let descriptor = candidateName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    0o600
                )
            }
            guard descriptor >= 0 else {
                throw DryRunStateRestorationFailure.stagingFailed
            }
            defer { _ = Darwin.close(descriptor) }
            try writeAll(expectedData, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0,
                  Darwin.fsync(directoryDescriptor) == 0,
                  try digestIfPresent(candidateName) == expectedDigest else {
                throw DryRunStateRestorationFailure.synchronizeFailed
            }
        }

        func reconcile(expectedDigest: String) throws {
            if try liveDigest() == expectedDigest { return }
            guard try digestIfPresent(candidateName) == expectedDigest else {
                throw DryRunStateRestorationFailure.restoredStateMismatch
            }
            let result: Int32
            if try entryExists(name: liveName) {
                result = liveName.withCString { live in
                    candidateName.withCString { candidate in
                        Darwin.renameatx_np(
                            directoryDescriptor,
                            live,
                            directoryDescriptor,
                            candidate,
                            renameSwapFlags
                        )
                    }
                }
            } else {
                guard liveMayBeAbsent else {
                    throw DryRunStateRestorationFailure.unsafeDestination
                }
                result = candidateName.withCString { candidate in
                    liveName.withCString { live in
                        Darwin.renameatx_np(
                            directoryDescriptor,
                            candidate,
                            directoryDescriptor,
                            live,
                            renameExclusiveFlags
                        )
                    }
                }
            }
            guard result == 0 else {
                throw DryRunStateRestorationFailure.atomicReplacementFailed(errno)
            }
            guard Darwin.fsync(directoryDescriptor) == 0,
                  try liveDigest() == expectedDigest else {
                throw DryRunStateRestorationFailure.synchronizeFailed
            }
        }

        func liveDigest() throws -> String? {
            try digestIfPresent(liveName)
        }

        func entryExists(name: String) throws -> Bool {
            var metadata = stat()
            let result = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return true }
            guard errno == ENOENT else {
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            return false
        }

        func preserveEntryIfPresent(name: String, preservedName: String) throws {
            guard isSafeEntryName(name), isSafeEntryName(preservedName) else {
                throw DryRunStateRestorationFailure.invalidRequest
            }
            let sourceExists = try entryExists(name: name)
            let preservedExists = try entryExists(name: preservedName)
            guard !(sourceExists && preservedExists) else {
                throw DryRunStateRestorationFailure.liveStateBusy
            }
            if !sourceExists {
                if preservedExists {
                    guard try digestIfPresent(preservedName) != nil else {
                        throw DryRunStateRestorationFailure.unsafeDestination
                    }
                }
                return
            }
            guard try digestIfPresent(name) != nil else {
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            let result = name.withCString { source in
                preservedName.withCString { preserved in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        source,
                        directoryDescriptor,
                        preserved,
                        renameExclusiveFlags
                    )
                }
            }
            guard result == 0 else {
                throw DryRunStateRestorationFailure.atomicReplacementFailed(errno)
            }
            guard Darwin.fsync(directoryDescriptor) == 0,
                  try entryExists(name: name) == false,
                  try digestIfPresent(preservedName) != nil else {
                throw DryRunStateRestorationFailure.synchronizeFailed
            }
        }

        private func isSafeEntryName(_ name: String) -> Bool {
            !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        }

        private func digestIfPresent(_ name: String) throws -> String? {
            let descriptor = name.withCString {
                Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            if descriptor < 0 {
                guard errno == ENOENT else {
                    throw DryRunStateRestorationFailure.unsafeDestination
                }
                return nil
            }
            defer { _ = Darwin.close(descriptor) }
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & 0o022 == 0,
                  metadata.st_size >= 0,
                  UInt64(metadata.st_size) <= maximumBytes else {
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            var data = Data()
            data.reserveCapacity(Int(metadata.st_size))
            var offset: off_t = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.pread(descriptor, $0.baseAddress, $0.count, offset)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw DryRunStateRestorationFailure.unsafeDestination
                }
                data.append(buffer, count: count)
                offset += off_t(count)
                guard UInt64(data.count) <= maximumBytes else {
                    throw DryRunStateRestorationFailure.unsafeDestination
                }
            }
            guard data.count == Int(metadata.st_size) else {
                throw DryRunStateRestorationFailure.unsafeDestination
            }
            return digest(data)
        }

        private func writeAll(_ data: Data, descriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else {
                        throw DryRunStateRestorationFailure.stagingFailed
                    }
                    offset += result
                }
            }
        }
    }
}
