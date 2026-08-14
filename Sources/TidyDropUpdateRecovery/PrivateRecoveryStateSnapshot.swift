import CryptoKit
import Darwin
import Foundation
import TidyDropCore
import TidyDropUpdateSecurity

public enum UpdateRecoverySnapshotFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unsafeRecoveryParent
    case snapshotCreationFailed
    case configurationBackupFailed
    case unsafeActivityDatabase
    case unsupportedActivitySchema
    case activityBackupFailed(String)
    case activityIntegrityCheckFailed
    case manifestWriteFailed
    case synchronizeFailed
    case injectedFailure
}

@_spi(Testing)
public enum UpdateRecoverySnapshotFault: Equatable, Sendable {
    case none
    case afterConfigurationBackup
    case afterActivityBackup
    case beforeManifest
}

public struct UpdateRecoverySnapshotManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let transactionID: String
    public let createdAt: String
    public let bundleIdentifier: String
    public let currentVersion: String
    public let targetVersion: String
    public let configurationSchemaVersion: Int
    public let configurationBackupName: String
    public let configurationSHA256: String
    public let activityBackupName: String?
    public let activitySHA256: String?
    public let activitySchemaVersion: Int32?
    public let applyEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case transactionID = "transaction_id"
        case createdAt = "created_at"
        case bundleIdentifier = "bundle_identifier"
        case currentVersion = "current_version"
        case targetVersion = "target_version"
        case configurationSchemaVersion = "configuration_schema_version"
        case configurationBackupName = "configuration_backup_name"
        case configurationSHA256 = "configuration_sha256"
        case activityBackupName = "activity_backup_name"
        case activitySHA256 = "activity_sha256"
        case activitySchemaVersion = "activity_schema_version"
        case applyEnabled = "apply_enabled"
    }
}

public struct PreparedUpdateRecoverySnapshot: Equatable, Sendable {
    public let workspaceURL: URL
    public let manifestURL: URL
    public let configurationBackupURL: URL
    public let activityBackupURL: URL?
    public let manifest: UpdateRecoverySnapshotManifest

    public init(
        workspaceURL: URL,
        manifestURL: URL,
        configurationBackupURL: URL,
        activityBackupURL: URL?,
        manifest: UpdateRecoverySnapshotManifest
    ) {
        self.workspaceURL = workspaceURL
        self.manifestURL = manifestURL
        self.configurationBackupURL = configurationBackupURL
        self.activityBackupURL = activityBackupURL
        self.manifest = manifest
    }
}

/// Creates a private, self-describing state snapshot for a future external
/// recovery process. This target is not linked into any shipping executable.
/// It never copies, replaces, launches, registers, or removes an app bundle.
public enum PrivateUpdateRecoverySnapshotBuilder {
    private static let workspacePrefix = ".tidydrop-recovery-"
    private static let maximumWorkspaceAttempts = 8
    private static let configurationBackupName = "config.dry-run.json"
    private static let activityBackupName = "activity.sqlite3"
    private static let manifestName = "recovery-manifest.json"

    public static func prepare(
        configurationURL: URL,
        recoveryParent: URL,
        currentVersion: String,
        authenticatedTarget: AuthenticatedReleaseManifest
    ) throws -> PreparedUpdateRecoverySnapshot {
        try prepare(
            configurationURL: configurationURL,
            recoveryParent: recoveryParent,
            currentVersion: currentVersion,
            authenticatedTarget: authenticatedTarget,
            fault: .none
        )
    }

