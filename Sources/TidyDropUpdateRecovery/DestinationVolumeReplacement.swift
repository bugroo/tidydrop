import Darwin
import Foundation
import TidyDropUpdateInspection

public enum DestinationVolumeReplacementFailure: Error, Equatable, Sendable {
    case invalidRequest
    case nonShippingScopeRequired
    case unsafeDestinationParent
    case unsafeBundleEntry
    case journalStateRejected
    case bundleInspectionFailed
    case bundlePairMismatch
    case atomicSwapUnsupported
    case atomicSwapFailed(Int32)
    case synchronizeFailed
    case injectedFailure
}

@_spi(Testing)
public enum DestinationVolumeReplacementFault: Equatable, Sendable {
    case none
    case afterReplacementStarted
    case afterInstallSwap
    case afterRollbackStarted
    case afterRollbackSwap
}

@_spi(Testing)
public enum DestinationVolumeReplacementCheckpoint: String, CaseIterable, Sendable {
    case replacementStarted = "replacement_started"
    case installSwapSynchronized = "install_swap_synchronized"
    case rollbackStarted = "rollback_started"
    case rollbackSwapSynchronized = "rollback_swap_synchronized"

    public var markerFileName: String {
        ".tidydrop-recovery-checkpoint-\(rawValue)"
    }
}

public enum DestinationVolumeReplacementOutcome: Equatable, Sendable {
    case prepared
    case newBundleInstalled
    case rolledBack
}

