import CryptoKit
import Darwin
import Foundation
import TidyDropUpdateInspection
import TidyDropUpdateSecurity

public enum CurrentBundleRetentionFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unsafeWorkspace
    case snapshotManifestMissing
    case sourceBundleRejected
    case copyFailed
    case sourceChanged
    case retainedBundleRejected(UpdateBundleInspectionFailure)
    case retainedBundleMismatch
    case journalInvalid
    case journalTransitionRejected
    case journalWriteFailed
    case synchronizeFailed
    case injectedFailure
}

@_spi(Testing)
public enum CurrentBundleRetentionFault: Equatable, Sendable {
    case none
    case afterDestinationCreation
    case duringBundleCopy
    case beforeJournalPublication
    case afterNextJournalSynchronization
}

public enum ExternalRecoveryState: String, Codable, Equatable, Sendable {
    case prepared
    case replacementStarted = "replacement_started"
    case newBundleInstalled = "new_bundle_installed"
    case validationSucceeded = "validation_succeeded"
    case rollbackStarted = "rollback_started"
    case rolledBack = "rolled_back"
    case stateRestorationStarted = "state_restoration_started"
    case configurationRestored = "configuration_restored"
    case stateRestored = "state_restored"
    case committed
}

public struct ExternalRecoveryJournal: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let transactionID: String
    public let sequence: Int
    public let state: ExternalRecoveryState
    public let updatedAt: String
    public let bundleIdentifier: String
    public let currentVersion: String
    public let targetVersion: String
    public let retainedBundleName: String
    public let retainedBundleTreeSHA256: String
    public let retainedBundleEntryCount: Int
    public let retainedBundleBytes: UInt64
    public let stateSnapshotManifestName: String
    public let stateSnapshotManifestSHA256: String
    public let applyEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case transactionID = "transaction_id"
        case sequence
        case state
        case updatedAt = "updated_at"
        case bundleIdentifier = "bundle_identifier"
        case currentVersion = "current_version"
        case targetVersion = "target_version"
        case retainedBundleName = "retained_bundle_name"
        case retainedBundleTreeSHA256 = "retained_bundle_tree_sha256"
        case retainedBundleEntryCount = "retained_bundle_entry_count"
        case retainedBundleBytes = "retained_bundle_bytes"
        case stateSnapshotManifestName = "state_snapshot_manifest_name"
        case stateSnapshotManifestSHA256 = "state_snapshot_manifest_sha256"
        case applyEnabled = "apply_enabled"
    }
}

public struct PreparedExternalRecoveryTransaction: Equatable, Sendable {
    public let workspaceURL: URL
    public let retainedBundleURL: URL
    public let journalURL: URL
    public let journal: ExternalRecoveryJournal

    public var locator: ExternalRecoveryTransactionLocator {
        ExternalRecoveryTransactionLocator(
            workspaceURL: workspaceURL,
            transactionID: journal.transactionID
        )
    }
}

public struct ExternalRecoveryTransactionLocator: Equatable, Sendable {
    public let workspaceURL: URL
    public let transactionID: String

    public init(workspaceURL: URL, transactionID: String) {
        self.workspaceURL = workspaceURL
        self.transactionID = transactionID
    }
}

/// Retains an already-verified current bundle inside the private state-snapshot
/// workspace and publishes a durable recovery journal. This non-shipping type
/// never replaces, launches, registers, or removes an installed application.
public enum CurrentBundleRetentionBuilder {
    private static let retainedBundleName = "TidyDrop.app"
    private static let snapshotManifestName = "recovery-manifest.json"
    private static let journalName = "external-recovery-journal.json"
    private static let nextJournalName = "external-recovery-journal.next"
    private static let maximumJournalBytes = 128 * 1_024

    public static func prepare(
        snapshot: PreparedUpdateRecoverySnapshot,
        currentBundleURL: URL,
        currentBundlePolicy: ExistingBundleInspectionPolicy,
        authenticatedTarget: AuthenticatedReleaseManifest
    ) throws -> PreparedExternalRecoveryTransaction {
        try prepare(
            snapshot: snapshot,
            currentBundleURL: currentBundleURL,
            currentBundlePolicy: currentBundlePolicy,
            authenticatedTarget: authenticatedTarget,
            fault: .none
        )
    }

