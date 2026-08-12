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
    public let isHidden: Bool

    public var modificationTime: TimeInterval {
        TimeInterval(modificationSeconds) + TimeInterval(modificationNanoseconds) / 1_000_000_000
    }

    public var creationTime: TimeInterval? {
        guard let creationSeconds, let creationNanoseconds else { return nil }
        return TimeInterval(creationSeconds) + TimeInterval(creationNanoseconds) / 1_000_000_000
    }
}

public enum FileSystemSecurity {
    public static let defaultJSONMaximumBytes: UInt64 = 67_108_864

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
        let isHidden = information.st_flags & UInt32(UF_HIDDEN) != 0
#else
        let modificationSeconds = Int64(information.st_mtim.tv_sec)
        let modificationNanoseconds = Int64(information.st_mtim.tv_nsec)
        let birthSeconds: Int64? = nil
        let birthNanoseconds: Int64? = nil
        let isHidden = false
#endif

        return POSIXMetadata(
            kind: kind,
            size: UInt64(information.st_size),
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            creationSeconds: birthSeconds,
            creationNanoseconds: birthNanoseconds,
            deviceID: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            isHidden: isHidden
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
        let descriptor = try openDirectoryWithoutFollowingSymlinks(url)
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_uid == geteuid() else {
            throw StewardError.unsafePath("el directorio privado no pertenece al usuario actual: \(url.path)")
        }
        guard fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
            throw StewardError.commandFailed(
                "No se pudieron fijar permisos privados en \(url.path): \(String(cString: strerror(errno)))"
            )
        }
    }

    public static func setPrivateFilePermissions(_ url: URL) throws {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed(
                "No se pudo abrir para fijar permisos \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == geteuid() else {
            throw StewardError.unsafePath("archivo no regular o de otro usuario: \(url.path)")
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw StewardError.commandFailed(
                "No se pudieron fijar permisos privados en \(url.path): \(String(cString: strerror(errno)))"
            )
        }
    }

    public static func ensureRegularFileExists(_ url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        if try !pathEntryExists(url) {
            let descriptor = url.path.withCString { path in
                open(
                    path,
                    O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor >= 0 {
                close(descriptor)
            } else if errno != EEXIST {
                throw StewardError.commandFailed(
                    "No se pudo crear de forma segura \(url.path): \(String(cString: strerror(errno)))"
                )
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

    public static func pathEntryExists(_ url: URL) throws -> Bool {
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

    public static func readRegularFile(
        _ url: URL,
        maximumBytes: UInt64 = defaultJSONMaximumBytes,
        requireCurrentUserOwner: Bool = true
    ) throws -> Data {
        guard maximumBytes > 0, maximumBytes < UInt64(Int.max) else {
            throw StewardError.commandFailed("Límite de lectura no válido para \(url.path)")
        }

        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                throw StewardError.sourceUnavailable(url.path)
            }
            throw StewardError.commandFailed(
                "No se pudo abrir de forma segura \(url.path): \(String(cString: strerror(errorNumber)))"
            )
        }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let errorNumber = errno
            close(descriptor)
            throw StewardError.commandFailed(
                "No se pudo inspeccionar el descriptor de \(url.path): \(String(cString: strerror(errorNumber)))"
            )
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(descriptor)
            throw StewardError.unsafePath("se esperaba un archivo regular sin symlink: \(url.path)")
        }
        if requireCurrentUserOwner, information.st_uid != geteuid() {
            close(descriptor)
            throw StewardError.unsafePath("el archivo no pertenece al usuario actual: \(url.path)")
        }
        guard information.st_mode & mode_t(0o022) == 0 else {
            close(descriptor)
            throw StewardError.unsafePath("el archivo permite escritura de grupo u otros: \(url.path)")
        }
        guard information.st_size >= 0, UInt64(information.st_size) <= maximumBytes else {
            close(descriptor)
            throw StewardError.commandFailed(
                "Archivo demasiado grande para lectura segura (máximo \(maximumBytes) bytes): \(url.path)"
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data: Data
        do {
            data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw StewardError.commandFailed("No se pudo leer \(url.path): \(error)")
        }
        guard UInt64(data.count) <= maximumBytes else {
            throw StewardError.commandFailed(
                "El archivo creció durante la lectura y superó \(maximumBytes) bytes: \(url.path)"
            )
        }
        return data
    }

    public static func atomicWritePrivate(
        _ data: Data,
        to url: URL,
        maximumBytes: UInt64 = defaultJSONMaximumBytes
    ) throws {
        guard UInt64(data.count) <= maximumBytes else {
            throw StewardError.commandFailed(
                "Datos demasiado grandes para escritura segura (máximo \(maximumBytes) bytes): \(url.path)"
            )
        }
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let filename = url.lastPathComponent
        guard isSafeDirectChildName(filename) else {
            throw StewardError.unsafePath("nombre no válido para escritura atómica: \(url.path)")
        }
        if try pathEntryExists(url) {
            _ = try readRegularFile(url, maximumBytes: maximumBytes)
        }

        let directoryDescriptor = try openDirectoryWithoutFollowingSymlinks(
            url.deletingLastPathComponent()
        )
        defer { close(directoryDescriptor) }
        let temporaryName = ".\(filename).tmp.\(UUID().uuidString)"
        let descriptor = temporaryName.withCString { name in
            openat(
                directoryDescriptor,
                name,
                O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed(
                "No se pudo crear el archivo temporal privado: \(String(cString: strerror(errno)))"
            )
        }

        var writeError: Int32?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    break
                }
                offset += count
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = errno
        }
        close(descriptor)

        if let writeError {
            temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            throw StewardError.commandFailed(
                "No se pudo persistir el archivo temporal privado: \(String(cString: strerror(writeError)))"
            )
        }

        let renameResult = temporaryName.withCString { temporaryPointer in
            filename.withCString { filenamePointer in
                renameat(directoryDescriptor, temporaryPointer, directoryDescriptor, filenamePointer)
            }
        }
        guard renameResult == 0 else {
            let errorNumber = errno
            temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            throw StewardError.commandFailed(
                "No se pudo publicar el archivo privado: \(String(cString: strerror(errorNumber)))"
            )
        }
        _ = fsync(directoryDescriptor)
    }

    public static func moveRegularFileExclusively(
        from source: URL,
        to destination: URL,
        expectedSnapshot: FileSnapshot
    ) throws {
        let sourceParent = source.deletingLastPathComponent()
        let destinationParent = destination.deletingLastPathComponent()
        let sourceName = source.lastPathComponent
        let destinationName = destination.lastPathComponent
        guard isSafeDirectChildName(sourceName), isSafeDirectChildName(destinationName) else {
            throw StewardError.unsafePath("nombre de archivo no válido para movimiento exclusivo")
        }

        let sourceDirectoryDescriptor = try openDirectoryWithoutFollowingSymlinks(sourceParent)
        defer { close(sourceDirectoryDescriptor) }
        let destinationDirectoryDescriptor = try openDirectoryWithoutFollowingSymlinks(destinationParent)
        defer { close(destinationDirectoryDescriptor) }

        var sourceDirectoryInfo = stat()
        var destinationDirectoryInfo = stat()
        guard fstat(sourceDirectoryDescriptor, &sourceDirectoryInfo) == 0,
              fstat(destinationDirectoryDescriptor, &destinationDirectoryInfo) == 0 else {
            throw StewardError.commandFailed("No se pudieron validar los directorios del movimiento")
        }
        guard sourceDirectoryInfo.st_dev == destinationDirectoryInfo.st_dev else {
            throw StewardError.unsafePath("el movimiento exclusivo cruza sistemas de archivos")
        }

        var sourceInfo = stat()
        let sourceResult = sourceName.withCString { name in
            fstatat(sourceDirectoryDescriptor, name, &sourceInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceResult == 0 else {
            throw StewardError.commandFailed(
                "No se pudo validar el origen justo antes del rename: \(String(cString: strerror(errno)))"
            )
        }
        guard sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw StewardError.unsafePath("el origen dejó de ser un archivo regular")
        }
        guard expectedSnapshot.matchesFreshPOSIXStat(sourceInfo) else {
            throw StewardError.commandFailed("changed_before_move")
        }

#if os(macOS)
        let result = sourceName.withCString { sourcePointer in
            destinationName.withCString { destinationPointer in
                renameatx_np(
                    sourceDirectoryDescriptor,
                    sourcePointer,
                    destinationDirectoryDescriptor,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
#else
        // Linux validation fallback: linkat is exclusive and never overwrites.
        // Both paths are regular files on one filesystem, so linking preserves
        // identity; unlinking the source completes the move.
        let result = sourceName.withCString { sourcePointer in
            destinationName.withCString { destinationPointer in
                let linked = linkat(
                    sourceDirectoryDescriptor,
                    sourcePointer,
                    destinationDirectoryDescriptor,
                    destinationPointer,
                    0
                )
                guard linked == 0 else { return linked }
                let unlinked = unlinkat(sourceDirectoryDescriptor, sourcePointer, 0)
                if unlinked != 0 {
                    _ = unlinkat(destinationDirectoryDescriptor, destinationPointer, 0)
                }
                return unlinked
            }
        }
#endif
        guard result == 0 else {
            let errorNumber = errno
            if errorNumber == EEXIST {
                throw StewardError.commandFailed("destination_collision")
            }
            throw StewardError.commandFailed(
                "El movimiento exclusivo falló: \(String(cString: strerror(errorNumber)))"
            )
        }
    }

    private static func openDirectoryWithoutFollowingSymlinks(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StewardError.unsafePath(
                "no se pudo abrir el directorio sin seguir symlinks: \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        return descriptor
    }

    private static func isSafeDirectChildName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func appendWithoutRotation(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed(
                "No se pudo abrir el log de forma segura: \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == geteuid() else {
            throw StewardError.unsafePath("el log no es regular o no pertenece al usuario: \(url.path)")
        }
        var writeError: Int32?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    break
                }
                offset += count
            }
        }
        if let writeError {
            throw StewardError.commandFailed(
                "No se pudo escribir el log: \(String(cString: strerror(writeError)))"
            )
        }
        guard fsync(descriptor) == 0 else {
            throw StewardError.commandFailed(
                "No se pudo sincronizar el log: \(String(cString: strerror(errno)))"
            )
        }
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

        return FileSnapshot(
            size: metadata.size,
            modificationTime: metadata.modificationTime,
            modificationSeconds: metadata.modificationSeconds,
            modificationNanoseconds: metadata.modificationNanoseconds,
            creationTime: metadata.creationTime,
            creationSeconds: metadata.creationSeconds,
            creationNanoseconds: metadata.creationNanoseconds,
            documentIdentifier: nil,
            fileIdentifier: nil,
            deviceID: metadata.deviceID,
            inode: metadata.inode
        )
    }

    public static func snapshot(of url: URL) throws -> FileSnapshot {
        try freshSnapshot(of: url)
    }

    public static func itemFacts(for url: URL) throws -> ItemFacts {
        let metadata = try freshPOSIXMetadata(of: URL(fileURLWithPath: url.path))
        let snapshot = metadata.kind == .regularFile ? try freshSnapshot(of: url) : nil
        return ItemFacts(
            isRegularFile: metadata.kind == .regularFile,
            isDirectory: metadata.kind == .directory,
            isSymbolicLink: metadata.kind == .symbolicLink,
            isHidden: metadata.isHidden || url.lastPathComponent.hasPrefix("."),
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
            open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode)
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed("No se pudo abrir el lock \(url.path): \(String(cString: strerror(errno)))")
        }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == geteuid() else {
            close(descriptor)
            descriptor = -1
            throw StewardError.unsafePath("el lock no es un archivo regular propiedad del usuario: \(url.path)")
        }
        _ = fchmod(descriptor, mode)

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
    public static func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        default defaultValue: @autoclosure () -> T,
        maximumBytes: UInt64 = FileSystemSecurity.defaultJSONMaximumBytes
    ) throws -> T {
        guard try FileSystemSecurity.pathEntryExists(url) else {
            return defaultValue()
        }
        let data = try FileSystemSecurity.readRegularFile(url, maximumBytes: maximumBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    public static func save<T: Encodable>(
        _ value: T,
        to url: URL,
        maximumBytes: UInt64 = FileSystemSecurity.defaultJSONMaximumBytes
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileSystemSecurity.atomicWritePrivate(data, to: url, maximumBytes: maximumBytes)
    }
}
