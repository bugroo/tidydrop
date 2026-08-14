import CryptoKit
import Darwin
import Foundation

public enum UpdateStagingFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unsafeParent
    case insufficientSpace
    case workspaceCreationFailed
    case artifactCreationFailed
    case sizeLimitExceeded
    case incompleteArtifact
    case cancelled
    case writeFailed
    case synchronizeFailed
    case artifactChanged
    case artifactDigestMismatch
    case finalizeFailed
}

public enum UpdateStagingFaultInjection: Equatable, Sendable {
    case none
    case diskFull(afterBytes: UInt64)
}

public struct StagedUpdateArtifact: Equatable, Sendable {
    public let fileURL: URL
    public let workspaceURL: URL
    public let byteCount: UInt64
    public let deviceID: UInt64
    public let inode: UInt64

    public init(
        fileURL: URL,
        workspaceURL: URL,
        byteCount: UInt64,
        deviceID: UInt64,
        inode: UInt64
    ) {
        self.fileURL = fileURL
        self.workspaceURL = workspaceURL
        self.byteCount = byteCount
        self.deviceID = deviceID
        self.inode = inode
    }
}

/// A descriptor-anchored artifact sink for a future authenticated downloader.
///
/// This type performs no networking, mounting, extraction, installation, or
/// application replacement. The current product does not import this module.
public final class PrivateUpdateStagingWriter {
    private enum State {
        case active
        case cancelled
        case failed
        case finalized
    }

    private static let workspacePrefix = ".tidydrop-update-"
    private static let maximumWorkspaceAttempts = 8

    private var parentDescriptor: Int32
    private var workspaceDescriptor: Int32
    private var artifactDescriptor: Int32
    private let parentURL: URL
    private let workspaceName: String
    private let partialName: String
    private let artifactName: String
    private let expectedBytes: UInt64
    private let expectedSHA256: String
    private let maximumBytes: UInt64
    private let faultInjection: UpdateStagingFaultInjection
    private let initialDevice: dev_t
    private let initialInode: ino_t
    private var writtenBytes: UInt64 = 0
    private var artifactHasher = SHA256()
    private var state: State = .active

    private init(
        parentDescriptor: Int32,
        workspaceDescriptor: Int32,
        artifactDescriptor: Int32,
        parentURL: URL,
        workspaceName: String,
        partialName: String,
        artifactName: String,
        expectedBytes: UInt64,
        expectedSHA256: String,
        maximumBytes: UInt64,
        faultInjection: UpdateStagingFaultInjection,
        initialDevice: dev_t,
        initialInode: ino_t
    ) {
        self.parentDescriptor = parentDescriptor
        self.workspaceDescriptor = workspaceDescriptor
        self.artifactDescriptor = artifactDescriptor
        self.parentURL = parentURL
        self.workspaceName = workspaceName
        self.partialName = partialName
        self.artifactName = artifactName
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.maximumBytes = maximumBytes
        self.faultInjection = faultInjection
        self.initialDevice = initialDevice
        self.initialInode = initialInode
    }

    deinit {
        if state == .active {
            cleanupIncompleteArtifact()
        } else {
            closeDescriptors()
        }
    }

    public static func create(
        in parentDirectory: URL,
        authenticatedManifest: AuthenticatedReleaseManifest,
        maximumBytes: UInt64,
        faultInjection: UpdateStagingFaultInjection = .none
    ) throws -> PrivateUpdateStagingWriter {
        let manifest = authenticatedManifest.manifest
        guard parentDirectory.isFileURL,
              parentDirectory.path.hasPrefix("/"),
              manifest.artifactLength > 0,
              manifest.artifactLength <= maximumBytes else {
            throw UpdateStagingFailure.invalidRequest
        }

        let requestedParent = parentDirectory.standardizedFileURL
        let parentDescriptor = requestedParent.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else {
            throw UpdateStagingFailure.unsafeParent
        }

        var keepParent = false
        var workspaceDescriptor: Int32 = -1
        var artifactDescriptor: Int32 = -1
        var createdWorkspaceName: String?
        var createdPartialName: String?
        defer {
            if !keepParent {
                if artifactDescriptor >= 0 { _ = Darwin.close(artifactDescriptor) }
                if let createdPartialName, workspaceDescriptor >= 0 {
                    _ = createdPartialName.withCString {
                        Darwin.unlinkat(workspaceDescriptor, $0, 0) // APP_OWNED_UPDATE_STAGING_CLEANUP
                    }
                }
                if workspaceDescriptor >= 0 { _ = Darwin.close(workspaceDescriptor) }
                if let createdWorkspaceName {
                    _ = createdWorkspaceName.withCString {
                        Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) // APP_OWNED_UPDATE_STAGING_CLEANUP
                    }
                }
                _ = Darwin.close(parentDescriptor)
            }
        }