/// Non-shipping atomic replacement protocol.
///
/// The current implementation is deliberately restricted to private
/// `TidyDropIntegration.*` directories below `/private/tmp`. It proves the
/// descriptor-relative swap and recovery state machine without acquiring any
/// authority over an installed application. Product activation remains
/// blocked by ADR-0020 and ADR-0021.
public enum DestinationVolumeReplacementProtocol {
    private static let installedBundleName = "TidyDrop.app"
    private static let integrationRootPrefix = "/private/tmp/TidyDropIntegration."
    private static let exactSigningRequirement = "identifier \"io.github.bugroo.tidydrop\""
    // Both operands are fixed single-component names relative to already-open
    // no-follow directory descriptors. RENAME_RESOLVE_BENEATH is intentionally
    // not used because the macOS 15 SDK does not expose it; no operand can
    // contain a path separator or traverse above either descriptor.
    private static let renameFlags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)

    public static func candidateContainerName(transactionID: String) throws -> String {
        guard validTransactionID(transactionID) else {
            throw DestinationVolumeReplacementFailure.invalidRequest
        }
        return ".tidydrop-replacement-\(transactionID)"
    }

    public static func install(
        locator: ExternalRecoveryTransactionLocator,
        destinationParentURL: URL
    ) throws -> DestinationVolumeReplacementOutcome {
        try install(
            locator: locator,
            destinationParentURL: destinationParentURL,
            fault: .none
        )
    }

    @_spi(Testing)
    public static func install(
        locator: ExternalRecoveryTransactionLocator,
        destinationParentURL: URL,
        fault: DestinationVolumeReplacementFault,
        checkpointHandler: ((DestinationVolumeReplacementCheckpoint) throws -> Void)? = nil
    ) throws -> DestinationVolumeReplacementOutcome {
        let journal = try CurrentBundleRetentionBuilder.loadRecovering(locator: locator)
        guard journal.state == .prepared else {
            throw DestinationVolumeReplacementFailure.journalStateRejected
        }
        let context = try ReplacementContext(
            locator: locator,
            journal: journal,
            destinationParentURL: destinationParentURL
        )
        _ = try context.verifyPair(expected: .currentThenTarget)
        _ = try CurrentBundleRetentionBuilder.advance(
            locator: locator,
            to: .replacementStarted
        )
        try checkpointHandler?(.replacementStarted)
        if fault == .afterReplacementStarted {
            throw DestinationVolumeReplacementFailure.injectedFailure
        }
        return try continueInstall(
            context: context,
            fault: fault,
            checkpointHandler: checkpointHandler
        )
    }

    public static func rollback(
        locator: ExternalRecoveryTransactionLocator,
        destinationParentURL: URL
    ) throws -> DestinationVolumeReplacementOutcome {
        try rollback(
            locator: locator,
            destinationParentURL: destinationParentURL,
            fault: .none
        )
    }

    @_spi(Testing)
    public static func rollback(
        locator: ExternalRecoveryTransactionLocator,
        destinationParentURL: URL,
        fault: DestinationVolumeReplacementFault,
        checkpointHandler: ((DestinationVolumeReplacementCheckpoint) throws -> Void)? = nil
    ) throws -> DestinationVolumeReplacementOutcome {
        let journal = try CurrentBundleRetentionBuilder.loadRecovering(locator: locator)
        guard journal.state == .newBundleInstalled || journal.state == .validationSucceeded else {
            throw DestinationVolumeReplacementFailure.journalStateRejected
        }
        let context = try ReplacementContext(
            locator: locator,
            journal: journal,
            destinationParentURL: destinationParentURL
        )
        _ = try context.verifyPair(expected: .targetThenCurrent)
        _ = try CurrentBundleRetentionBuilder.advance(locator: locator, to: .rollbackStarted)
        try checkpointHandler?(.rollbackStarted)
        if fault == .afterRollbackStarted {
            throw DestinationVolumeReplacementFailure.injectedFailure
        }
        return try continueRollback(
            context: context,
            fault: fault,
            checkpointHandler: checkpointHandler
        )
    }

    /// Reconciles an interrupted swap from the durable journal plus the two
    /// signed bundle identities. It never guesses if the pair is ambiguous.
    public static func recover(
        locator: ExternalRecoveryTransactionLocator,
        destinationParentURL: URL
    ) throws -> DestinationVolumeReplacementOutcome {
        let journal = try CurrentBundleRetentionBuilder.loadRecovering(locator: locator)
        let context = try ReplacementContext(
            locator: locator,
            journal: journal,
            destinationParentURL: destinationParentURL
        )
        switch journal.state {
        case .prepared:
            _ = try context.verifyPair(expected: .currentThenTarget)
            return .prepared
        case .replacementStarted:
            return try continueInstall(context: context, fault: .none)
        case .newBundleInstalled, .validationSucceeded:
            _ = try context.verifyPair(expected: .targetThenCurrent)
            return .newBundleInstalled
        case .rollbackStarted:
            return try continueRollback(context: context, fault: .none)
        case .rolledBack, .stateRestorationStarted, .configurationRestored, .stateRestored:
            _ = try context.verifyPair(expected: .currentThenTarget)
            return .rolledBack
        case .committed:
            if context.matchesPair(.targetThenCurrent) {
                return .newBundleInstalled
            }
            if context.matchesPair(.currentThenTarget) {
                return .rolledBack
            }
            throw DestinationVolumeReplacementFailure.bundlePairMismatch
        }
    }

    private static func continueInstall(
        context: ReplacementContext,
        fault: DestinationVolumeReplacementFault,
        checkpointHandler: ((DestinationVolumeReplacementCheckpoint) throws -> Void)? = nil
    ) throws -> DestinationVolumeReplacementOutcome {
        if let identities = try? context.verifyPair(expected: .currentThenTarget) {
            try context.atomicSwap(expected: identities)
            try checkpointHandler?(.installSwapSynchronized)
            if fault == .afterInstallSwap {
                throw DestinationVolumeReplacementFailure.injectedFailure
            }
        } else {
            guard context.matchesPair(.targetThenCurrent) else {
                throw DestinationVolumeReplacementFailure.bundlePairMismatch
            }
            try context.synchronizeDirectories()
        }
        _ = try context.verifyPair(expected: .targetThenCurrent)
        _ = try CurrentBundleRetentionBuilder.advance(
            locator: context.locator,
            to: .newBundleInstalled
        )
        return .newBundleInstalled
    }

    private static func continueRollback(
        context: ReplacementContext,
        fault: DestinationVolumeReplacementFault,
        checkpointHandler: ((DestinationVolumeReplacementCheckpoint) throws -> Void)? = nil
    ) throws -> DestinationVolumeReplacementOutcome {
        if let identities = try? context.verifyPair(expected: .targetThenCurrent) {
            try context.atomicSwap(expected: identities)
            try checkpointHandler?(.rollbackSwapSynchronized)
            if fault == .afterRollbackSwap {
                throw DestinationVolumeReplacementFailure.injectedFailure
            }
        } else {
            guard context.matchesPair(.currentThenTarget) else {
                throw DestinationVolumeReplacementFailure.bundlePairMismatch
            }
            try context.synchronizeDirectories()
        }
        _ = try context.verifyPair(expected: .currentThenTarget)
        _ = try CurrentBundleRetentionBuilder.advance(
            locator: context.locator,
            to: .rolledBack
        )
        return .rolledBack
    }

    private enum ExpectedPair: Equatable {
        case currentThenTarget
        case targetThenCurrent
    }

    private struct EntryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct PairIdentity: Equatable {
        let installed: EntryIdentity
        let candidate: EntryIdentity
    }

    private final class ReplacementContext {
        let locator: ExternalRecoveryTransactionLocator
        let journal: ExternalRecoveryJournal
        let parentDescriptor: Int32
        let candidateParentDescriptor: Int32
        let candidateContainerName: String
        let candidateContainerIdentity: EntryIdentity
        let installedURL: URL
        let candidateURL: URL
        let currentPolicy: ExistingBundleInspectionPolicy
        let targetPolicy: ExistingBundleInspectionPolicy

        init(
            locator: ExternalRecoveryTransactionLocator,
            journal: ExternalRecoveryJournal,
            destinationParentURL: URL
        ) throws {
            guard locator.transactionID == journal.transactionID,
                  journal.bundleIdentifier == "io.github.bugroo.tidydrop",
                  journal.applyEnabled == false,
                  validTransactionID(journal.transactionID),
                  validVersion(journal.currentVersion),
                  let targetMarketingVersion = marketingVersion(from: journal.targetVersion) else {
                throw DestinationVolumeReplacementFailure.invalidRequest
            }
            let parent = try canonicalPrivateIntegrationParent(destinationParentURL)
            let descriptor = parent.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw DestinationVolumeReplacementFailure.unsafeDestinationParent
            }
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & 0o077 == 0,
                  metadata.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
                _ = Darwin.close(descriptor)
                throw DestinationVolumeReplacementFailure.unsafeDestinationParent
            }
            let candidateContainerName = try DestinationVolumeReplacementProtocol
                .candidateContainerName(
                transactionID: journal.transactionID
            )
            let candidateParentDescriptor = candidateContainerName.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard candidateParentDescriptor >= 0 else {
                _ = Darwin.close(descriptor)
                throw DestinationVolumeReplacementFailure.unsafeDestinationParent
            }
            var candidateParentMetadata = stat()
            guard Darwin.fstat(candidateParentDescriptor, &candidateParentMetadata) == 0,
                  (candidateParentMetadata.st_mode & S_IFMT) == S_IFDIR,
                  candidateParentMetadata.st_dev == metadata.st_dev,
                  candidateParentMetadata.st_uid == Darwin.geteuid(),
                  candidateParentMetadata.st_mode & 0o077 == 0,
                  candidateParentMetadata.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
                _ = Darwin.close(candidateParentDescriptor)
                _ = Darwin.close(descriptor)
                throw DestinationVolumeReplacementFailure.unsafeDestinationParent
            }
            self.locator = locator
            self.journal = journal
            self.parentDescriptor = descriptor
            self.candidateParentDescriptor = candidateParentDescriptor
            self.candidateContainerName = candidateContainerName
            self.candidateContainerIdentity = EntryIdentity(
                device: candidateParentMetadata.st_dev,
                inode: candidateParentMetadata.st_ino
            )
            self.installedURL = parent.appendingPathComponent(installedBundleName, isDirectory: true)
            self.candidateURL = parent
                .appendingPathComponent(candidateContainerName, isDirectory: true)
                .appendingPathComponent(installedBundleName, isDirectory: true)
            self.currentPolicy = ExistingBundleInspectionPolicy(
                bundleIdentifier: journal.bundleIdentifier,
                marketingVersion: journal.currentVersion,
                codeSigningRequirement: exactSigningRequirement
            )
            self.targetPolicy = ExistingBundleInspectionPolicy(
                bundleIdentifier: journal.bundleIdentifier,
                marketingVersion: targetMarketingVersion,
                codeSigningRequirement: exactSigningRequirement
            )
            do {
                _ = try validateBundleEntry(installedBundleName)
                _ = try validateBundleEntry(
                    installedBundleName,
                    directoryDescriptor: candidateParentDescriptor
                )
            } catch {
                _ = Darwin.close(candidateParentDescriptor)
                _ = Darwin.close(descriptor)
                throw error
            }
        }

        deinit {
            _ = Darwin.close(candidateParentDescriptor)
            _ = Darwin.close(parentDescriptor)
        }

        func matchesPair(_ expected: ExpectedPair) -> Bool {
            (try? verifyPair(expected: expected)) != nil
        }

        func verifyPair(expected: ExpectedPair) throws -> PairIdentity {
            let installedPolicy = expected == .currentThenTarget ? currentPolicy : targetPolicy
            let candidatePolicy = expected == .currentThenTarget ? targetPolicy : currentPolicy
            do {
                _ = try SafeUpdateBundleInspector.inspectExistingBundle(
                    at: installedURL,
                    policy: installedPolicy
                )
                _ = try SafeUpdateBundleInspector.inspectExistingBundle(
                    at: candidateURL,
                    policy: candidatePolicy
                )
            } catch {
                throw DestinationVolumeReplacementFailure.bundleInspectionFailed
            }
            try validateCandidateContainerIdentity()
            return PairIdentity(
                installed: try validateBundleEntry(installedBundleName),
                candidate: try validateBundleEntry(
                    installedBundleName,
                    directoryDescriptor: candidateParentDescriptor
                )
            )
        }

        func atomicSwap(expected: PairIdentity) throws {
            try validateCandidateContainerIdentity()
            guard try validateBundleEntry(installedBundleName) == expected.installed,
                  try validateBundleEntry(
                installedBundleName,
                directoryDescriptor: candidateParentDescriptor
                  ) == expected.candidate else {
                throw DestinationVolumeReplacementFailure.bundlePairMismatch
            }
            let result = installedBundleName.withCString { installedName in
                installedBundleName.withCString { candidateName in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        installedName,
                        candidateParentDescriptor,
                        candidateName,
                        renameFlags
                    )
                }
            }
            guard result == 0 else {
                let code = errno
                if code == ENOTSUP || code == EINVAL {
                    throw DestinationVolumeReplacementFailure.atomicSwapUnsupported
                }
                throw DestinationVolumeReplacementFailure.atomicSwapFailed(code)
            }
            try synchronizeDirectories()
        }

        func synchronizeDirectories() throws {
            guard Darwin.fsync(candidateParentDescriptor) == 0,
                  Darwin.fsync(parentDescriptor) == 0 else {
                throw DestinationVolumeReplacementFailure.synchronizeFailed
            }
        }

        private func validateCandidateContainerIdentity() throws {
            var metadata = stat()
            let result = candidateContainerName.withCString {
                Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  EntryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
                    == candidateContainerIdentity else {
                throw DestinationVolumeReplacementFailure.unsafeDestinationParent
            }
        }

        private func validateBundleEntry(
            _ name: String,
            directoryDescriptor: Int32? = nil
        ) throws -> EntryIdentity {
            let directoryDescriptor = directoryDescriptor ?? parentDescriptor
            var metadata = stat()
            let result = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            var parentMetadata = stat()
            guard result == 0,
                  Darwin.fstat(parentDescriptor, &parentMetadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_dev == parentMetadata.st_dev,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & 0o022 == 0,
                  metadata.st_mode & (S_ISUID | S_ISGID | S_ISVTX) == 0 else {
                throw DestinationVolumeReplacementFailure.unsafeBundleEntry
            }
            return EntryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
        }
    }

    private static func canonicalPrivateIntegrationParent(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DestinationVolumeReplacementFailure.invalidRequest
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { storage in
            url.path.withCString { path in
                Darwin.realpath(path, storage.baseAddress)
            }
        }
        guard resolved != nil else {
            throw DestinationVolumeReplacementFailure.unsafeDestinationParent
        }
        guard let path = buffer.withUnsafeBufferPointer({ storage -> String? in
            guard let base = storage.baseAddress else { return nil }
            return String(validatingCString: base)
        }) else {
            throw DestinationVolumeReplacementFailure.unsafeDestinationParent
        }
        guard path.hasPrefix(integrationRootPrefix),
              !path.contains("/../"),
              path != "/private/tmp" else {
            throw DestinationVolumeReplacementFailure.nonShippingScopeRequired
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func validTransactionID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              UUID(uuidString: value) != nil else { return false }
        return value == value.lowercased()
    }

    private static func validVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 6 && part.allSatisfy(\.isNumber)
        }
    }

    private static func marketingVersion(from releaseTag: String) -> String? {
        guard releaseTag.first == "v" else { return nil }
        let body = releaseTag.dropFirst()
        let version = String(body.split(separator: "-", maxSplits: 1)[0])
        return validVersion(version) ? version : nil
    }
}
