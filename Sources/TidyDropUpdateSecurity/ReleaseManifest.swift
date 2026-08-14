import CryptoKit
import Darwin
import Foundation
import TidyDropCore

public enum ReleaseManifestFailure: Error, Equatable, Sendable {
    case invalidEncoding
    case oversizedManifest
    case nonCanonicalManifest
    case invalidField(String)
    case invalidPublicKey
    case invalidSignature
    case invalidArtifact
    case artifactChangedDuringVerification
    case wrongChannel
    case downgrade
    case replay
    case staleManifest
    case futurePublication
    case wrongBundleIdentifier
    case wrongArtifactName
    case oversizedArtifact
    case artifactLengthMismatch
    case artifactDigestMismatch
    case unsupportedSystem
}

public struct ReleaseManifest: Equatable, Sendable {
    public static let header = "tidydrop-release-manifest-v1"
    public static let maximumEncodedBytes = 4_096

    public let version: ReleaseVersion
    public let channel: UpdateChannel
    public let bundleIdentifier: String
    public let artifactName: String
    public let artifactLength: UInt64
    public let artifactSHA256: String
    public let minimumMacOS: OperatingSystemVersion
    public let publishedAt: Date

    public init(
        version: ReleaseVersion,
        channel: UpdateChannel,
        bundleIdentifier: String,
        artifactName: String,
        artifactLength: UInt64,
        artifactSHA256: String,
        minimumMacOS: OperatingSystemVersion,
        publishedAt: Date
    ) {
        self.version = version
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.artifactName = artifactName
        self.artifactLength = artifactLength
        self.artifactSHA256 = artifactSHA256
        self.minimumMacOS = minimumMacOS
        self.publishedAt = publishedAt
    }

    public static func == (lhs: ReleaseManifest, rhs: ReleaseManifest) -> Bool {
        lhs.version == rhs.version
            && lhs.channel == rhs.channel
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.artifactName == rhs.artifactName
            && lhs.artifactLength == rhs.artifactLength
            && lhs.artifactSHA256 == rhs.artifactSHA256
            && lhs.minimumMacOS.majorVersion == rhs.minimumMacOS.majorVersion
            && lhs.minimumMacOS.minorVersion == rhs.minimumMacOS.minorVersion
            && lhs.minimumMacOS.patchVersion == rhs.minimumMacOS.patchVersion
            && lhs.publishedAt == rhs.publishedAt
    }
}

public struct ReleaseManifestPolicy: Sendable {
    public let currentVersion: ReleaseVersion
    public let channel: UpdateChannel
    public let bundleIdentifier: String
    public let artifactName: String
    public let maximumArtifactBytes: UInt64
    public let currentSystem: OperatingSystemVersion
    public let now: Date
    public let newestAcceptedPublication: Date?
    public let maximumManifestAge: TimeInterval
    public let futureTolerance: TimeInterval

    public init(
        currentVersion: ReleaseVersion,
        channel: UpdateChannel,
        bundleIdentifier: String,
        artifactName: String,
        maximumArtifactBytes: UInt64,
        currentSystem: OperatingSystemVersion,
        now: Date,
        newestAcceptedPublication: Date? = nil,
        maximumManifestAge: TimeInterval = 90 * 24 * 60 * 60,
        futureTolerance: TimeInterval = 5 * 60
    ) {
        self.currentVersion = currentVersion
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.artifactName = artifactName
        self.maximumArtifactBytes = maximumArtifactBytes
        self.currentSystem = currentSystem
        self.now = now
        self.newestAcceptedPublication = newestAcceptedPublication
        self.maximumManifestAge = maximumManifestAge
        self.futureTolerance = futureTolerance
    }
}

public struct AuthenticatedReleaseManifest: Equatable, Sendable {
    public let manifest: ReleaseManifest

    fileprivate init(manifest: ReleaseManifest) {
        self.manifest = manifest
    }
}

public enum ReleaseManifestCodec {
    private static let expectedKeys = [
        "version",
        "channel",
        "bundle-id",
        "artifact-name",
        "artifact-length",
        "artifact-sha256",
        "minimum-macos",
        "published-at"
    ]

