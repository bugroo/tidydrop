import Foundation

public enum WorkbenchData {
    public static func auditEvents(
        at auditLogURL: URL,
        rotatedFileCount: Int,
        maximumFileBytes: UInt64,
        limit: Int
    ) throws -> [AuditEvent] {
        guard (0...100).contains(rotatedFileCount) else {
            throw StewardError.invalidConfiguration("rotated_file_count is outside the supported range")
        }
        guard maximumFileBytes > 0, limit > 0, limit <= 10_000 else {
            throw StewardError.invalidConfiguration("invalid workbench audit read limits")
        }

        var files: [URL] = []
        if rotatedFileCount > 0 {
            for index in stride(from: rotatedFileCount, through: 1, by: -1) {
                files.append(URL(fileURLWithPath: auditLogURL.path + ".\(index)"))
            }
        }
        files.append(auditLogURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [AuditEvent] = []
        events.reserveCapacity(min(limit, 512))

        for file in files {
            guard try FileSystemSecurity.pathEntryExists(file) else { continue }
            let data = try FileSystemSecurity.readRegularFile(
                file,
                maximumBytes: maximumFileBytes
            )
            guard let contents = String(data: data, encoding: .utf8) else {
                throw StewardError.commandFailed(
                    "Audit history is not valid UTF-8: \(file.lastPathComponent)"
                )
            }
            for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: true)
                .enumerated() {
                do {
                    events.append(try decoder.decode(AuditEvent.self, from: Data(line.utf8)))
                } catch {
                    throw StewardError.commandFailed(
                        "Audit history contains an invalid record at \(file.lastPathComponent):\(offset + 1)"
                    )
                }
            }
        }

        return Array(events.suffix(limit).reversed())
    }

    @discardableResult
    public static func replaceCategory(
        at index: Int,
        with category: CategoryRule,
        configurationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ResolvedConfiguration {
        let resolved = try ConfigurationIO.load(
            from: configurationURL,
            homeDirectory: homeDirectory
        )
        guard resolved.config.classification.categories.indices.contains(index) else {
            throw StewardError.invalidConfiguration("category index is outside the configured rules")
        }

        var configuration = resolved.config
        configuration.classification.categories[index] = category
        configuration.automation.applyEnabled = false
        try ConfigurationIO.validate(configuration)
        try ConfigurationIO.save(configuration, to: configurationURL)
        return try ConfigurationIO.load(from: configurationURL, homeDirectory: homeDirectory)
    }
}

public extension TransactionManifest {
    var containsUndoableMove: Bool {
        status != .fullyUndone && moves.contains {
            $0.executionStatus == .completed && $0.undoStatus != .undone
        }
    }
}