    @_spi(Testing)
    public static func prepare(
        snapshot: PreparedUpdateRecoverySnapshot,
        currentBundleURL: URL,
        currentBundlePolicy: ExistingBundleInspectionPolicy,
        authenticatedTarget: AuthenticatedReleaseManifest,
        fault: CurrentBundleRetentionFault
    ) throws -> PreparedExternalRecoveryTransaction {
        let target = authenticatedTarget.manifest
        guard snapshot.workspaceURL.isFileURL,
              currentBundleURL.isFileURL,
              currentBundleURL.lastPathComponent == "TidyDrop.app",
              snapshot.manifest.bundleIdentifier == target.bundleIdentifier,
              snapshot.manifest.targetVersion == target.version.tag,
              snapshot.manifest.currentVersion == currentBundlePolicy.marketingVersion,
              snapshot.manifest.applyEnabled == false,
              currentBundlePolicy.bundleIdentifier == target.bundleIdentifier else {
            throw CurrentBundleRetentionFailure.invalidRequest
        }

        let workspaceDescriptor = try openPrivateWorkspace(snapshot.workspaceURL)
        defer { _ = Darwin.close(workspaceDescriptor) }
        let snapshotDigest = try digestExistingRegularFile(
            name: snapshotManifestName,
            directoryDescriptor: workspaceDescriptor,
            maximumBytes: maximumJournalBytes
        )
        guard snapshot.manifestURL.lastPathComponent == snapshotManifestName else {
            throw CurrentBundleRetentionFailure.snapshotManifestMissing
        }

        let sourceInspection: InspectedUpdateBundle
        do {
            sourceInspection = try SafeUpdateBundleInspector.inspectExistingBundle(
                at: currentBundleURL,
                policy: currentBundlePolicy
            )
        } catch {
            throw CurrentBundleRetentionFailure.sourceBundleRejected
        }

        let sourceDescriptor = currentBundleURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            throw CurrentBundleRetentionFailure.sourceBundleRejected
        }
        defer { _ = Darwin.close(sourceDescriptor) }
        var sourceMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw CurrentBundleRetentionFailure.sourceBundleRejected
        }

        guard entryIsAbsent(retainedBundleName, directoryDescriptor: workspaceDescriptor),
              entryIsAbsent(journalName, directoryDescriptor: workspaceDescriptor),
              entryIsAbsent(nextJournalName, directoryDescriptor: workspaceDescriptor) else {
            throw CurrentBundleRetentionFailure.invalidRequest
        }
        let destinationResult = retainedBundleName.withCString {
            Darwin.mkdirat(workspaceDescriptor, $0, 0o700)
        }
        guard destinationResult == 0 else {
            throw CurrentBundleRetentionFailure.copyFailed
        }
        var keepBundle = false
        defer {
            if !keepBundle {
                cleanupPublishedArtifacts(workspaceDescriptor: workspaceDescriptor)
            }
        }
        if fault == .afterDestinationCreation {
            throw CurrentBundleRetentionFailure.injectedFailure
        }

        let destinationDescriptor = retainedBundleName.withCString {
            Darwin.openat(
                workspaceDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard destinationDescriptor >= 0 else {
            throw CurrentBundleRetentionFailure.copyFailed
        }
        defer { _ = Darwin.close(destinationDescriptor) }

        var copyContext = BundleCopyContext(
            rootDevice: sourceMetadata.st_dev,
            maximumEntries: currentBundlePolicy.maximumEntries,
            maximumBytes: currentBundlePolicy.maximumUncompressedBytes,
            fault: fault
        )
        do {
            try copyDirectory(
                sourceDescriptor: sourceDescriptor,
                destinationDescriptor: destinationDescriptor,
                depth: 0,
                context: &copyContext
            )
        } catch let failure as CurrentBundleRetentionFailure {
            throw failure
        } catch {
            throw CurrentBundleRetentionFailure.copyFailed
        }
        guard Darwin.fsync(destinationDescriptor) == 0,
              Darwin.fsync(workspaceDescriptor) == 0 else {
            throw CurrentBundleRetentionFailure.synchronizeFailed
        }

        var sourceAfter = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceAfter) == 0,
              sameStableDirectory(sourceMetadata, sourceAfter) else {
            throw CurrentBundleRetentionFailure.sourceChanged
        }

        let sourceInspectionAfterCopy: InspectedUpdateBundle
        do {
            sourceInspectionAfterCopy = try SafeUpdateBundleInspector.inspectExistingBundle(
                at: currentBundleURL,
                policy: currentBundlePolicy
            )
        } catch {
            throw CurrentBundleRetentionFailure.sourceChanged
        }
        guard sourceInspectionAfterCopy == sourceInspection else {
            throw CurrentBundleRetentionFailure.sourceChanged
        }

        let retainedBundleURL = snapshot.workspaceURL.appendingPathComponent(
            retainedBundleName,
            isDirectory: true
        )
        let retainedInspection: InspectedUpdateBundle
        do {
            retainedInspection = try SafeUpdateBundleInspector.inspectExistingBundle(
                at: retainedBundleURL,
                policy: currentBundlePolicy
            )
        } catch let failure as UpdateBundleInspectionFailure {
            throw CurrentBundleRetentionFailure.retainedBundleRejected(failure)
        } catch {
            throw CurrentBundleRetentionFailure.retainedBundleRejected(.unsafeBundleEntry)
        }
        guard retainedInspection == sourceInspection,
              retainedInspection.entryCount == copyContext.entryCount,
              retainedInspection.uncompressedRegularBytes == copyContext.regularBytes else {
            throw CurrentBundleRetentionFailure.retainedBundleMismatch
        }
        let retainedTree = try digestBundleTree(
            descriptor: destinationDescriptor,
            rootDevice: destinationDevice(destinationDescriptor),
            maximumEntries: currentBundlePolicy.maximumEntries,
            maximumBytes: currentBundlePolicy.maximumUncompressedBytes
        )
        guard retainedTree.entryCount == retainedInspection.entryCount,
              retainedTree.regularBytes == retainedInspection.uncompressedRegularBytes else {
            throw CurrentBundleRetentionFailure.retainedBundleMismatch
        }
        if fault == .beforeJournalPublication {
            throw CurrentBundleRetentionFailure.injectedFailure
        }

        let journal = ExternalRecoveryJournal(
            formatVersion: 1,
            transactionID: snapshot.manifest.transactionID,
            sequence: 0,
            state: .prepared,
            updatedAt: timestamp(),
            bundleIdentifier: target.bundleIdentifier,
            currentVersion: currentBundlePolicy.marketingVersion,
            targetVersion: target.version.tag,
            retainedBundleName: retainedBundleName,
            retainedBundleTreeSHA256: retainedTree.digest,
            retainedBundleEntryCount: retainedInspection.entryCount,
            retainedBundleBytes: retainedInspection.uncompressedRegularBytes,
            stateSnapshotManifestName: snapshotManifestName,
            stateSnapshotManifestSHA256: snapshotDigest,
            applyEnabled: false
        )
        try writeJournalExclusive(
            journal,
            name: journalName,
            directoryDescriptor: workspaceDescriptor
        )
        guard Darwin.fsync(workspaceDescriptor) == 0 else {
            throw CurrentBundleRetentionFailure.synchronizeFailed
        }
        keepBundle = true
        return PreparedExternalRecoveryTransaction(
            workspaceURL: snapshot.workspaceURL,
            retainedBundleURL: retainedBundleURL,
            journalURL: snapshot.workspaceURL.appendingPathComponent(journalName),
            journal: journal
        )
    }

    public static func loadRecovering(
        transaction: PreparedExternalRecoveryTransaction
    ) throws -> ExternalRecoveryJournal {
        try loadRecovering(locator: transaction.locator)
    }

    public static func loadRecovering(
        locator: ExternalRecoveryTransactionLocator
    ) throws -> ExternalRecoveryJournal {
        let descriptor = try openPrivateWorkspace(locator.workspaceURL)
        defer { _ = Darwin.close(descriptor) }
        return try loadRecovering(
            directoryDescriptor: descriptor,
            expectedTransactionID: locator.transactionID
        )
    }

    public static func advance(
        transaction: PreparedExternalRecoveryTransaction,
        to newState: ExternalRecoveryState
    ) throws -> ExternalRecoveryJournal {
        try advance(locator: transaction.locator, to: newState, fault: .none)
    }

    public static func advance(
        locator: ExternalRecoveryTransactionLocator,
        to newState: ExternalRecoveryState
    ) throws -> ExternalRecoveryJournal {
        try advance(locator: locator, to: newState, fault: .none)
    }

    @_spi(Testing)
    public static func advance(
        transaction: PreparedExternalRecoveryTransaction,
        to newState: ExternalRecoveryState,
        fault: CurrentBundleRetentionFault
    ) throws -> ExternalRecoveryJournal {
        try advance(locator: transaction.locator, to: newState, fault: fault)
    }

    @_spi(Testing)
    public static func advance(
        locator: ExternalRecoveryTransactionLocator,
        to newState: ExternalRecoveryState,
        fault: CurrentBundleRetentionFault
    ) throws -> ExternalRecoveryJournal {
        let descriptor = try openPrivateWorkspace(locator.workspaceURL)
        defer { _ = Darwin.close(descriptor) }
        let current = try loadRecovering(
            directoryDescriptor: descriptor,
            expectedTransactionID: locator.transactionID
        )
        guard allowedTransition(from: current.state, to: newState) else {
            throw CurrentBundleRetentionFailure.journalTransitionRejected
        }
        let next = ExternalRecoveryJournal(
            formatVersion: current.formatVersion,
            transactionID: current.transactionID,
            sequence: current.sequence + 1,
            state: newState,
            updatedAt: timestamp(),
            bundleIdentifier: current.bundleIdentifier,
            currentVersion: current.currentVersion,
            targetVersion: current.targetVersion,
            retainedBundleName: current.retainedBundleName,
            retainedBundleTreeSHA256: current.retainedBundleTreeSHA256,
            retainedBundleEntryCount: current.retainedBundleEntryCount,
            retainedBundleBytes: current.retainedBundleBytes,
            stateSnapshotManifestName: current.stateSnapshotManifestName,
            stateSnapshotManifestSHA256: current.stateSnapshotManifestSHA256,
            applyEnabled: false
        )
        try writeJournalExclusive(
            next,
            name: nextJournalName,
            directoryDescriptor: descriptor
        )
        guard Darwin.fsync(descriptor) == 0 else {
            throw CurrentBundleRetentionFailure.synchronizeFailed
        }
        if fault == .afterNextJournalSynchronization {
            throw CurrentBundleRetentionFailure.injectedFailure
        }
        try publishNextJournal(directoryDescriptor: descriptor)
        return next
    }

    private struct BundleCopyContext {
        let rootDevice: dev_t
        let maximumEntries: Int
        let maximumBytes: UInt64
        let fault: CurrentBundleRetentionFault
        var entryCount = 0
        var regularBytes: UInt64 = 0
        var copiedRegularFiles = 0
        var visitedDirectories: Set<FileIdentity> = []
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func copyDirectory(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        depth: Int,
        context: inout BundleCopyContext
    ) throws {
        guard depth <= 32 else { throw CurrentBundleRetentionFailure.copyFailed }
        var directoryMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &directoryMetadata) == 0,
              (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_dev == context.rootDevice,
              directoryMetadata.st_mode & 0o022 == 0,
              directoryMetadata.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
            throw CurrentBundleRetentionFailure.copyFailed
        }
        let identity = FileIdentity(
            device: directoryMetadata.st_dev,
            inode: directoryMetadata.st_ino
        )
        guard context.visitedDirectories.insert(identity).inserted else {
            throw CurrentBundleRetentionFailure.copyFailed
        }

        for name in try directoryNames(descriptor: sourceDescriptor) {
            context.entryCount += 1
            guard context.entryCount <= context.maximumEntries else {
                throw CurrentBundleRetentionFailure.copyFailed
            }
            var before = stat()
            let status = name.withCString {
                Darwin.fstatat(sourceDescriptor, $0, &before, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0,
                  before.st_dev == context.rootDevice,
                  before.st_mode & 0o022 == 0,
                  before.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
                throw CurrentBundleRetentionFailure.copyFailed
            }
            switch before.st_mode & S_IFMT {
            case S_IFDIR:
                let mode = before.st_mode & 0o777
                guard name.withCString({ Darwin.mkdirat(destinationDescriptor, $0, mode) }) == 0 else {
                    throw CurrentBundleRetentionFailure.copyFailed
                }
                let sourceChild = name.withCString {
                    Darwin.openat(
                        sourceDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                let destinationChild = name.withCString {
                    Darwin.openat(
                        destinationDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard sourceChild >= 0, destinationChild >= 0 else {
                    if sourceChild >= 0 { _ = Darwin.close(sourceChild) }
                    if destinationChild >= 0 { _ = Darwin.close(destinationChild) }
                    throw CurrentBundleRetentionFailure.copyFailed
                }
                var openedSourceMetadata = stat()
                var openedDestinationMetadata = stat()
                guard Darwin.fstat(sourceChild, &openedSourceMetadata) == 0,
                      openedSourceMetadata.st_dev == before.st_dev,
                      openedSourceMetadata.st_ino == before.st_ino,
                      (openedSourceMetadata.st_mode & S_IFMT) == S_IFDIR,
                      Darwin.fstat(destinationChild, &openedDestinationMetadata) == 0,
                      (openedDestinationMetadata.st_mode & S_IFMT) == S_IFDIR,
                      Darwin.fchmod(destinationChild, mode) == 0 else {
                    _ = Darwin.close(sourceChild)
                    _ = Darwin.close(destinationChild)
                    throw CurrentBundleRetentionFailure.sourceChanged
                }
                defer {
                    _ = Darwin.close(sourceChild)
                    _ = Darwin.close(destinationChild)
                }
                try copyDirectory(
                    sourceDescriptor: sourceChild,
                    destinationDescriptor: destinationChild,
                    depth: depth + 1,
                    context: &context
                )
                guard Darwin.fsync(destinationChild) == 0 else {
                    throw CurrentBundleRetentionFailure.synchronizeFailed
                }
            case S_IFREG:
                guard before.st_nlink == 1, before.st_size >= 0 else {
                    throw CurrentBundleRetentionFailure.copyFailed
                }
                let (newTotal, overflow) = context.regularBytes.addingReportingOverflow(
                    UInt64(before.st_size)
                )
                guard !overflow, newTotal <= context.maximumBytes else {
                    throw CurrentBundleRetentionFailure.copyFailed
                }
                try copyRegularFile(
                    name: name,
                    sourceDescriptor: sourceDescriptor,
                    destinationDescriptor: destinationDescriptor,
                    expected: before
                )
                context.regularBytes = newTotal
                context.copiedRegularFiles += 1
                if context.fault == .duringBundleCopy, context.copiedRegularFiles == 1 {
                    throw CurrentBundleRetentionFailure.injectedFailure
                }
            default:
                throw CurrentBundleRetentionFailure.copyFailed
            }
        }
    }

    private static func copyRegularFile(
        name: String,
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        expected: stat
    ) throws {
        let source = name.withCString {
            Darwin.openat(sourceDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard source >= 0 else { throw CurrentBundleRetentionFailure.copyFailed }
        defer { _ = Darwin.close(source) }
        let destination = name.withCString {
            Darwin.openat(
                destinationDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard destination >= 0 else { throw CurrentBundleRetentionFailure.copyFailed }
        defer { _ = Darwin.close(destination) }
        guard Darwin.fcopyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ALL)) == 0,
              Darwin.fsync(destination) == 0 else {
            throw CurrentBundleRetentionFailure.copyFailed
        }
        var after = stat()
        guard Darwin.fstat(source, &after) == 0,
              sameStableFile(expected, after) else {
            throw CurrentBundleRetentionFailure.sourceChanged
        }
    }

    private struct BundleTreeDigest {
        let digest: String
        let entryCount: Int
        let regularBytes: UInt64
    }

    private static func digestBundleTree(
        descriptor: Int32,
        rootDevice: dev_t,
        maximumEntries: Int,
        maximumBytes: UInt64
    ) throws -> BundleTreeDigest {
        var hasher = SHA256()
        var entryCount = 0
        var bytes: UInt64 = 0
        var visited: Set<FileIdentity> = []
        try digestDirectory(
            descriptor: descriptor,
            relativePath: "",
            rootDevice: rootDevice,
            maximumEntries: maximumEntries,
            maximumBytes: maximumBytes,
            entryCount: &entryCount,
            bytes: &bytes,
            visited: &visited,
            hasher: &hasher
        )
        return BundleTreeDigest(
            digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            entryCount: entryCount,
            regularBytes: bytes
        )
    }

    private static func destinationDevice(_ descriptor: Int32) throws -> dev_t {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw CurrentBundleRetentionFailure.retainedBundleMismatch
        }
        return metadata.st_dev
    }

    private static func digestDirectory(
        descriptor: Int32,
        relativePath: String,
        rootDevice: dev_t,
        maximumEntries: Int,
        maximumBytes: UInt64,
        entryCount: inout Int,
        bytes: inout UInt64,
        visited: inout Set<FileIdentity>,
        hasher: inout SHA256
    ) throws {
        var directoryMetadata = stat()
        guard Darwin.fstat(descriptor, &directoryMetadata) == 0,
              (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_dev == rootDevice else {
            throw CurrentBundleRetentionFailure.retainedBundleMismatch
        }
        let identity = FileIdentity(device: directoryMetadata.st_dev, inode: directoryMetadata.st_ino)
        guard visited.insert(identity).inserted else {
            throw CurrentBundleRetentionFailure.retainedBundleMismatch
        }
        for name in try directoryNames(descriptor: descriptor) {
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw CurrentBundleRetentionFailure.retainedBundleMismatch
            }
            let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var metadata = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }) == 0, metadata.st_dev == rootDevice else {
                throw CurrentBundleRetentionFailure.retainedBundleMismatch
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                updateHasher(&hasher, text: "D\u{0}\(path)\u{0}\(metadata.st_mode & 0o777)\n")
                let child = name.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard child >= 0 else {
                    throw CurrentBundleRetentionFailure.retainedBundleMismatch
                }
                defer { _ = Darwin.close(child) }
                try digestDirectory(
                    descriptor: child,
                    relativePath: path,
                    rootDevice: rootDevice,
                    maximumEntries: maximumEntries,
                    maximumBytes: maximumBytes,
                    entryCount: &entryCount,
                    bytes: &bytes,
                    visited: &visited,
                    hasher: &hasher
                )
            case S_IFREG:
                guard metadata.st_nlink == 1, metadata.st_size >= 0 else {
                    throw CurrentBundleRetentionFailure.retainedBundleMismatch
                }
                let (newTotal, overflow) = bytes.addingReportingOverflow(UInt64(metadata.st_size))
                guard !overflow, newTotal <= maximumBytes else {
                    throw CurrentBundleRetentionFailure.retainedBundleMismatch
                }
                bytes = newTotal
                updateHasher(
                    &hasher,
                    text: "F\u{0}\(path)\u{0}\(metadata.st_mode & 0o777)\u{0}\(metadata.st_size)\n"
                )
                let file = name.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard file >= 0 else {
                    throw CurrentBundleRetentionFailure.retainedBundleMismatch
                }
                defer { _ = Darwin.close(file) }
                try hashFile(descriptor: file, expectedBytes: UInt64(metadata.st_size), hasher: &hasher)
            default:
                throw CurrentBundleRetentionFailure.retainedBundleMismatch
            }
        }
    }

    private static func hashFile(
        descriptor: Int32,
        expectedBytes: UInt64,
        hasher: inout SHA256
    ) throws {
        var offset: off_t = 0
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, $0.count, offset)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CurrentBundleRetentionFailure.retainedBundleMismatch
            }
            total += UInt64(count)
            guard total <= expectedBytes else {
                throw CurrentBundleRetentionFailure.retainedBundleMismatch
            }
            buffer.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count)))
            }
            offset += off_t(count)
        }
        guard total == expectedBytes else {
            throw CurrentBundleRetentionFailure.retainedBundleMismatch
        }
    }

    private static func updateHasher(_ hasher: inout SHA256, text: String) {
        hasher.update(data: Data(text.utf8))
    }

    private static func loadRecovering(
        directoryDescriptor: Int32,
        expectedTransactionID: String
    ) throws -> ExternalRecoveryJournal {
        let current = try readJournal(
            name: journalName,
            directoryDescriptor: directoryDescriptor
        )
        guard validJournal(current, expectedTransactionID: expectedTransactionID) else {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
        var nextMetadata = stat()
        let nextStatus = nextJournalName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &nextMetadata, AT_SYMLINK_NOFOLLOW)
        }
        if nextStatus != 0 {
            guard errno == ENOENT else {
                throw CurrentBundleRetentionFailure.journalInvalid
            }
            try validatePublishedArtifacts(current, directoryDescriptor: directoryDescriptor)
            return current
        }
        let next = try readJournal(
            name: nextJournalName,
            directoryDescriptor: directoryDescriptor
        )
        guard validJournal(next, expectedTransactionID: expectedTransactionID),
              next.sequence == current.sequence + 1,
              journalsShareImmutableFields(current, next),
              allowedTransition(from: current.state, to: next.state) else {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
        try publishNextJournal(directoryDescriptor: directoryDescriptor)
        try validatePublishedArtifacts(next, directoryDescriptor: directoryDescriptor)
        return next
    }

    private static func validatePublishedArtifacts(
        _ journal: ExternalRecoveryJournal,
        directoryDescriptor: Int32
    ) throws {
        do {
            try validatePublishedArtifactsUnchecked(
                journal,
                directoryDescriptor: directoryDescriptor
            )
        } catch {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
    }

    private static func validatePublishedArtifactsUnchecked(
        _ journal: ExternalRecoveryJournal,
        directoryDescriptor: Int32
    ) throws {
        let snapshotDigest = try digestExistingRegularFile(
            name: journal.stateSnapshotManifestName,
            directoryDescriptor: directoryDescriptor,
            maximumBytes: maximumJournalBytes
        )
        guard snapshotDigest == journal.stateSnapshotManifestSHA256 else {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
        let retainedDescriptor = journal.retainedBundleName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard retainedDescriptor >= 0 else {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
        defer { _ = Darwin.close(retainedDescriptor) }
        let tree = try digestBundleTree(
            descriptor: retainedDescriptor,
            rootDevice: destinationDevice(retainedDescriptor),
            maximumEntries: journal.retainedBundleEntryCount,
            maximumBytes: journal.retainedBundleBytes
        )
        guard tree.digest == journal.retainedBundleTreeSHA256,
              tree.entryCount == journal.retainedBundleEntryCount,
              tree.regularBytes == journal.retainedBundleBytes else {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
    }

    private static func publishNextJournal(directoryDescriptor: Int32) throws {
        let result = nextJournalName.withCString { nextName in
            journalName.withCString { currentName in
                Darwin.renameat(
                    directoryDescriptor,
                    nextName,
                    directoryDescriptor,
                    currentName
                ) // APP_OWNED_RECOVERY_JOURNAL_RENAME
            }
        }
        guard result == 0, Darwin.fsync(directoryDescriptor) == 0 else {
            throw CurrentBundleRetentionFailure.journalWriteFailed
        }
    }

    private static func readJournal(
        name: String,
        directoryDescriptor: Int32
    ) throws -> ExternalRecoveryJournal {
        let descriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw CurrentBundleRetentionFailure.journalInvalid }
        defer { _ = Darwin.close(descriptor) }
        let data = try readBoundedRegularFile(
            descriptor: descriptor,
            maximumBytes: maximumJournalBytes
        )
        do {
            return try JSONDecoder().decode(ExternalRecoveryJournal.self, from: data)
        } catch {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
    }

    private static func writeJournalExclusive(
        _ journal: ExternalRecoveryJournal,
        name: String,
        directoryDescriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(journal), data.count <= maximumJournalBytes else {
            throw CurrentBundleRetentionFailure.journalWriteFailed
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else { throw CurrentBundleRetentionFailure.journalWriteFailed }
        defer { _ = Darwin.close(descriptor) }
        do {
            try writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw CurrentBundleRetentionFailure.synchronizeFailed
            }
        } catch {
            _ = name.withCString {
                Darwin.unlinkat(
                    directoryDescriptor,
                    $0,
                    0
                ) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
            }
            throw error
        }
    }

    private static func allowedTransition(
        from current: ExternalRecoveryState,
        to next: ExternalRecoveryState
    ) -> Bool {
        switch (current, next) {
        case (.prepared, .replacementStarted),
             (.replacementStarted, .newBundleInstalled),
             (.replacementStarted, .rollbackStarted),
             (.newBundleInstalled, .validationSucceeded),
             (.newBundleInstalled, .rollbackStarted),
             (.validationSucceeded, .committed),
             (.rollbackStarted, .rolledBack),
             (.rolledBack, .stateRestorationStarted),
             (.stateRestorationStarted, .configurationRestored),
             (.configurationRestored, .stateRestored),
             (.stateRestored, .committed),
             (.rolledBack, .committed):
            return true
        default:
            return false
        }
    }

    private static func validJournal(
        _ journal: ExternalRecoveryJournal,
        expectedTransactionID: String
    ) -> Bool {
        journal.formatVersion == 1
            && journal.transactionID == expectedTransactionID
            && journal.sequence >= 0
            && journal.bundleIdentifier == "io.github.bugroo.tidydrop"
            && !journal.currentVersion.isEmpty
            && !journal.targetVersion.isEmpty
            && journal.retainedBundleName == retainedBundleName
            && journal.retainedBundleTreeSHA256.utf8.count == 64
            && journal.retainedBundleEntryCount > 0
            && journal.retainedBundleBytes > 0
            && journal.stateSnapshotManifestName == snapshotManifestName
            && journal.stateSnapshotManifestSHA256.utf8.count == 64
            && journal.applyEnabled == false
    }

    private static func journalsShareImmutableFields(
        _ lhs: ExternalRecoveryJournal,
        _ rhs: ExternalRecoveryJournal
    ) -> Bool {
        lhs.formatVersion == rhs.formatVersion
            && lhs.transactionID == rhs.transactionID
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.currentVersion == rhs.currentVersion
            && lhs.targetVersion == rhs.targetVersion
            && lhs.retainedBundleName == rhs.retainedBundleName
            && lhs.retainedBundleTreeSHA256 == rhs.retainedBundleTreeSHA256
            && lhs.retainedBundleEntryCount == rhs.retainedBundleEntryCount
            && lhs.retainedBundleBytes == rhs.retainedBundleBytes
            && lhs.stateSnapshotManifestName == rhs.stateSnapshotManifestName
            && lhs.stateSnapshotManifestSHA256 == rhs.stateSnapshotManifestSHA256
            && lhs.applyEnabled == rhs.applyEnabled
    }

    private static func openPrivateWorkspace(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw CurrentBundleRetentionFailure.unsafeWorkspace }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            _ = Darwin.close(descriptor)
            throw CurrentBundleRetentionFailure.unsafeWorkspace
        }
        return descriptor
    }

    private static func digestExistingRegularFile(
        name: String,
        directoryDescriptor: Int32,
        maximumBytes: Int
    ) throws -> String {
        let descriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CurrentBundleRetentionFailure.snapshotManifestMissing
        }
        defer { _ = Darwin.close(descriptor) }
        let data = try readBoundedRegularFile(descriptor: descriptor, maximumBytes: maximumBytes)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readBoundedRegularFile(
        descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes,
              metadata.st_mode & 0o077 == 0 else {
            throw CurrentBundleRetentionFailure.journalInvalid
        }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes {
            Darwin.pread(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard count == data.count else { throw CurrentBundleRetentionFailure.journalInvalid }
        return data
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CurrentBundleRetentionFailure.journalWriteFailed }
                offset += count
            }
        }
    }

    private static func directoryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw CurrentBundleRetentionFailure.copyFailed
        }
        defer { _ = Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let candidate = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name = candidate else {
                throw CurrentBundleRetentionFailure.copyFailed
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), name.utf8.count <= Int(MAXNAMLEN) else {
                throw CurrentBundleRetentionFailure.copyFailed
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func cleanupPublishedArtifacts(workspaceDescriptor: Int32) {
        _ = nextJournalName.withCString {
            Darwin.unlinkat(workspaceDescriptor, $0, 0) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
        }
        _ = journalName.withCString {
            Darwin.unlinkat(workspaceDescriptor, $0, 0) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
        }
        removeDirectoryTree(
            parentDescriptor: workspaceDescriptor,
            name: retainedBundleName
        )
    }

    private static func entryIsAbsent(_ name: String, directoryDescriptor: Int32) -> Bool {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result != 0 && errno == ENOENT
    }

    private static func removeDirectoryTree(parentDescriptor: Int32, name: String) {
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor >= 0 {
            if let names = try? directoryNames(descriptor: descriptor) {
                for childName in names {
                    var metadata = stat()
                    let status = childName.withCString {
                        Darwin.fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                    }
                    if status == 0, (metadata.st_mode & S_IFMT) == S_IFDIR {
                        removeDirectoryTree(parentDescriptor: descriptor, name: childName)
                    } else {
                        _ = childName.withCString {
                            Darwin.unlinkat(
                                descriptor,
                                $0,
                                0
                            ) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
                        }
                    }
                }
            }
            _ = Darwin.close(descriptor)
        }
        _ = name.withCString {
            Darwin.unlinkat(
                parentDescriptor,
                $0,
                AT_REMOVEDIR
            ) // APP_OWNED_UPDATE_RECOVERY_CLEANUP
        }
    }

    private static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func sameStableDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