    public static func encode(_ manifest: ReleaseManifest) throws -> Data {
        try validateFields(manifest)
        let fields = [
            manifest.version.tag,
            manifest.channel.rawValue,
            manifest.bundleIdentifier,
            manifest.artifactName,
            String(manifest.artifactLength),
            manifest.artifactSHA256,
            operatingSystemText(manifest.minimumMacOS),
            timestampFormatter().string(from: manifest.publishedAt)
        ]
        var lines = [ReleaseManifest.header]
        for (key, value) in zip(expectedKeys, fields) {
            lines.append("\(key)=\(value)")
        }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8),
              data.count <= ReleaseManifest.maximumEncodedBytes else {
            throw ReleaseManifestFailure.oversizedManifest
        }
        return data
    }

    public static func decodeCanonical(_ data: Data) throws -> ReleaseManifest {
        guard data.count <= ReleaseManifest.maximumEncodedBytes else {
            throw ReleaseManifestFailure.oversizedManifest
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("\r"),
              text.hasSuffix("\n") else {
            throw ReleaseManifestFailure.invalidEncoding
        }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == expectedKeys.count + 1,
              lines.first == Substring(ReleaseManifest.header) else {
            throw ReleaseManifestFailure.nonCanonicalManifest
        }

        var values: [String] = []
        values.reserveCapacity(expectedKeys.count)
        for (index, key) in expectedKeys.enumerated() {
            let line = lines[index + 1]
            let prefix = "\(key)="
            guard line.hasPrefix(prefix) else {
                throw ReleaseManifestFailure.nonCanonicalManifest
            }
            values.append(String(line.dropFirst(prefix.count)))
        }

        guard let channel = UpdateChannel(rawValue: values[1]),
              let version = ReleaseVersion.parse(tag: values[0], channel: channel),
              let artifactLength = parseUnsigned(values[4]),
              let minimumMacOS = parseOperatingSystem(values[6]),
              let publishedAt = timestampFormatter().date(from: values[7]) else {
            throw ReleaseManifestFailure.invalidField("typed-value")
        }
        let manifest = ReleaseManifest(
            version: version,
            channel: channel,
            bundleIdentifier: values[2],
            artifactName: values[3],
            artifactLength: artifactLength,
            artifactSHA256: values[5],
            minimumMacOS: minimumMacOS,
            publishedAt: publishedAt
        )
        try validateFields(manifest)
        guard try encode(manifest) == data else {
            throw ReleaseManifestFailure.nonCanonicalManifest
        }
        return manifest
    }

    private static func validateFields(_ manifest: ReleaseManifest) throws {
        guard manifest.version.channel == manifest.channel else {
            throw ReleaseManifestFailure.invalidField("version")
        }
        guard isStrictIdentifier(manifest.bundleIdentifier) else {
            throw ReleaseManifestFailure.invalidField("bundle-id")
        }
        guard isStrictArtifactName(manifest.artifactName) else {
            throw ReleaseManifestFailure.invalidField("artifact-name")
        }
        guard manifest.artifactLength > 0 else {
            throw ReleaseManifestFailure.invalidField("artifact-length")
        }
        guard manifest.artifactSHA256.utf8.count == 64,
              manifest.artifactSHA256.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw ReleaseManifestFailure.invalidField("artifact-sha256")
        }
        guard manifest.minimumMacOS.majorVersion >= 1,
              manifest.minimumMacOS.minorVersion >= 0,
              manifest.minimumMacOS.patchVersion >= 0 else {
            throw ReleaseManifestFailure.invalidField("minimum-macos")
        }
    }

    private static func isStrictIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.contains("."), value.first != ".", value.last != ".",
              !value.contains("..") else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46
        }
    }

    private static func isStrictArtifactName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160,
              value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("..") else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func parseUnsigned(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value == "0" || value.first != "0",
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(value)
    }

    private static func parseOperatingSystem(_ value: String) -> OperatingSystemVersion? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        let parsed = components.map { component -> Int? in
            let text = String(component)
            guard !text.isEmpty, text == "0" || text.first != "0",
                  text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int(text)
        }
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        return OperatingSystemVersion(
            majorVersion: parsed[0]!,
            minorVersion: parsed[1]!,
            patchVersion: components.count == 3 ? parsed[2]! : 0
        )
    }

    private static func operatingSystemText(_ version: OperatingSystemVersion) -> String {
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

public enum ReleaseManifestVerifier {
    public static func verify(
        manifestData: Data,
        signature: Data,
        publicKey: Data,
        artifactURL: URL,
        policy: ReleaseManifestPolicy
    ) throws -> ReleaseManifest {
        let authenticated = try authenticateManifest(
            manifestData: manifestData,
            signature: signature,
            publicKey: publicKey,
            policy: policy
        )
        let manifest = authenticated.manifest
        guard artifactURL.lastPathComponent == policy.artifactName else {
            throw ReleaseManifestFailure.wrongArtifactName
        }
        let artifact = try inspectArtifact(at: artifactURL, maximumBytes: policy.maximumArtifactBytes)
        guard manifest.artifactLength == artifact.length else {
            throw ReleaseManifestFailure.artifactLengthMismatch
        }
        guard manifest.artifactSHA256 == artifact.sha256 else {
            throw ReleaseManifestFailure.artifactDigestMismatch
        }
        return manifest
    }

    public static func authenticateManifest(
        manifestData: Data,
        signature: Data,
        publicKey: Data,
        policy: ReleaseManifestPolicy
    ) throws -> AuthenticatedReleaseManifest {
        let manifest = try ReleaseManifestCodec.decodeCanonical(manifestData)
        let verifier: Curve25519.Signing.PublicKey
        do {
            verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw ReleaseManifestFailure.invalidPublicKey
        }
        guard signature.count == 64,
              verifier.isValidSignature(signature, for: manifestData) else {
            throw ReleaseManifestFailure.invalidSignature
        }
        guard manifest.channel == policy.channel,
              policy.currentVersion.channel == policy.channel else {
            throw ReleaseManifestFailure.wrongChannel
        }
        guard manifest.version > policy.currentVersion else {
            throw ReleaseManifestFailure.downgrade
        }
        if let newestAcceptedPublication = policy.newestAcceptedPublication,
           manifest.publishedAt <= newestAcceptedPublication {
            throw ReleaseManifestFailure.replay
        }
        guard policy.maximumManifestAge >= 0,
              policy.now.timeIntervalSince(manifest.publishedAt) <= policy.maximumManifestAge else {
            throw ReleaseManifestFailure.staleManifest
        }
        guard policy.futureTolerance >= 0,
              manifest.publishedAt.timeIntervalSince(policy.now) <= policy.futureTolerance else {
            throw ReleaseManifestFailure.futurePublication
        }
        guard manifest.bundleIdentifier == policy.bundleIdentifier else {
            throw ReleaseManifestFailure.wrongBundleIdentifier
        }
        guard manifest.artifactName == policy.artifactName else {
            throw ReleaseManifestFailure.wrongArtifactName
        }
        guard manifest.artifactLength <= policy.maximumArtifactBytes else {
            throw ReleaseManifestFailure.oversizedArtifact
        }
        guard system(policy.currentSystem, supports: manifest.minimumMacOS) else {
            throw ReleaseManifestFailure.unsupportedSystem
        }
        return AuthenticatedReleaseManifest(manifest: manifest)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func system(
        _ current: OperatingSystemVersion,
        supports minimum: OperatingSystemVersion
    ) -> Bool {
        if current.majorVersion != minimum.majorVersion {
            return current.majorVersion > minimum.majorVersion
        }
        if current.minorVersion != minimum.minorVersion {
            return current.minorVersion > minimum.minorVersion
        }
        return current.patchVersion >= minimum.patchVersion
    }

    private struct ArtifactEvidence {
        let length: UInt64
        let sha256: String
    }

    private static func inspectArtifact(
        at url: URL,
        maximumBytes: UInt64
    ) throws -> ArtifactEvidence {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ReleaseManifestFailure.invalidArtifact
        }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0 else {
            throw ReleaseManifestFailure.invalidArtifact
        }
        let initialLength = UInt64(before.st_size)
        guard initialLength <= maximumBytes else {
            throw ReleaseManifestFailure.oversizedArtifact
        }

        var total: UInt64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReleaseManifestFailure.invalidArtifact
            }
            total += UInt64(count)
            guard total <= maximumBytes else {
                throw ReleaseManifestFailure.oversizedArtifact
            }
            hasher.update(data: Data(buffer[0..<count]))
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw ReleaseManifestFailure.invalidArtifact
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              total == initialLength else {
            throw ReleaseManifestFailure.artifactChangedDuringVerification
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ArtifactEvidence(length: total, sha256: digest)
    }
}
