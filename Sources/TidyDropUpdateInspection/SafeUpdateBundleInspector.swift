import CryptoKit
import Darwin
import Foundation
import Security
import TidyDropUpdateSecurity

public enum UpdateBundleInspectionFailure: Error, Equatable, Sendable {
    case invalidPolicy
    case unauthenticatedArtifact
    case unsafeWorkspace
    case imageVerificationFailed
    case imageAttachFailed
    case imageMountNotReadOnly
    case imageDetachFailed
    case unsafeImageLayout
    case unsafeBundleEntry
    case bundleLimitExceeded
    case invalidBundleMetadata
    case wrongBundleIdentifier
    case wrongBundleVersion
    case invalidExecutable
    case architectureMismatch
    case invalidCodeRequirement
    case invalidCodeSignature(Int32)
}

public struct UpdateBundleInspectionPolicy: Equatable, Sendable {
    public static let maximumAllowedEntries = 16_384
    public static let maximumAllowedUncompressedBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    public let manifestTag: String
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let codeSigningRequirement: String
    public let maximumEntries: Int
    public let maximumUncompressedBytes: UInt64

    public init(
        authenticatedManifest: AuthenticatedReleaseManifest,
        codeSigningRequirement: String,
        maximumEntries: Int = 4_096,
        maximumUncompressedBytes: UInt64 = 1_024 * 1_024 * 1_024
    ) {
        let manifest = authenticatedManifest.manifest
        self.manifestTag = manifest.version.tag
        self.bundleIdentifier = manifest.bundleIdentifier
        self.marketingVersion = "\(manifest.version.major).\(manifest.version.minor).\(manifest.version.patch)"
        self.codeSigningRequirement = codeSigningRequirement
        self.maximumEntries = maximumEntries
        self.maximumUncompressedBytes = maximumUncompressedBytes
    }
}

public struct InspectedUpdateBundle: Equatable, Sendable {
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let executableName: String
    public let architectures: [String]
    public let entryCount: Int
    public let uncompressedRegularBytes: UInt64

    public init(
        bundleIdentifier: String,
        marketingVersion: String,
        executableName: String,
        architectures: [String],
        entryCount: Int,
        uncompressedRegularBytes: UInt64
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.marketingVersion = marketingVersion
        self.executableName = executableName
        self.architectures = architectures
        self.entryCount = entryCount
        self.uncompressedRegularBytes = uncompressedRegularBytes
    }
}

public struct ExistingBundleInspectionPolicy: Equatable, Sendable {
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let codeSigningRequirement: String
    public let maximumEntries: Int
    public let maximumUncompressedBytes: UInt64

    public init(
        bundleIdentifier: String,
        marketingVersion: String,
        codeSigningRequirement: String,
        maximumEntries: Int = 4_096,
        maximumUncompressedBytes: UInt64 = 1_024 * 1_024 * 1_024
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.marketingVersion = marketingVersion
        self.codeSigningRequirement = codeSigningRequirement
        self.maximumEntries = maximumEntries
        self.maximumUncompressedBytes = maximumUncompressedBytes
    }
}

/// A non-shipping inspection boundary for an authenticated staged DMG.
///
/// The image is rehashed, verified, mounted read-only into its private staging
/// workspace, inspected, and detached. This type cannot copy, install, launch,
/// replace, or register an application.
public enum SafeUpdateBundleInspector {
    private static let expectedAppName = "TidyDrop.app"
    private static let applicationsLinkName = "Applications"
    private static let applicationsLinkTarget = "/Applications"
    private static let requiredResourceExecutables = ["tidydrop", "tidydrop-agent"]
    private static let requiredArchitectures = Set(["arm64", "x86_64"])
    private static let hdiutilURL = URL(fileURLWithPath: "/usr/bin/hdiutil")

