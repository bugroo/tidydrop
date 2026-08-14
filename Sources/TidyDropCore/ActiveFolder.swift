import Foundation

public struct ActiveFolderValidation: Equatable, Sendable {
    public let configuredPath: String
    public let canonicalPath: String
    public let exists: Bool
    public let readable: Bool
    public let writable: Bool
    public let isSymbolicLink: Bool
    public let deviceID: UInt64?
    public let filesystemType: String?

    public init(
        configuredPath: String,
        canonicalPath: String,
        exists: Bool,
        readable: Bool,
        writable: Bool,
        isSymbolicLink: Bool,
        deviceID: UInt64?,
        filesystemType: String?
    ) {
        self.configuredPath = configuredPath
        self.canonicalPath = canonicalPath
        self.exists = exists
        self.readable = readable
        self.writable = writable
        self.isSymbolicLink = isSymbolicLink
        self.deviceID = deviceID
        self.filesystemType = filesystemType
    }
}

public enum FolderSelectionResult: Equatable, Sendable {
    case cancelled
    case changed(ActiveFolderValidation)
}

public enum ActiveFolderManager {
    public static func validate(
        path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        requireAvailable: Bool = true
    ) throws -> ActiveFolderValidation {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StewardError.invalidConfiguration("la carpeta activa está vacía")
        }
        guard !trimmed.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw StewardError.unsafePath("la carpeta activa no puede contener componentes ..")
        }

        let expanded = ConfigurationIO.expand(trimmed, homeDirectory: homeDirectory).standardizedFileURL
        guard expanded.path.hasPrefix("/") else {
            throw StewardError.unsafePath("la carpeta activa debe ser absoluta")
        }
        try rejectProtectedScope(expanded, homeDirectory: homeDirectory)

        let metadata: POSIXMetadata
        do {
            metadata = try FileSystemSecurity.freshPOSIXMetadata(of: expanded)
        } catch {
            if requireAvailable { throw StewardError.sourceUnavailable("\(expanded.path): \(error)") }
            return unavailableValidation(configuredPath: trimmed, expandedPath: expanded.path)
        }

        guard metadata.kind != .symbolicLink else {
            throw StewardError.unsafePath("la carpeta activa no puede ser un enlace simbólico: \(expanded.path)")
        }
        guard metadata.kind == .directory else {
            throw StewardError.unsafePath("la carpeta activa no es un directorio: \(expanded.path)")
        }

        let canonical = expanded.resolvingSymlinksInPath().standardizedFileURL
        try rejectProtectedScope(canonical, homeDirectory: homeDirectory)
        let filesystem = filesystemType(at: canonical)
        if let filesystem, pseudoFilesystems.contains(filesystem.lowercased()) {
            throw StewardError.unsafePath("filesystem no permitido para carpeta activa: \(filesystem)")
        }

        let manager = FileManager.default
        let readable = manager.isReadableFile(atPath: canonical.path)
        let writable = manager.isWritableFile(atPath: canonical.path)
        guard readable else {
            throw StewardError.sourceUnavailable("sin acceso de lectura: \(canonical.path)")
        }
        guard writable else {
            throw StewardError.sourceUnavailable("sin acceso de escritura: \(canonical.path)")
        }

        return ActiveFolderValidation(
            configuredPath: trimmed,
            canonicalPath: canonical.path,
            exists: true,
            readable: readable,
            writable: writable,
            isSymbolicLink: false,
            deviceID: metadata.deviceID,
            filesystemType: filesystem
        )
    }

    public static func set(
        path: String,
        configurationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ActiveFolderValidation {
        let validation = try validate(path: path, homeDirectory: homeDirectory)
        let resolved = try ConfigurationIO.load(from: configurationURL, homeDirectory: homeDirectory)
        let selected = URL(fileURLWithPath: validation.canonicalPath, isDirectory: true)
        for internalPath in [resolved.paths.stateDirectory, resolved.paths.logDirectory] {
            if ConfigurationIO.isSameOrDescendant(selected, of: internalPath)
                || ConfigurationIO.isSameOrDescendant(internalPath, of: selected) {
                throw StewardError.unsafePath(
                    "la carpeta activa coincide, contiene o está dentro de state/log: \(validation.canonicalPath)"
                )
            }
        }
        var config = resolved.config
        config.paths.sourceDirectory = validation.canonicalPath
        config.paths.destinationRoot = validation.canonicalPath
        config.automation.applyEnabled = false
        try ConfigurationIO.save(config, to: configurationURL)
        return validation
    }

    public static func resetToDownloads(
        configurationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ActiveFolderValidation {
        try set(
            path: homeDirectory.appendingPathComponent("Downloads", isDirectory: true).path,
            configurationURL: configurationURL,
            homeDirectory: homeDirectory
        )
    }

    public static func applySelection(
        _ selectedURL: URL?,
        configurationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> FolderSelectionResult {
        guard let selectedURL else { return .cancelled }
        return .changed(try set(
            path: selectedURL.path,
            configurationURL: configurationURL,
            homeDirectory: homeDirectory
        ))
    }

    private static let pseudoFilesystems: Set<String> = [
        "autofs", "devfs", "fdesc", "procfs", "sysfs"
    ]

    private static func unavailableValidation(configuredPath: String, expandedPath: String) -> ActiveFolderValidation {
        ActiveFolderValidation(
            configuredPath: configuredPath,
            canonicalPath: expandedPath,
            exists: false,
            readable: false,
            writable: false,
            isSymbolicLink: false,
            deviceID: nil,
            filesystemType: nil
        )
    }

    private static func rejectProtectedScope(_ candidate: URL, homeDirectory: URL) throws {
        let canonicalCandidate = candidate.standardizedFileURL
        let canonicalHome = homeDirectory.standardizedFileURL
        let explicitForbidden = [
            URL(fileURLWithPath: "/", isDirectory: true),
            canonicalHome,
            canonicalHome.appendingPathComponent("Library", isDirectory: true)
        ]
        if explicitForbidden.contains(where: { $0.standardizedFileURL.path == canonicalCandidate.path }) {
            throw StewardError.unsafePath("carpeta activa prohibida: \(canonicalCandidate.path)")
        }

        let internals = [
            canonicalHome.appendingPathComponent("Applications/TidyDrop.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/TidyDrop.app", isDirectory: true),
            canonicalHome.appendingPathComponent("Library/Application Support/TidyDrop", isDirectory: true),
            canonicalHome.appendingPathComponent("Library/Logs/TidyDrop", isDirectory: true)
        ]
        for internalURL in internals {
            if ConfigurationIO.isSameOrDescendant(canonicalCandidate, of: internalURL)
                || ConfigurationIO.isSameOrDescendant(internalURL, of: canonicalCandidate) {
                throw StewardError.unsafePath(
                    "la carpeta activa coincide, contiene o está dentro de una ruta interna de TidyDrop: \(canonicalCandidate.path)"
                )
            }
        }

        let pseudoPrefixes = ["/dev", "/proc", "/sys"]
        if pseudoPrefixes.contains(where: {
            canonicalCandidate.path == $0 || canonicalCandidate.path.hasPrefix($0 + "/")
        }) {
            throw StewardError.unsafePath("pseudo-filesystem no permitido: \(canonicalCandidate.path)")
        }
    }

    private static func filesystemType(at url: URL) -> String? {
        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        return try? freshURL.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey])
            .volumeLocalizedFormatDescription
    }
}
