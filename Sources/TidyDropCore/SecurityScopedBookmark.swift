import Foundation

public struct ResolvedSecurityScopedBookmark {
    public let url: URL
    public let isStale: Bool
}

public enum SecurityScopedBookmark {
    public static let maximumBytes = 1_048_576

    public static func create(for directory: URL) throws -> Data {
#if os(macOS)
        let canonical = ConfigurationIO.canonicalURL(directory)
        let metadata = try FileSystemSecurity.freshPOSIXMetadata(of: canonical)
        guard metadata.kind == .directory else {
            throw StewardError.unsafePath("bookmark target must be a real directory")
        }
        let data = try canonical.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw StewardError.commandFailed("security-scoped bookmark has an invalid size")
        }
        return data
#else
        throw StewardError.commandFailed("security-scoped bookmarks are available only on macOS")
#endif
    }

    public static func resolve(_ data: Data) throws -> ResolvedSecurityScopedBookmark {
#if os(macOS)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw StewardError.commandFailed("security-scoped bookmark has an invalid size")
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedSecurityScopedBookmark(
            url: ConfigurationIO.canonicalURL(url),
            isStale: isStale
        )
#else
        throw StewardError.commandFailed("security-scoped bookmarks are available only on macOS")
#endif
    }

    public static func withAccess<Result>(
        to data: Data,
        _ body: (ResolvedSecurityScopedBookmark) throws -> Result
    ) throws -> Result {
#if os(macOS)
        let resolved = try resolve(data)
        let started = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if started {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
        guard started
                || (FileManager.default.isReadableFile(atPath: resolved.url.path)
                    && FileManager.default.isWritableFile(atPath: resolved.url.path)) else {
            throw StewardError.sourceUnavailable(resolved.url.path)
        }
        return try body(resolved)
#else
        throw StewardError.commandFailed("security-scoped bookmarks are available only on macOS")
#endif
    }
}