        let canonicalParent = try validatePrivateParent(
            descriptor: parentDescriptor,
            requestedURL: requestedParent
        )
        guard try availableBytes(descriptor: parentDescriptor) >= manifest.artifactLength else {
            throw UpdateStagingFailure.insufficientSpace
        }

        for _ in 0..<maximumWorkspaceAttempts {
            let candidate = workspacePrefix + UUID().uuidString.lowercased()
            let result = candidate.withCString { Darwin.mkdirat(parentDescriptor, $0, 0o700) }
            if result == 0 {
                createdWorkspaceName = candidate
                break
            }
            if errno != EEXIST {
                throw UpdateStagingFailure.workspaceCreationFailed
            }
        }
        guard let workspaceName = createdWorkspaceName else {
            throw UpdateStagingFailure.workspaceCreationFailed
        }

        workspaceDescriptor = workspaceName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard workspaceDescriptor >= 0,
              validateOwnedDirectory(descriptor: workspaceDescriptor, exactMode: 0o700) else {
            throw UpdateStagingFailure.workspaceCreationFailed
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw UpdateStagingFailure.synchronizeFailed
        }

        let partialName = ".\(manifest.artifactName).partial"
        createdPartialName = partialName
        artifactDescriptor = partialName.withCString {
            Darwin.openat(
                workspaceDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard artifactDescriptor >= 0 else {
            throw UpdateStagingFailure.artifactCreationFailed
        }

        var initial = stat()
        guard Darwin.fstat(artifactDescriptor, &initial) == 0,
              validateOwnedRegularFile(initial, exactMode: 0o600),
              initial.st_size == 0 else {
            throw UpdateStagingFailure.artifactCreationFailed
        }

        keepParent = true
        return PrivateUpdateStagingWriter(
            parentDescriptor: parentDescriptor,
            workspaceDescriptor: workspaceDescriptor,
            artifactDescriptor: artifactDescriptor,
            parentURL: canonicalParent,
            workspaceName: workspaceName,
            partialName: partialName,
            artifactName: manifest.artifactName,
            expectedBytes: manifest.artifactLength,
            expectedSHA256: manifest.artifactSHA256,
            maximumBytes: maximumBytes,
            faultInjection: faultInjection,
            initialDevice: initial.st_dev,
            initialInode: initial.st_ino
        )
    }

    public func append(_ data: Data) throws {
        guard state == .active else {
            throw state == .cancelled ? UpdateStagingFailure.cancelled : .writeFailed
        }
        guard !data.isEmpty else { return }
        let count = UInt64(data.count)
        guard count <= maximumBytes - writtenBytes,
              count <= expectedBytes - writtenBytes else {
            failAndCleanup()
            throw UpdateStagingFailure.sizeLimitExceeded
        }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let allowedCount = try writableCount(requested: bytes.count - offset)
                    let result = Darwin.write(
                        artifactDescriptor,
                        baseAddress.advanced(by: offset),
                        allowedCount
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        if errno == ENOSPC || errno == EDQUOT {
                            throw UpdateStagingFailure.insufficientSpace
                        }
                        throw UpdateStagingFailure.writeFailed
                    }
                    guard result > 0 else { throw UpdateStagingFailure.writeFailed }
                    artifactHasher.update(
                        bufferPointer: UnsafeRawBufferPointer(
                            start: baseAddress.advanced(by: offset),
                            count: result
                        )
                    )
                    offset += result
                    writtenBytes += UInt64(result)
                }
            }
        } catch {
            failAndCleanup()
            throw error
        }
    }

    public func cancel() {
        guard state == .active else { return }
        state = .cancelled
        cleanupIncompleteArtifact()
    }

    public func finish() throws -> StagedUpdateArtifact {
        guard state == .active else {
            throw state == .cancelled ? UpdateStagingFailure.cancelled : .finalizeFailed
        }
        guard writtenBytes == expectedBytes else {
            failAndCleanup()
            throw UpdateStagingFailure.incompleteArtifact
        }
        guard Darwin.fsync(artifactDescriptor) == 0 else {
            failAndCleanup()
            throw UpdateStagingFailure.synchronizeFailed
        }

        var current = stat()
        guard Darwin.fstat(artifactDescriptor, &current) == 0,
              Self.validateOwnedRegularFile(current, exactMode: 0o600),
              current.st_dev == initialDevice,
              current.st_ino == initialInode,
              current.st_size >= 0,
              UInt64(current.st_size) == writtenBytes else {
            failAndCleanup()
            throw UpdateStagingFailure.artifactChanged
        }
        let digest = artifactHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedSHA256 else {
            failAndCleanup()
            throw UpdateStagingFailure.artifactDigestMismatch
        }

        let renamed = partialName.withCString { partialPath in
            artifactName.withCString { finalPath in
                Darwin.renameatx_np(
                    workspaceDescriptor,
                    partialPath,
                    workspaceDescriptor,
                    finalPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renamed == 0 else {
            failAndCleanup()
            throw UpdateStagingFailure.finalizeFailed
        }
        guard Darwin.fsync(workspaceDescriptor) == 0 else {
            failAndCleanup(finalName: artifactName)
            throw UpdateStagingFailure.synchronizeFailed
        }

        var finalEntry = stat()
        let finalStatResult = artifactName.withCString {
            Darwin.fstatat(workspaceDescriptor, $0, &finalEntry, AT_SYMLINK_NOFOLLOW)
        }
        guard finalStatResult == 0,
              Self.validateOwnedRegularFile(finalEntry, exactMode: 0o600),
              finalEntry.st_dev == current.st_dev,
              finalEntry.st_ino == current.st_ino,
              finalEntry.st_size == current.st_size else {
            failAndCleanup(finalName: artifactName)
            throw UpdateStagingFailure.artifactChanged
        }

        let workspaceURL = parentURL.appendingPathComponent(workspaceName, isDirectory: true)
        let fileURL = workspaceURL.appendingPathComponent(artifactName, isDirectory: false)
        var pathEntry = stat()
        let pathStatResult = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &pathEntry)
        }
        guard pathStatResult == 0,
              pathEntry.st_dev == current.st_dev,
              pathEntry.st_ino == current.st_ino,
              pathEntry.st_size == current.st_size else {
            failAndCleanup(finalName: artifactName)
            throw UpdateStagingFailure.artifactChanged
        }
        state = .finalized
        closeDescriptors()
        return StagedUpdateArtifact(
            fileURL: fileURL,
            workspaceURL: workspaceURL,
            byteCount: writtenBytes,
            deviceID: UInt64(current.st_dev),
            inode: UInt64(current.st_ino)
        )
    }

    private func writableCount(requested: Int) throws -> Int {
        switch faultInjection {
        case .none:
            return requested
        case let .diskFull(afterBytes):
            guard writtenBytes < afterBytes else {
                throw UpdateStagingFailure.insufficientSpace
            }
            let remaining = afterBytes - writtenBytes
            return min(requested, Int(min(remaining, UInt64(Int.max))))
        }
    }

    private func failAndCleanup() {
        state = .failed
        cleanupIncompleteArtifact()
    }

    private func failAndCleanup(finalName: String) {
        state = .failed
        if workspaceDescriptor >= 0 {
            var entry = stat()
            let safeToRemove = finalName.withCString {
                Darwin.fstatat(workspaceDescriptor, $0, &entry, AT_SYMLINK_NOFOLLOW)
            } == 0 && entry.st_dev == initialDevice && entry.st_ino == initialInode
            if safeToRemove {
                _ = finalName.withCString {
                    Darwin.unlinkat(workspaceDescriptor, $0, 0) // APP_OWNED_UPDATE_STAGING_CLEANUP
                }
            }
        }
        closeArtifactDescriptor()
        removeEmptyWorkspaceAndClose()
    }

    private func cleanupIncompleteArtifact() {
        if artifactDescriptor >= 0, workspaceDescriptor >= 0 {
            var current = stat()
            let descriptorMatches = Darwin.fstat(artifactDescriptor, &current) == 0
                && current.st_dev == initialDevice
                && current.st_ino == initialInode
            if descriptorMatches {
                _ = partialName.withCString {
                    Darwin.unlinkat(workspaceDescriptor, $0, 0) // APP_OWNED_UPDATE_STAGING_CLEANUP
                }
            }
        }
        closeArtifactDescriptor()
        removeEmptyWorkspaceAndClose()
    }

    private func removeEmptyWorkspaceAndClose() {
        if workspaceDescriptor >= 0 { _ = Darwin.close(workspaceDescriptor) }
        workspaceDescriptor = -1
        if parentDescriptor >= 0 {
            _ = workspaceName.withCString {
                Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) // APP_OWNED_UPDATE_STAGING_CLEANUP
            }
            _ = Darwin.fsync(parentDescriptor)
            _ = Darwin.close(parentDescriptor)
        }
        parentDescriptor = -1
    }

    private func closeArtifactDescriptor() {
        if artifactDescriptor >= 0 { _ = Darwin.close(artifactDescriptor) }
        artifactDescriptor = -1
    }

    private func closeDescriptors() {
        closeArtifactDescriptor()
        if workspaceDescriptor >= 0 { _ = Darwin.close(workspaceDescriptor) }
        if parentDescriptor >= 0 { _ = Darwin.close(parentDescriptor) }
        workspaceDescriptor = -1
        parentDescriptor = -1
    }

    private static func validatePrivateParent(
        descriptor: Int32,
        requestedURL: URL
    ) throws -> URL {
        guard validateOwnedDirectory(descriptor: descriptor, exactMode: nil) else {
            throw UpdateStagingFailure.unsafeParent
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & 0o022) == 0 else {
            throw UpdateStagingFailure.unsafeParent
        }

        var resolvedPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = requestedURL.withUnsafeFileSystemRepresentation { path -> UnsafeMutablePointer<CChar>? in
            guard let path else { return nil }
            return Darwin.realpath(path, &resolvedPath)
        }
        guard result != nil,
              let terminator = resolvedPath.firstIndex(of: 0) else {
            throw UpdateStagingFailure.unsafeParent
        }
        let pathText = String(decoding: resolvedPath[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let descriptorURL = URL(fileURLWithPath: pathText, isDirectory: true)
            .standardizedFileURL
        guard descriptorURL.path == requestedURL.path else {
            throw UpdateStagingFailure.unsafeParent
        }
        return descriptorURL
    }

    private static func validateOwnedDirectory(
        descriptor: Int32,
        exactMode mode: mode_t?
    ) -> Bool {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else { return false }
        if let mode {
            return metadata.st_mode & 0o777 == mode
        }
        return true
    }

    private static func validateOwnedRegularFile(_ metadata: stat, exactMode: mode_t) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == Darwin.geteuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o777 == exactMode
    }

    private static func availableBytes(descriptor: Int32) throws -> UInt64 {
        var filesystem = statfs()
        guard Darwin.fstatfs(descriptor, &filesystem) == 0,
              filesystem.f_bavail >= 0,
              filesystem.f_bsize > 0 else {
            throw UpdateStagingFailure.unsafeParent
        }
        let blocks = UInt64(filesystem.f_bavail)
        let blockSize = UInt64(filesystem.f_bsize)
        let (bytes, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        return overflow ? UInt64.max : bytes
    }
}