    @_spi(Testing)
    public static func prepare(
        configurationURL: URL,
        recoveryParent: URL,
        currentVersion: String,
        authenticatedTarget: AuthenticatedReleaseManifest,
        fault: UpdateRecoverySnapshotFault
    ) throws -> PreparedUpdateRecoverySnapshot {
        let target = authenticatedTarget.manifest
        guard configurationURL.isFileURL,
              configurationURL.path.hasPrefix("/"),
              recoveryParent.isFileURL,
              recoveryParent.path.hasPrefix("/"),
              isSafeVersionText(currentVersion),
              target.bundleIdentifier == "io.github.bugroo.tidydrop" else {
            throw UpdateRecoverySnapshotFailure.invalidRequest
        }

        let resolved = try ConfigurationIO.load(from: configurationURL)
        let parentURL = recoveryParent.standardizedFileURL
        let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else {
            throw UpdateRecoverySnapshotFailure.unsafeRecoveryParent
        }
        defer { _ = Darwin.close(parentDescriptor) }
        guard validateOwnedPrivateDirectory(parentDescriptor) else {
            throw UpdateRecoverySnapshotFailure.unsafeRecoveryParent
        }

        let transactionID = UUID().uuidString.lowercased()
        let workspaceName = try createWorkspace(
            parentDescriptor: parentDescriptor,
            transactionID: transactionID
        )
        let workspaceDescriptor = workspaceName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard workspaceDescriptor >= 0, validateOwnedPrivateDirectory(workspaceDescriptor) else {
            cleanupWorkspace(parentDescriptor: parentDescriptor, workspaceName: workspaceName)
            throw UpdateRecoverySnapshotFailure.snapshotCreationFailed
        }

        var keepWorkspace = false
        defer {
            _ = Darwin.close(workspaceDescriptor)
            if !keepWorkspace {
                cleanupWorkspace(parentDescriptor: parentDescriptor, workspaceName: workspaceName)
            }
        }

        let workspaceURL = parentURL.appendingPathComponent(workspaceName, isDirectory: true)
        let configurationBackupURL = workspaceURL.appendingPathComponent(configurationBackupName)
        let activityBackupURL = workspaceURL.appendingPathComponent(activityBackupName)
        let manifestURL = workspaceURL.appendingPathComponent(manifestName)

        var recoveryConfiguration = resolved.config
        recoveryConfiguration.automation.applyEnabled = false
        let configurationData = try encodeConfiguration(recoveryConfiguration)
        do {
            try writeExclusivePrivate(
                configurationData,
                name: configurationBackupName,
                directoryDescriptor: workspaceDescriptor
            )
        } catch {
            throw UpdateRecoverySnapshotFailure.configurationBackupFailed
        }
        let configurationDigest = sha256(configurationData)
        if fault == .afterConfigurationBackup {
            throw UpdateRecoverySnapshotFailure.injectedFailure
        }

        let activitySource = resolved.paths.activityDatabaseFile
        var backedUpActivityURL: URL?
        var activityDigest: String?
        var activitySchema: Int32?
        if try FileSystemSecurity.pathEntryExists(activitySource) {
            let result = try backupActivityDatabase(
                sourceURL: activitySource,
                destinationURL: activityBackupURL
            )
            backedUpActivityURL = activityBackupURL
            activityDigest = result.digest
            activitySchema = result.schemaVersion
        }
        if fault == .afterActivityBackup {
            throw UpdateRecoverySnapshotFailure.injectedFailure
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let manifest = UpdateRecoverySnapshotManifest(
            formatVersion: 1,
            transactionID: transactionID,
            createdAt: formatter.string(from: Date()),
            bundleIdentifier: target.bundleIdentifier,
            currentVersion: currentVersion,
            targetVersion: target.version.tag,
            configurationSchemaVersion: recoveryConfiguration.version,
            configurationBackupName: configurationBackupName,
            configurationSHA256: configurationDigest,
            activityBackupName: backedUpActivityURL == nil ? nil : activityBackupName,
            activitySHA256: activityDigest,
            activitySchemaVersion: activitySchema,
            applyEnabled: false
        )
        if fault == .beforeManifest {
            throw UpdateRecoverySnapshotFailure.injectedFailure
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let manifestData = try? encoder.encode(manifest) else {
            throw UpdateRecoverySnapshotFailure.manifestWriteFailed
        }
        do {
            try writeExclusivePrivate(
                manifestData,
                name: manifestName,
                directoryDescriptor: workspaceDescriptor
            )
        } catch {
            throw UpdateRecoverySnapshotFailure.manifestWriteFailed
        }
        guard Darwin.fsync(workspaceDescriptor) == 0,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw UpdateRecoverySnapshotFailure.synchronizeFailed
        }

        keepWorkspace = true
        return PreparedUpdateRecoverySnapshot(
            workspaceURL: workspaceURL,
            manifestURL: manifestURL,
            configurationBackupURL: configurationBackupURL,
            activityBackupURL: backedUpActivityURL,
            manifest: manifest
        )
    }

    private struct ActivityBackupResult {
        let digest: String
        let schemaVersion: Int32
    }

    private static func backupActivityDatabase(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> ActivityBackupResult {
        let sourceMetadata = try FileSystemSecurity.freshPOSIXMetadata(of: sourceURL)
        guard sourceMetadata.kind == .regularFile,
              sourceMetadata.size <= AgentActivityDatabase.maximumDatabaseBytes else {
            throw UpdateRecoverySnapshotFailure.unsafeActivityDatabase
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            if try FileSystemSecurity.pathEntryExists(sidecar) {
                let metadata = try FileSystemSecurity.freshPOSIXMetadata(of: sidecar)
                guard metadata.kind == .regularFile,
                      metadata.size <= AgentActivityDatabase.maximumDatabaseBytes else {
                    throw UpdateRecoverySnapshotFailure.unsafeActivityDatabase
                }
            }
        }

        let sourceSchema: Int32
        do {
            sourceSchema = try AgentActivityDatabase.createVerifiedBackup(
                from: sourceURL,
                to: destinationURL
            )
        } catch {
            throw UpdateRecoverySnapshotFailure.activityBackupFailed("sqlite-online-backup")
        }

        let data = try FileSystemSecurity.readRegularFile(
            destinationURL,
            maximumBytes: AgentActivityDatabase.maximumDatabaseBytes
        )
        return ActivityBackupResult(digest: sha256(data), schemaVersion: sourceSchema)
    }

    private static func createWorkspace(
        parentDescriptor: Int32,
        transactionID: String
    ) throws -> String {
        for attempt in 0..<maximumWorkspaceAttempts {
            let suffix = attempt == 0 ? transactionID : "\(transactionID)-\(attempt)"
            let name = workspacePrefix + suffix
            if name.withCString({ Darwin.mkdirat(parentDescriptor, $0, 0o700) }) == 0 {
                guard Darwin.fsync(parentDescriptor) == 0 else {
                    cleanupWorkspace(parentDescriptor: parentDescriptor, workspaceName: name)
                    throw UpdateRecoverySnapshotFailure.synchronizeFailed
                }
                return name
            }
            if errno != EEXIST {
                throw UpdateRecoverySnapshotFailure.snapshotCreationFailed
            }
        }
        throw UpdateRecoverySnapshotFailure.snapshotCreationFailed
    }

    private static func validateOwnedPrivateDirectory(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return Darwin.fstat(descriptor, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == Darwin.geteuid()
            && (metadata.st_mode & 0o777) == 0o700
    }

    private static func writeExclusivePrivate(
        _ data: Data,
        name: String,
        directoryDescriptor: Int32
    ) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw UpdateRecoverySnapshotFailure.snapshotCreationFailed
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw UpdateRecoverySnapshotFailure.snapshotCreationFailed
        }
        defer { _ = Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw UpdateRecoverySnapshotFailure.snapshotCreationFailed
                    }
                    offset += written
                }
            }
        } catch {
            _ = name.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
            }
            throw error
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw UpdateRecoverySnapshotFailure.synchronizeFailed
        }
    }

    private static func encodeConfiguration(_ configuration: StewardConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(configuration),
              UInt64(data.count) <= ConfigurationIO.maximumConfigurationBytes else {
            throw UpdateRecoverySnapshotFailure.configurationBackupFailed
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeVersionText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46
        }
    }

    private static func cleanupWorkspace(parentDescriptor: Int32, workspaceName: String) {
        let workspaceDescriptor = workspaceName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        if workspaceDescriptor >= 0 {
            for name in [
                configurationBackupName,
                activityBackupName,
                activityBackupName + "-journal",
                activityBackupName + "-wal",
                activityBackupName + "-shm",
                manifestName
            ] {
                _ = name.withCString {
                    Darwin.unlinkat(workspaceDescriptor, $0, 0) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
                }
            }
            _ = Darwin.close(workspaceDescriptor)
        }
        _ = workspaceName.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
        }
    }
}
