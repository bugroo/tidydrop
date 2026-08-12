import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif


public struct POSIXFileIdentity: Equatable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }
}

public enum POSIXEntryKind: String, Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public struct POSIXMetadata: Equatable, Sendable {
    public let kind: POSIXEntryKind
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let creationSeconds: Int64?
    public let creationNanoseconds: Int64?
    public let deviceID: UInt64
    public let inode: UInt64

    public var modificationTime: TimeInterval {
        TimeInterval(modificationSeconds) + TimeInterval(modificationNanoseconds) / 1_000_000_000
    }

    public var creationTime: TimeInterval? {
        guard let creationSeconds, let creationNanoseconds else { return nil }
        return TimeInterval(creationSeconds) + TimeInterval(creationNanoseconds) / 1_000_000_000
    }
}

public enum FileSystemSecurity {
    public static func freshPOSIXMetadata(of url: URL) throws -> POSIXMetadata {
        var information = stat()
        let result = url.path.withCString { pointer -> Int32 in
#if os(macOS)
            Darwin.lstat(pointer, &information)
#else
            Glibc.lstat(pointer, &information)
#endif
        }
        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                throw StewardError.sourceUnavailable(url.path)
            }
            throw StewardError.commandFailed(
                "No se pudo ejecutar lstat sobre \(url.path): \(String(cString: strerror(errorNumber)))"
            )
        }

        let fileType = information.st_mode & mode_t(S_IFMT)
        let kind: POSIXEntryKind
        switch fileType {
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        guard information.st_size >= 0 else {
            throw StewardError.commandFailed("Tamaño POSIX no válido: \(url.path)")
        }

#if os(macOS)
        let modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        let modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        let birthSeconds: Int64? = Int64(information.st_birthtimespec.tv_sec)
        let birthNanoseconds: Int64? = Int64(information.st_birthtimespec.tv_nsec)
#else
        let modificationSeconds = Int64(information.st_mtim.tv_sec)
        let modificationNanoseconds = Int64(information.st_mtim.tv_nsec)
        let birthSeconds: Int64? = nil
        let birthNanoseconds: Int64? = nil
#endif

        return POSIXMetadata(
            kind: kind,
            size: UInt64(information.st_size),
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            creationSeconds: birthSeconds,
            creationNanoseconds: birthNanoseconds,
            deviceID: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    public static func posixIdentity(of url: URL) throws -> POSIXFileIdentity {
        let information = try freshPOSIXMetadata(of: url)
        return POSIXFileIdentity(
            deviceID: information.deviceID,
            inode: information.inode
        )
    }

    public static func ensurePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if try pathEntryExists(url) {
            let metadata = try freshPOSIXMetadata(of: url)
            guard metadata.kind == .directory else {
                throw StewardError.unsafePath("se esperaba un directorio: \(url.path)")
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
    }

    public static func setPrivateFilePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    public static func ensureRegularFileExists(_ url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        if try !pathEntryExists(url) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw StewardError.commandFailed("No se pudo crear \(url.path)")
            }
        }
        _ = try regularFileSize(url)
        try setPrivateFilePermissions(url)
    }

    public static func append(_ data: Data, to url: URL) throws {
        try ensureRegularFileExists(url)
        try appendWithoutRotation(data, to: url)
    }

    public static func appendBounded(
        _ data: Data,
        to url: URL,
        maxBytes: UInt64,
        retainedFiles: Int
    ) throws {
        guard maxBytes > 0, retainedFiles >= 1 else {
            throw StewardError.invalidConfiguration("límites de log no válidos")
        }
        try ensureRegularFileExists(url)
        let currentSize = try regularFileSize(url)
        let incomingSize = UInt64(data.count)
        let wouldExceed = currentSize >= maxBytes
            || incomingSize > maxBytes
            || currentSize > maxBytes - incomingSize
        if currentSize > 0, wouldExceed {
            try rotateRegularFile(url, retainedFiles: retainedFiles)
        }
        try appendWithoutRotation(data, to: url)
    }

    public static func regularFileSize(_ url: URL) throws -> UInt64 {
        let metadata = try freshPOSIXMetadata(of: url)
        guard metadata.kind == .regularFile else {
            throw StewardError.unsafePath("se esperaba un archivo regular, no un enlace o directorio: \(url.path)")
        }
        return metadata.size
    }

    private static func pathEntryExists(_ url: URL) throws -> Bool {
        var information = stat()
        let result = url.path.withCString { pointer -> Int32 in
#if os(macOS)
            Darwin.lstat(pointer, &information)
#else
            Glibc.lstat(pointer, &information)
#endif
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw StewardError.commandFailed(
            "No se pudo inspeccionar \(url.path): \(String(cString: strerror(errno)))"
        )
    }

    private static func appendWithoutRotation(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func rotateRegularFile(_ url: URL, retainedFiles: Int) throws {
        let manager = FileManager.default
        for index in stride(from: retainedFiles, through: 1, by: -1) {
            let destination = url.appendingPathExtension(String(index))
            let source = index == 1
                ? url
                : url.appendingPathExtension(String(index - 1))

            if try pathEntryExists(destination) {
                _ = try regularFileSize(destination)
                // APP_OWNED_RETENTION: elimina únicamente la copia de log más antigua.
                try manager.removeItem(at: destination)
            }
            if try pathEntryExists(source) {
                _ = try regularFileSize(source)
                try manager.moveItem(at: source, to: destination)
                try setPrivateFilePermissions(destination)
            }
        }
        try ensureRegularFileExists(url)
    }

    public static func freshSnapshot(of url: URL) throws -> FileSnapshot {
        let metadata = try freshPOSIXMetadata(of: URL(fileURLWithPath: url.path))
        guard metadata.kind == .regularFile else {
            throw StewardError.commandFailed("No es un archivo regular sin symlink: \(url.path)")
        }

        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        let secondaryValues = try? freshURL.resourceValues(
            forKeys: [.documentIdentifierKey, .fileResourceIdentifierKey]
        )
        return FileSnapshot(
            size: metadata.size,
            modificationTime: metadata.modificationTime,
            modificationSeconds: metadata.modificationSeconds,
            modificationNanoseconds: metadata.modificationNanoseconds,
            creationTime: metadata.creationTime,
            creationSeconds: metadata.creationSeconds,
            creationNanoseconds: metadata.creationNanoseconds,
            documentIdentifier: secondaryValues?.documentIdentifier.map(Int64.init),
            fileIdentifier: secondaryValues?.fileResourceIdentifier.map { String(describing: $0) },
            deviceID: metadata.deviceID,
            inode: metadata.inode
        )
    }

    public static func snapshot(of url: URL) throws -> FileSnapshot {
        try freshSnapshot(of: url)
    }

    public static func itemFacts(for url: URL) throws -> ItemFacts {
        let metadata = try freshPOSIXMetadata(of: URL(fileURLWithPath: url.path))
        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        let hidden = (try? freshURL.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
        let snapshot = metadata.kind == .regularFile ? try freshSnapshot(of: freshURL) : nil
        return ItemFacts(
            isRegularFile: metadata.kind == .regularFile,
            isDirectory: metadata.kind == .directory,
            isSymbolicLink: metadata.kind == .symbolicLink,
            isHidden: hidden || url.lastPathComponent.hasPrefix("."),
            snapshot: snapshot
        )
    }
}

public struct ItemFacts: Equatable, Sendable {
    public let isRegularFile: Bool
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isHidden: Bool
    public let snapshot: FileSnapshot?

    public init(
        isRegularFile: Bool,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isHidden: Bool,
        snapshot: FileSnapshot?
    ) {
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.snapshot = snapshot
    }
}

public final class ProcessFileLock {
    private var descriptor: Int32 = -1
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileSystemSecurity.ensurePrivateDirectory(url.deletingLastPathComponent())

        let mode = mode_t(S_IRUSR | S_IWUSR)
        descriptor = url.path.withCString { path in
            open(path, O_CREAT | O_RDWR, mode)
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed("No se pudo abrir el lock \(url.path): \(String(cString: strerror(errno)))")
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let errorNumber = errno
            close(descriptor)
            descriptor = -1
            if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                throw StewardError.lockBusy(url.path)
            }
            throw StewardError.commandFailed(
                "No se pudo bloquear \(url.path): \(String(cString: strerror(errorNumber)))"
            )
        }

        let marker = "pid=\(getpid()) started=\(ISO8601DateFormatter().string(from: Date()))\n"
        _ = ftruncate(descriptor, 0)
        _ = marker.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
        _ = fsync(descriptor)
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

public enum JSONFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, default defaultValue: @autoclosure () -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileSystemSecurity.ensurePrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileSystemSecurity.setPrivateFilePermissions(url)
    }
}
