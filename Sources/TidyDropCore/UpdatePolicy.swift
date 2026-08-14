import Foundation

public enum UpdateChannel: String, Sendable {
    case community
    case stable
}

public struct ReleaseVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let communitySequence: Int?

    public var channel: UpdateChannel {
        communitySequence == nil ? .stable : .community
    }

    public var tag: String {
        let base = "v\(major).\(minor).\(patch)"
        guard let communitySequence else { return base }
        return "\(base)-community.\(communitySequence)"
    }

    public static func parse(tag: String, channel: UpdateChannel) -> ReleaseVersion? {
        guard tag.utf8.count <= 64, tag.first == "v" else { return nil }
        let versionText = String(tag.dropFirst())
        let baseText: String
        let sequence: Int?

        switch channel {
        case .stable:
            guard !versionText.contains("-") else { return nil }
            baseText = versionText
            sequence = nil
        case .community:
            let marker = "-community."
            guard let markerRange = versionText.range(of: marker),
                  markerRange.upperBound < versionText.endIndex,
                  versionText[markerRange.upperBound...].firstIndex(of: "-") == nil else {
                return nil
            }
            baseText = String(versionText[..<markerRange.lowerBound])
            guard let parsedSequence = parseNumericComponent(
                String(versionText[markerRange.upperBound...])
            ), parsedSequence > 0 else {
                return nil
            }
            sequence = parsedSequence
        }

        let components = baseText.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = parseNumericComponent(String(components[0])),
              let minor = parseNumericComponent(String(components[1])),
              let patch = parseNumericComponent(String(components[2])) else {
            return nil
        }
        return ReleaseVersion(
            major: major,
            minor: minor,
            patch: patch,
            communitySequence: sequence
        )
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let lhsBase = (lhs.major, lhs.minor, lhs.patch)
        let rhsBase = (rhs.major, rhs.minor, rhs.patch)
        if lhsBase.0 != rhsBase.0 { return lhsBase.0 < rhsBase.0 }
        if lhsBase.1 != rhsBase.1 { return lhsBase.1 < rhsBase.1 }
        if lhsBase.2 != rhsBase.2 { return lhsBase.2 < rhsBase.2 }
        return (lhs.communitySequence ?? 0) < (rhs.communitySequence ?? 0)
    }

    private static func parseNumericComponent(_ text: String) -> Int? {
        guard !text.isEmpty,
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              text == "0" || text.first != "0" else {
            return nil
        }
        return Int(text)
    }
}

public struct ReleaseMetadata: Decodable, Equatable, Sendable {
    public let tagName: String
    public let name: String?
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: String?

    public init(
        tagName: String,
        name: String? = nil,
        draft: Bool,
        prerelease: Bool,
        publishedAt: String? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case draft
        case prerelease
        case publishedAt = "published_at"
    }
}

public struct AvailableRelease: Equatable, Sendable {
    public let version: ReleaseVersion
    public let displayName: String
    public let publishedAt: String?
    public let officialPageURL: URL

    public init(
        version: ReleaseVersion,
        displayName: String,
        publishedAt: String?,
        officialPageURL: URL
    ) {
        self.version = version
        self.displayName = displayName
        self.publishedAt = publishedAt
        self.officialPageURL = officialPageURL
    }
}

public enum ReleaseSelectionPolicy {
    public static let maximumReleaseCount = 50

    public static func latestNewerRelease(
        in releases: [ReleaseMetadata],
        channel: UpdateChannel,
        currentVersion: ReleaseVersion
    ) -> AvailableRelease? {
        guard currentVersion.channel == channel else { return nil }

        return releases.prefix(maximumReleaseCount).compactMap { metadata in
            candidate(from: metadata, channel: channel, currentVersion: currentVersion)
        }.max { $0.version < $1.version }
    }

    public static func officialReleasePageURL(for version: ReleaseVersion) -> URL? {
        URL(string: "https://github.com/bugroo/tidydrop/releases/tag/\(version.tag)")
    }

    private static func candidate(
        from metadata: ReleaseMetadata,
        channel: UpdateChannel,
        currentVersion: ReleaseVersion
    ) -> AvailableRelease? {
        guard !metadata.draft else { return nil }
        switch channel {
        case .community where !metadata.prerelease:
            return nil
        case .stable where metadata.prerelease:
            return nil
        default:
            break
        }
        guard let version = ReleaseVersion.parse(tag: metadata.tagName, channel: channel),
              version > currentVersion,
              let officialPageURL = officialReleasePageURL(for: version) else {
            return nil
        }
        let trimmedName = metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName: String
        if let trimmedName, !trimmedName.isEmpty, trimmedName.utf8.count <= 160 {
            displayName = trimmedName
        } else {
            displayName = version.tag
        }
        let publishedAt = metadata.publishedAt.flatMap { value in
            value.utf8.count <= 64 ? value : nil
        }
        return AvailableRelease(
            version: version,
            displayName: displayName,
            publishedAt: publishedAt,
            officialPageURL: officialPageURL
        )
    }
}