    public static func inspect(
        stagedArtifact: StagedUpdateArtifact,
        authenticatedManifest: AuthenticatedReleaseManifest,
        policy: UpdateBundleInspectionPolicy
    ) throws -> InspectedUpdateBundle {
        try validate(policy: policy, manifest: authenticatedManifest)
        let verified = try VerifiedStagedArtifact(
            stagedArtifact: stagedArtifact,
            authenticatedManifest: authenticatedManifest
        )
        defer { verified.close() }

        guard runHdiutil(
            ["verify", verified.artifactURL.path, "-quiet"],
            timeout: 60
        ) else {
            throw UpdateBundleInspectionFailure.imageVerificationFailed
        }

        let mount = try PrivateMountPoint(workspace: verified.workspaceURL)
        var attached = false
        var inspectionResult: Result<InspectedUpdateBundle, Error>

        if runHdiutil(
            [
                "attach", verified.artifactURL.path,
                "-readonly", "-verify", "-nobrowse", "-noautoopen",
                "-owners", "off", "-mountpoint", mount.url.path, "-quiet"
            ],
            timeout: 30
        ) {
            attached = true
            do {
                try mount.validateAttachedReadOnly()
                inspectionResult = .success(try inspectMountedRoot(mount.url, policy: policy))
            } catch {
                inspectionResult = .failure(error)
            }
        } else {
            inspectionResult = .failure(UpdateBundleInspectionFailure.imageAttachFailed)
        }

        if attached {
            guard detach(mount.url) else {
                throw UpdateBundleInspectionFailure.imageDetachFailed
            }
        }
        try mount.remove()
        try verified.revalidateAfterUse()
        return try inspectionResult.get()
    }

    /// Applies the same bounded metadata, architecture, tree, and code-signing
    /// checks to an already-installed or retained application bundle. This is
    /// used only by the non-shipping recovery foundation.
    public static func inspectExistingBundle(
        at bundleURL: URL,
        policy: ExistingBundleInspectionPolicy
    ) throws -> InspectedUpdateBundle {
        try validateExistingPolicyBounds(policy)
        guard bundleURL.isFileURL, bundleURL.lastPathComponent == expectedAppName else {
            throw UpdateBundleInspectionFailure.invalidPolicy
        }
        let descriptor = bundleURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw UpdateBundleInspectionFailure.unsafeBundleEntry
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw UpdateBundleInspectionFailure.unsafeBundleEntry
        }
        return try inspectOpenedBundle(
            descriptor: descriptor,
            bundleURL: bundleURL,
            rootDevice: metadata.st_dev,
            policy: BundleValidationPolicy(
                bundleIdentifier: policy.bundleIdentifier,
                marketingVersion: policy.marketingVersion,
                codeSigningRequirement: policy.codeSigningRequirement,
                maximumEntries: policy.maximumEntries,
                maximumUncompressedBytes: policy.maximumUncompressedBytes
            )
        )
    }

    @_spi(Testing)
    public static func inspectMountedRootForTesting(
        _ rootURL: URL,
        policy: UpdateBundleInspectionPolicy
    ) throws -> InspectedUpdateBundle {
        try validatePolicyBounds(policy)
        return try inspectMountedRoot(rootURL, policy: policy)
    }

    private static func validate(
        policy: UpdateBundleInspectionPolicy,
        manifest: AuthenticatedReleaseManifest
    ) throws {
        try validatePolicyBounds(policy)
        let release = manifest.manifest
        guard policy.manifestTag == release.version.tag,
              policy.bundleIdentifier == release.bundleIdentifier,
              policy.marketingVersion == "\(release.version.major).\(release.version.minor).\(release.version.patch)",
              release.artifactName.hasSuffix(".dmg") else {
            throw UpdateBundleInspectionFailure.invalidPolicy
        }
    }

    private static func validatePolicyBounds(_ policy: UpdateBundleInspectionPolicy) throws {
        guard !policy.bundleIdentifier.isEmpty,
              policy.bundleIdentifier.utf8.count <= 128,
              !policy.marketingVersion.isEmpty,
              policy.marketingVersion.utf8.count <= 64,
              !policy.codeSigningRequirement.isEmpty,
              policy.codeSigningRequirement.utf8.count <= 8_192,
              policy.maximumEntries > 0,
              policy.maximumEntries <= UpdateBundleInspectionPolicy.maximumAllowedEntries,
              policy.maximumUncompressedBytes > 0,
              policy.maximumUncompressedBytes <= UpdateBundleInspectionPolicy.maximumAllowedUncompressedBytes else {
            throw UpdateBundleInspectionFailure.invalidPolicy
        }
    }

    private static func validateExistingPolicyBounds(
        _ policy: ExistingBundleInspectionPolicy
    ) throws {
        guard !policy.bundleIdentifier.isEmpty,
              policy.bundleIdentifier.utf8.count <= 128,
              !policy.marketingVersion.isEmpty,
              policy.marketingVersion.utf8.count <= 64,
              !policy.codeSigningRequirement.isEmpty,
              policy.codeSigningRequirement.utf8.count <= 8_192,
              policy.maximumEntries > 0,
              policy.maximumEntries <= UpdateBundleInspectionPolicy.maximumAllowedEntries,
              policy.maximumUncompressedBytes > 0,
              policy.maximumUncompressedBytes <= UpdateBundleInspectionPolicy.maximumAllowedUncompressedBytes else {
            throw UpdateBundleInspectionFailure.invalidPolicy
        }
    }

    private static func inspectMountedRoot(
        _ rootURL: URL,
        policy: UpdateBundleInspectionPolicy
    ) throws -> InspectedUpdateBundle {
        let rootDescriptor = rootURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
        defer { _ = Darwin.close(rootDescriptor) }

        var rootMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
        try validateImageRoot(descriptor: rootDescriptor)

        let appDescriptor = expectedAppName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard appDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
        defer { _ = Darwin.close(appDescriptor) }

        var appMetadata = stat()
        guard Darwin.fstat(appDescriptor, &appMetadata) == 0,
              (appMetadata.st_mode & S_IFMT) == S_IFDIR,
              appMetadata.st_dev == rootMetadata.st_dev else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }

        let appURL = rootURL.appendingPathComponent(expectedAppName, isDirectory: true)
        return try inspectOpenedBundle(
            descriptor: appDescriptor,
            bundleURL: appURL,
            rootDevice: appMetadata.st_dev,
            policy: BundleValidationPolicy(
                bundleIdentifier: policy.bundleIdentifier,
                marketingVersion: policy.marketingVersion,
                codeSigningRequirement: policy.codeSigningRequirement,
                maximumEntries: policy.maximumEntries,
                maximumUncompressedBytes: policy.maximumUncompressedBytes
            )
        )
    }

    private struct BundleValidationPolicy {
        let bundleIdentifier: String
        let marketingVersion: String
        let codeSigningRequirement: String
        let maximumEntries: Int
        let maximumUncompressedBytes: UInt64
    }

    private static func inspectOpenedBundle(
        descriptor appDescriptor: Int32,
        bundleURL: URL,
        rootDevice: dev_t,
        policy: BundleValidationPolicy
    ) throws -> InspectedUpdateBundle {
        var tree = BundleTreeInspector(
            rootDevice: rootDevice,
            maximumEntries: policy.maximumEntries,
            maximumBytes: policy.maximumUncompressedBytes
        )
        try tree.inspect(directoryDescriptor: appDescriptor, depth: 0)

        let metadata = try readBundleMetadata(appDescriptor: appDescriptor)
        guard metadata.identifier == policy.bundleIdentifier else {
            throw UpdateBundleInspectionFailure.wrongBundleIdentifier
        }
        guard metadata.version == policy.marketingVersion else {
            throw UpdateBundleInspectionFailure.wrongBundleVersion
        }

        let executableDescriptor = try openExecutable(
            appDescriptor: appDescriptor,
            executableName: metadata.executable
        )
        defer { _ = Darwin.close(executableDescriptor) }
        let architectures = try validateRequiredArchitectures(descriptor: executableDescriptor)
        for resourceName in requiredResourceExecutables {
            let resourceDescriptor = try openResourceExecutable(
                appDescriptor: appDescriptor,
                executableName: resourceName
            )
            defer { _ = Darwin.close(resourceDescriptor) }
            _ = try validateRequiredArchitectures(descriptor: resourceDescriptor)
        }

        try validateCodeSignature(appURL: bundleURL, requirementText: policy.codeSigningRequirement)

        return InspectedUpdateBundle(
            bundleIdentifier: metadata.identifier,
            marketingVersion: metadata.version,
            executableName: metadata.executable,
            architectures: architectures.sorted(),
            entryCount: tree.entryCount,
            uncompressedRegularBytes: tree.regularBytes
        )
    }

    private static func validateImageRoot(descriptor: Int32) throws {
        let entries = try directoryEntryNames(descriptor: descriptor)
        guard Set(entries) == Set([expectedAppName, applicationsLinkName]) else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }

        var appMetadata = stat()
        let appResult = expectedAppName.withCString {
            Darwin.fstatat(descriptor, $0, &appMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard appResult == 0, (appMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }

        var applicationsMetadata = stat()
        let linkResult = applicationsLinkName.withCString {
            Darwin.fstatat(descriptor, $0, &applicationsMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard linkResult == 0, (applicationsMetadata.st_mode & S_IFMT) == S_IFLNK else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
        var target = [CChar](repeating: 0, count: 64)
        let count = applicationsLinkName.withCString {
            Darwin.readlinkat(descriptor, $0, &target, target.count - 1)
        }
        guard count == applicationsLinkTarget.utf8.count else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
        let targetText = String(
            decoding: target.prefix(Int(count)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard targetText == applicationsLinkTarget else {
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
    }

    private struct BundleMetadata {
        let identifier: String
        let version: String
        let executable: String
    }

    private static func readBundleMetadata(appDescriptor: Int32) throws -> BundleMetadata {
        let contentsDescriptor = "Contents".withCString {
            Darwin.openat(appDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard contentsDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidBundleMetadata
        }
        defer { _ = Darwin.close(contentsDescriptor) }

        let infoDescriptor = "Info.plist".withCString {
            Darwin.openat(contentsDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard infoDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidBundleMetadata
        }
        defer { _ = Darwin.close(infoDescriptor) }

        let data = try readRegularFile(descriptor: infoDescriptor, maximumBytes: 128 * 1_024)
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw UpdateBundleInspectionFailure.invalidBundleMetadata
        }
        guard let dictionary = object as? [String: Any],
              let packageType = dictionary["CFBundlePackageType"] as? String,
              packageType == "APPL",
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let version = dictionary["CFBundleShortVersionString"] as? String,
              let executable = dictionary["CFBundleExecutable"] as? String,
              isSafeLeafName(executable) else {
            throw UpdateBundleInspectionFailure.invalidBundleMetadata
        }
        return BundleMetadata(identifier: identifier, version: version, executable: executable)
    }

    private static func openExecutable(
        appDescriptor: Int32,
        executableName: String
    ) throws -> Int32 {
        let contentsDescriptor = "Contents".withCString {
            Darwin.openat(appDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard contentsDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        defer { _ = Darwin.close(contentsDescriptor) }
        let macOSDescriptor = "MacOS".withCString {
            Darwin.openat(contentsDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard macOSDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        defer { _ = Darwin.close(macOSDescriptor) }
        let executableDescriptor = executableName.withCString {
            Darwin.openat(macOSDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard executableDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        var metadata = stat()
        guard Darwin.fstat(executableDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size > 0 else {
            _ = Darwin.close(executableDescriptor)
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        return executableDescriptor
    }

    private static func openResourceExecutable(
        appDescriptor: Int32,
        executableName: String
    ) throws -> Int32 {
        let contentsDescriptor = "Contents".withCString {
            Darwin.openat(appDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard contentsDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        defer { _ = Darwin.close(contentsDescriptor) }
        let resourcesDescriptor = "Resources".withCString {
            Darwin.openat(contentsDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard resourcesDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        defer { _ = Darwin.close(resourcesDescriptor) }
        let executableDescriptor = executableName.withCString {
            Darwin.openat(resourcesDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard executableDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        var metadata = stat()
        guard Darwin.fstat(executableDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size > 0 else {
            _ = Darwin.close(executableDescriptor)
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        return executableDescriptor
    }

    private static func validateRequiredArchitectures(descriptor: Int32) throws -> [String] {
        let architectures = try MachOArchitectureReader.architectures(descriptor: descriptor)
        guard Set(architectures) == requiredArchitectures,
              architectures.count == requiredArchitectures.count else {
            throw UpdateBundleInspectionFailure.architectureMismatch
        }
        return architectures
    }

    private static func validateCodeSignature(appURL: URL, requirementText: String) throws {
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw UpdateBundleInspectionFailure.invalidCodeRequirement
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw UpdateBundleInspectionFailure.invalidCodeSignature(createStatus)
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSStrictValidate
                | kSecCSCheckNestedCode
        )
        let validityStatus = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard validityStatus == errSecSuccess else {
            throw UpdateBundleInspectionFailure.invalidCodeSignature(validityStatus)
        }
    }

    private static func detach(_ mountURL: URL) -> Bool {
        for _ in 0..<10 {
            if runHdiutil(["detach", mountURL.path, "-quiet"], timeout: 15) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func runHdiutil(_ arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = hdiutilURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard completed.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = completed.wait(timeout: .now() + 5)
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw UpdateBundleInspectionFailure.unsafeImageLayout
        }
        defer { _ = Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard isSafeDirectoryEntryName(name) else {
                throw UpdateBundleInspectionFailure.unsafeImageLayout
            }
            names.append(name)
        }
        return names
    }

    private static func readRegularFile(descriptor: Int32, maximumBytes: Int) throws -> Data {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw UpdateBundleInspectionFailure.invalidBundleMetadata
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.pread(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw UpdateBundleInspectionFailure.invalidBundleMetadata
            }
            guard count > 0 else {
                throw UpdateBundleInspectionFailure.invalidBundleMetadata
            }
            offset += count
        }
        return data
    }

    private static func isSafeLeafName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("..") else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isSafeDirectoryEntryName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && value.utf8.count <= Int(MAXNAMLEN)
    }
}

private final class VerifiedStagedArtifact {
    let artifactURL: URL
    let workspaceURL: URL
    private var workspaceDescriptor: Int32
    private var artifactDescriptor: Int32
    private let initialMetadata: stat

    init(
        stagedArtifact: StagedUpdateArtifact,
        authenticatedManifest: AuthenticatedReleaseManifest
    ) throws {
        let manifest = authenticatedManifest.manifest
        let requestedWorkspace = stagedArtifact.workspaceURL.standardizedFileURL
        let requestedArtifact = stagedArtifact.fileURL.standardizedFileURL
        guard requestedWorkspace.isFileURL,
              requestedArtifact.isFileURL,
              requestedArtifact.deletingLastPathComponent().path == requestedWorkspace.path,
              requestedArtifact.lastPathComponent == manifest.artifactName,
              stagedArtifact.byteCount == manifest.artifactLength else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }

        let workspaceDescriptor = requestedWorkspace.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard workspaceDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        var keepWorkspace = false
        var artifactDescriptor: Int32 = -1
        defer {
            if !keepWorkspace {
                if artifactDescriptor >= 0 { _ = Darwin.close(artifactDescriptor) }
                _ = Darwin.close(workspaceDescriptor)
            }
        }

        var workspaceMetadata = stat()
        guard Darwin.fstat(workspaceDescriptor, &workspaceMetadata) == 0,
              (workspaceMetadata.st_mode & S_IFMT) == S_IFDIR,
              workspaceMetadata.st_uid == Darwin.geteuid(),
              workspaceMetadata.st_mode & 0o777 == 0o700 else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        let canonicalWorkspace = try Self.canonicalURL(
            requestedURL: requestedWorkspace,
            expectedMetadata: workspaceMetadata
        )

        artifactDescriptor = manifest.artifactName.withCString {
            Darwin.openat(workspaceDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard artifactDescriptor >= 0 else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }
        var artifactMetadata = stat()
        guard Darwin.fstat(artifactDescriptor, &artifactMetadata) == 0,
              (artifactMetadata.st_mode & S_IFMT) == S_IFREG,
              artifactMetadata.st_uid == Darwin.geteuid(),
              artifactMetadata.st_nlink == 1,
              artifactMetadata.st_mode & 0o777 == 0o600,
              artifactMetadata.st_size > 0,
              UInt64(artifactMetadata.st_size) == manifest.artifactLength,
              UInt64(artifactMetadata.st_dev) == stagedArtifact.deviceID,
              UInt64(artifactMetadata.st_ino) == stagedArtifact.inode else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }
        let digest = try Self.hash(descriptor: artifactDescriptor, expectedBytes: manifest.artifactLength)
        guard digest == manifest.artifactSHA256 else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }

        var afterHash = stat()
        guard Darwin.fstat(artifactDescriptor, &afterHash) == 0,
              Self.sameStableMetadata(artifactMetadata, afterHash) else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }

        self.artifactURL = canonicalWorkspace.appendingPathComponent(manifest.artifactName)
        self.workspaceURL = canonicalWorkspace
        self.workspaceDescriptor = workspaceDescriptor
        self.artifactDescriptor = artifactDescriptor
        self.initialMetadata = afterHash
        keepWorkspace = true
    }

    func close() {
        if artifactDescriptor >= 0 { _ = Darwin.close(artifactDescriptor) }
        if workspaceDescriptor >= 0 { _ = Darwin.close(workspaceDescriptor) }
        artifactDescriptor = -1
        workspaceDescriptor = -1
    }

    func revalidateAfterUse() throws {
        var current = stat()
        guard artifactDescriptor >= 0,
              Darwin.fstat(artifactDescriptor, &current) == 0,
              Self.sameStableMetadata(initialMetadata, current) else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }
    }

    private static func canonicalURL(requestedURL: URL, expectedMetadata: stat) throws -> URL {
        var resolved = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = requestedURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil as UnsafeMutablePointer<CChar>? }
            return Darwin.realpath(path, &resolved)
        }
        guard result != nil, let terminator = resolved.firstIndex(of: 0) else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        let text = String(
            decoding: resolved[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let canonical = URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL
        guard canonical.path == requestedURL.path else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        var pathMetadata = stat()
        let status = canonical.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &pathMetadata)
        }
        guard status == 0,
              pathMetadata.st_dev == expectedMetadata.st_dev,
              pathMetadata.st_ino == expectedMetadata.st_ino else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        return canonical
    }

    private static func hash(descriptor: Int32, expectedBytes: UInt64) throws -> String {
        var total: UInt64 = 0
        var offset: off_t = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.pread(descriptor, bytes.baseAddress, bytes.count, offset)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw UpdateBundleInspectionFailure.unauthenticatedArtifact
            }
            total += UInt64(count)
            guard total <= expectedBytes else {
                throw UpdateBundleInspectionFailure.unauthenticatedArtifact
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: bytes.prefix(count))
                )
            }
            offset += off_t(count)
        }
        guard total == expectedBytes else {
            throw UpdateBundleInspectionFailure.unauthenticatedArtifact
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameStableMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

private final class PrivateMountPoint {
    let url: URL
    private var removed = false
    private let initialDevice: dev_t
    private let initialInode: ino_t

    init(workspace: URL) throws {
        let name = ".mount-\(UUID().uuidString.lowercased())"
        self.url = workspace.appendingPathComponent(name, isDirectory: true)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkdir(path, 0o700)
        }
        guard result == 0 else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        var metadata = stat()
        let statResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &metadata)
        }
        guard statResult == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            _ = Darwin.rmdir(url.path) // APP_OWNED_UPDATE_MOUNT_CLEANUP
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        self.initialDevice = metadata.st_dev
        self.initialInode = metadata.st_ino
    }

    func validateAttachedReadOnly() throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw UpdateBundleInspectionFailure.imageMountNotReadOnly
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        var filesystem = statfs()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              Darwin.fstatfs(descriptor, &filesystem) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              (metadata.st_dev != initialDevice || metadata.st_ino != initialInode),
              filesystem.f_flags & UInt32(MNT_RDONLY) != 0 else {
            throw UpdateBundleInspectionFailure.imageMountNotReadOnly
        }
    }

    func remove() throws {
        guard !removed else { return }
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.rmdir(path) // APP_OWNED_UPDATE_MOUNT_CLEANUP
        }
        guard result == 0 else {
            throw UpdateBundleInspectionFailure.unsafeWorkspace
        }
        removed = true
    }

    deinit {
        if !removed { _ = Darwin.rmdir(url.path) } // APP_OWNED_UPDATE_MOUNT_CLEANUP
    }
}

private struct BundleTreeInspector {
    private let rootDevice: dev_t
    private let maximumEntries: Int
    private let maximumBytes: UInt64
    private(set) var entryCount = 0
    private(set) var regularBytes: UInt64 = 0
    private var visitedDirectories: Set<FileIdentity> = []

    init(rootDevice: dev_t, maximumEntries: Int, maximumBytes: UInt64) {
        self.rootDevice = rootDevice
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    mutating func inspect(directoryDescriptor: Int32, depth: Int) throws {
        guard depth <= 32 else {
            throw UpdateBundleInspectionFailure.bundleLimitExceeded
        }
        var directoryMetadata = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
              (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_dev == rootDevice else {
            throw UpdateBundleInspectionFailure.unsafeBundleEntry
        }
        let identity = FileIdentity(device: directoryMetadata.st_dev, inode: directoryMetadata.st_ino)
        guard visitedDirectories.insert(identity).inserted else {
            throw UpdateBundleInspectionFailure.unsafeBundleEntry
        }

        let duplicate = Darwin.dup(directoryDescriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw UpdateBundleInspectionFailure.unsafeBundleEntry
        }
        defer { _ = Darwin.closedir(directory) }

        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), name.utf8.count <= Int(MAXNAMLEN) else {
                throw UpdateBundleInspectionFailure.unsafeBundleEntry
            }
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw UpdateBundleInspectionFailure.bundleLimitExceeded
            }

            var metadata = stat()
            let status = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0, metadata.st_dev == rootDevice else {
                throw UpdateBundleInspectionFailure.unsafeBundleEntry
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFREG:
                guard metadata.st_nlink == 1, metadata.st_size >= 0 else {
                    throw UpdateBundleInspectionFailure.unsafeBundleEntry
                }
                let (newTotal, overflow) = regularBytes.addingReportingOverflow(UInt64(metadata.st_size))
                guard !overflow, newTotal <= maximumBytes else {
                    throw UpdateBundleInspectionFailure.bundleLimitExceeded
                }
                regularBytes = newTotal
            case S_IFDIR:
                let child = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard child >= 0 else {
                    throw UpdateBundleInspectionFailure.unsafeBundleEntry
                }
                defer { _ = Darwin.close(child) }
                try inspect(directoryDescriptor: child, depth: depth + 1)
            default:
                throw UpdateBundleInspectionFailure.unsafeBundleEntry
            }
        }
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}

private enum MachOArchitectureReader {
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let machMagic64Little: UInt32 = 0xfeedfacf
    private static let cpuTypeX86_64: UInt32 = 0x01000007
    private static let cpuTypeARM64: UInt32 = 0x0100000c

    static func architectures(descriptor: Int32) throws -> [String] {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 8 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        let readCount = min(Int(metadata.st_size), 4_096)
        var bytes = [UInt8](repeating: 0, count: readCount)
        let count = bytes.withUnsafeMutableBytes {
            Darwin.pread(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard count == readCount else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        let magic = try readUInt32(bytes, offset: 0, bigEndian: true)
        if magic == fatMagic || magic == fatMagic64 {
            return try readFatArchitectures(
                bytes,
                fileSize: UInt64(metadata.st_size),
                is64Bit: magic == fatMagic64
            )
        }
        let littleMagic = try readUInt32(bytes, offset: 0, bigEndian: false)
        guard littleMagic == machMagic64Little else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        return [try architectureName(readUInt32(bytes, offset: 4, bigEndian: false))]
    }

    private static func readFatArchitectures(
        _ bytes: [UInt8],
        fileSize: UInt64,
        is64Bit: Bool
    ) throws -> [String] {
        let count = Int(try readUInt32(bytes, offset: 4, bigEndian: true))
        guard count > 0, count <= 16 else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        let stride = is64Bit ? 32 : 20
        let headerSize = 8 + count * stride
        guard headerSize <= bytes.count else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        var names: [String] = []
        var ranges: [Range<UInt64>] = []
        for index in 0..<count {
            let base = 8 + index * stride
            let cpuType = try readUInt32(bytes, offset: base, bigEndian: true)
            let offset: UInt64
            let size: UInt64
            if is64Bit {
                offset = try readUInt64(bytes, offset: base + 8, bigEndian: true)
                size = try readUInt64(bytes, offset: base + 16, bigEndian: true)
            } else {
                offset = UInt64(try readUInt32(bytes, offset: base + 8, bigEndian: true))
                size = UInt64(try readUInt32(bytes, offset: base + 12, bigEndian: true))
            }
            let (end, overflow) = offset.addingReportingOverflow(size)
            guard !overflow, size > 0, offset >= UInt64(headerSize), end <= fileSize else {
                throw UpdateBundleInspectionFailure.invalidExecutable
            }
            let range = offset..<end
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw UpdateBundleInspectionFailure.invalidExecutable
            }
            ranges.append(range)
            names.append(try architectureName(cpuType))
        }
        guard Set(names).count == names.count else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        return names
    }

    private static func architectureName(_ cpuType: UInt32) throws -> String {
        switch cpuType {
        case cpuTypeX86_64: return "x86_64"
        case cpuTypeARM64: return "arm64"
        default: throw UpdateBundleInspectionFailure.invalidExecutable
        }
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        offset: Int,
        bigEndian: Bool
    ) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        return bigEndian ? value : value.byteSwapped
    }

    private static func readUInt64(
        _ bytes: [UInt8],
        offset: Int,
        bigEndian: Bool
    ) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else {
            throw UpdateBundleInspectionFailure.invalidExecutable
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return bigEndian ? value : value.byteSwapped
    }
}
