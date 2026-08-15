import Foundation
import SQLite3
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public struct StoredAgentRun: Equatable, Sendable {
    public let runID: String
    public let timestamp: Date
    public let outcome: ScheduledRunOutcome
    public let mode: String?
    public let scanned: Int?
    public let planned: Int?
    public let moved: Int?
    public let deferred: Int?
    public let skipped: Int?
    public let errors: Int?
    public let detail: String?
    public let sourceDirectory: String?
}

public enum AgentActivityDatabase {
    public static let schemaVersion: Int32 = 1
    public static let maximumRows = 1_000
    public static let maximumDatabaseBytes: UInt64 = 64 * 1_024 * 1_024

    public static func record(_ record: ScheduledRunRecord, at databaseURL: URL) throws {
        let connection = try SQLiteConnection(databaseURL: databaseURL, mode: .writer)
        try connection.migrate()
        try connection.record(record)
        try connection.enforceRetention(maximumRows: maximumRows)
        try connection.checkpoint()
        try connection.applyPrivatePermissions()
    }

    public static func recentRuns(at databaseURL: URL, limit: Int) throws -> [StoredAgentRun] {
        guard (1...maximumRows).contains(limit) else {
            throw StewardError.invalidConfiguration("invalid SQLite activity limit")
        }
        guard try FileSystemSecurity.pathEntryExists(databaseURL) else { return [] }
        let connection = try SQLiteConnection(databaseURL: databaseURL, mode: .reader)
        return try connection.recentRuns(limit: limit)
    }

    /// Verifies a closed recovery database without modifying it.
    @discardableResult
    public static func verifyRecoveryDatabase(at databaseURL: URL) throws -> Int32 {
        let connection = try SQLiteConnection(databaseURL: databaseURL, mode: .reader)
        return try connection.verifyRecoveryDatabase()
    }

    /// Checkpoints and closes a live activity database before an external
    /// recovery process replaces that exact file. An active writer fails
    /// closed; the caller must isolate any validated residual sidecars.
    public static func quiesceForRecoveryReplacement(at databaseURL: URL) throws {
        guard try pathEntryExists(databaseURL) else { return }
        let physicalURL = try physicalRegularFileURL(databaseURL)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
        let result = physicalURL.path.withCString {
            sqlite3_open_v2($0, &database, flags, nil)
        }
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw StewardError.commandFailed("SQLite recovery quiescence could not open live state")
        }
        var closeRequired = true
        defer {
            if closeRequired { sqlite3_close_v2(database) }
        }
        guard sqlite3_extended_result_codes(database, 1) == SQLITE_OK,
              sqlite3_busy_timeout(database, 0) == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery quiescence setup failed")
        }
        var framesInLog: Int32 = 0
        var framesCheckpointed: Int32 = 0
        guard sqlite3_wal_checkpoint_v2(
            database,
            "main",
            SQLITE_CHECKPOINT_TRUNCATE,
            &framesInLog,
            &framesCheckpointed
        ) == SQLITE_OK,
              framesInLog == framesCheckpointed else {
            throw StewardError.commandFailed("SQLite recovery quiescence found an active writer")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA journal_mode=DELETE;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw StewardError.commandFailed("SQLite recovery journal-mode change failed")
        }
        let stepResult = sqlite3_step(statement)
        let journalMode = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        let cacheResult = sqlite3_db_cacheflush(database)
        sqlite3_finalize(statement)
        guard stepResult == SQLITE_ROW,
              journalMode?.caseInsensitiveCompare("delete") == .orderedSame,
              cacheResult == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery database remained busy")
        }
        guard sqlite3_close_v2(database) == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery database could not close")
        }
        closeRequired = false
    }

    /// Creates a consistent, read-only SQLite backup for update recovery.
    /// The destination must not exist and is created in a private directory.
    @discardableResult
    public static func createVerifiedBackup(from sourceURL: URL, to destinationURL: URL) throws -> Int32 {
        guard try pathEntryExists(destinationURL) == false else {
            throw StewardError.unsafePath("SQLite recovery destination already exists")
        }
        let physicalSourceURL = try physicalRegularFileURL(sourceURL)
        let physicalDestinationURL = try physicalPrivateDestinationURL(destinationURL)
        let connection = try SQLiteConnection(databaseURL: physicalSourceURL, mode: .reader)
        let schemaVersion = try connection.backup(to: physicalDestinationURL)
        try FileSystemSecurity.setPrivateFilePermissions(physicalDestinationURL)
        try validateClosedRecoverySidecars(for: physicalDestinationURL)
        guard try verifyRecoveryDatabase(at: physicalDestinationURL) == schemaVersion else {
            throw StewardError.commandFailed("SQLite recovery backup verification mismatch")
        }
        try validateClosedRecoverySidecars(for: physicalDestinationURL)
        return schemaVersion
    }

    private static func validateClosedRecoverySidecars(for databaseURL: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            guard try pathEntryExists(URL(fileURLWithPath: databaseURL.path + suffix)) == false else {
                throw StewardError.commandFailed("SQLite recovery backup retained sidecar \(suffix)")
            }
        }
    }

    private static func pathEntryExists(_ url: URL) throws -> Bool {
        try FileSystemSecurity.pathEntryExists(url)
    }

    fileprivate static func physicalRegularFileURL(_ url: URL) throws -> URL {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed("SQLite recovery source could not be opened safely")
        }
        defer { close(descriptor) }
        var sourceMetadata = stat()
        guard fstat(descriptor, &sourceMetadata) == 0,
              sourceMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              sourceMetadata.st_uid == geteuid(),
              sourceMetadata.st_mode & mode_t(0o022) == 0 else {
            throw StewardError.unsafePath("unsafe SQLite recovery source")
        }

#if os(macOS)
        var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = pathBytes.withUnsafeMutableBytes { bytes -> Int32 in
            guard let base = bytes.baseAddress else { return -1 }
            return fcntl(descriptor, F_GETPATH, base)
        }
        guard result == 0 else {
            throw StewardError.commandFailed("SQLite recovery source path could not be resolved")
        }
        let physicalURL = URL(fileURLWithPath: decodedPath(pathBytes))
#else
        let descriptorPath = "/proc/self/fd/\(descriptor)"
        var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = descriptorPath.withCString {
            readlink($0, &pathBytes, pathBytes.count - 1)
        }
        guard count > 0 else {
            throw StewardError.commandFailed("SQLite recovery source path could not be resolved")
        }
        pathBytes[Int(count)] = 0
        let physicalURL = URL(fileURLWithPath: decodedPath(pathBytes))
#endif
        let physicalMetadata = try FileSystemSecurity.freshPOSIXMetadata(of: physicalURL)
        guard physicalMetadata.kind == .regularFile,
              physicalMetadata.deviceID == UInt64(sourceMetadata.st_dev),
              physicalMetadata.inode == UInt64(sourceMetadata.st_ino) else {
            throw StewardError.unsafePath("SQLite recovery source identity changed")
        }
        return physicalURL
    }

    fileprivate static func physicalPrivateDestinationURL(_ url: URL) throws -> URL {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw StewardError.unsafePath("unsafe SQLite recovery destination name")
        }
        let parentURL = url.deletingLastPathComponent()
        let descriptor = parentURL.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw StewardError.commandFailed("SQLite recovery destination directory could not be opened")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o077) == 0 else {
            throw StewardError.unsafePath("unsafe SQLite recovery destination directory")
        }

#if os(macOS)
        var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = pathBytes.withUnsafeMutableBytes { bytes -> Int32 in
            guard let base = bytes.baseAddress else { return -1 }
            return fcntl(descriptor, F_GETPATH, base)
        }
        guard result == 0 else {
            throw StewardError.commandFailed("SQLite recovery destination path could not be resolved")
        }
        let physicalParent = URL(fileURLWithPath: decodedPath(pathBytes), isDirectory: true)
#else
        let descriptorPath = "/proc/self/fd/\(descriptor)"
        var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = descriptorPath.withCString {
            readlink($0, &pathBytes, pathBytes.count - 1)
        }
        guard count > 0 else {
            throw StewardError.commandFailed("SQLite recovery destination path could not be resolved")
        }
        pathBytes[Int(count)] = 0
        let physicalParent = URL(fileURLWithPath: decodedPath(pathBytes), isDirectory: true)
#endif
        return physicalParent.appendingPathComponent(name)
    }

    private static func decodedPath(_ pathBytes: [CChar]) -> String {
        String(
            decoding: pathBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

private final class SQLiteConnection {
    enum Mode {
        case writer
        case reader
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let databaseURL: URL
    private let mode: Mode
    private var database: OpaquePointer?

    init(databaseURL: URL, mode: Mode) throws {
        self.mode = mode

        let requestedURL = databaseURL.standardizedFileURL
        switch mode {
        case .writer:
            try FileSystemSecurity.ensurePrivateDirectory(requestedURL.deletingLastPathComponent())
            if try FileSystemSecurity.pathEntryExists(requestedURL) {
                self.databaseURL = try AgentActivityDatabase.physicalRegularFileURL(requestedURL)
            } else {
                self.databaseURL = try AgentActivityDatabase.physicalPrivateDestinationURL(requestedURL)
            }
        case .reader:
            self.databaseURL = try AgentActivityDatabase.physicalRegularFileURL(requestedURL)
        }
        for candidate in relatedDatabaseFiles {
            if try FileSystemSecurity.pathEntryExists(candidate) {
                let metadata = try FileSystemSecurity.freshPOSIXMetadata(of: candidate)
                guard metadata.kind == .regularFile,
                      metadata.size <= AgentActivityDatabase.maximumDatabaseBytes else {
                    throw StewardError.unsafePath("unsafe or oversized SQLite activity database file")
                }
            }
        }

        let flags: Int32
        switch mode {
        case .writer:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
        case .reader:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
        }
        let openResult = self.databaseURL.path.withCString { path in
            sqlite3_open_v2(path, &database, flags, nil)
        }
        guard openResult == SQLITE_OK, let database else {
            let message = self.database.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let database = self.database { sqlite3_close_v2(database) }
            self.database = nil
            throw StewardError.commandFailed("SQLite open failed: \(message)")
        }
        do {
            guard sqlite3_extended_result_codes(database, 1) == SQLITE_OK,
                  sqlite3_busy_timeout(database, 1_500) == SQLITE_OK else {
                throw sqliteError("SQLite connection setup failed")
            }

            switch mode {
            case .writer:
                try FileSystemSecurity.setPrivateFilePermissions(self.databaseURL)
                let journalMode = try scalarText("PRAGMA journal_mode=WAL;")
                guard journalMode.caseInsensitiveCompare("wal") == .orderedSame else {
                    throw StewardError.commandFailed("SQLite WAL mode was not enabled")
                }
                try execute("PRAGMA synchronous=NORMAL;")
                try execute("PRAGMA wal_autocheckpoint=128;")
            case .reader:
                guard sqlite3_db_readonly(database, "main") == 1 else {
                    throw StewardError.commandFailed("SQLite reader did not open read-only")
                }
                try validateSchemaVersion()
            }
            try execute("PRAGMA foreign_keys=ON;")
            try execute("PRAGMA trusted_schema=OFF;")
            try execute("PRAGMA temp_store=MEMORY;")
            try applyPrivatePermissions()
        } catch {
            sqlite3_close_v2(database)
            self.database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    private var relatedDatabaseFiles: [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }

    func migrate() throws {
        guard case .writer = mode else {
            throw StewardError.commandFailed("SQLite migration requires the agent writer")
        }
        let current = try scalarInt("PRAGMA user_version;")
        guard current <= AgentActivityDatabase.schemaVersion else {
            throw StewardError.commandFailed("SQLite activity schema is newer than this TidyDrop build")
        }
        guard current < AgentActivityDatabase.schemaVersion else { return }

        try execute("BEGIN IMMEDIATE;")
        do {
            if current == 0 {
                try execute("""
                CREATE TABLE agent_runs (
                    run_id TEXT PRIMARY KEY NOT NULL,
                    timestamp REAL NOT NULL,
                    outcome TEXT NOT NULL,
                    mode TEXT,
                    scanned INTEGER,
                    planned INTEGER,
                    moved INTEGER,
                    deferred INTEGER,
                    skipped INTEGER,
                    errors INTEGER,
                    detail TEXT,
                    source_directory TEXT
                );
                """)
                try execute("CREATE INDEX agent_runs_timestamp ON agent_runs(timestamp DESC, run_id DESC);")
                try execute("PRAGMA user_version=1;")
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func record(_ record: ScheduledRunRecord) throws {
        guard case .writer = mode else {
            throw StewardError.commandFailed("SQLite activity writes are agent-only")
        }
        let sql = """
        INSERT INTO agent_runs (
            run_id, timestamp, outcome, mode, scanned, planned, moved,
            deferred, skipped, errors, detail, source_directory
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(run_id) DO UPDATE SET
            timestamp=excluded.timestamp,
            outcome=excluded.outcome,
            mode=excluded.mode,
            scanned=excluded.scanned,
            planned=excluded.planned,
            moved=excluded.moved,
            deferred=excluded.deferred,
            skipped=excluded.skipped,
            errors=excluded.errors,
            detail=excluded.detail,
            source_directory=excluded.source_directory;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(record.runID, at: 1, to: statement)
        guard sqlite3_bind_double(statement, 2, record.timestamp.timeIntervalSince1970) == SQLITE_OK else {
            throw sqliteError("SQLite timestamp bind failed")
        }
        try bind(record.outcome.rawValue, at: 3, to: statement)
        try bind(record.mode, at: 4, to: statement)
        try bind(record.scanned, at: 5, to: statement)
        try bind(record.planned, at: 6, to: statement)
        try bind(record.moved, at: 7, to: statement)
        try bind(record.deferred, at: 8, to: statement)
        try bind(record.skipped, at: 9, to: statement)
        try bind(record.errors, at: 10, to: statement)
        try bind(record.detail, at: 11, to: statement)
        try bind(record.sourceDirectory, at: 12, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError("SQLite activity insert failed")
        }
    }

    func enforceRetention(maximumRows: Int) throws {
        guard case .writer = mode else { return }
        // APP_OWNED_SQLITE_RETENTION: only rows in the internal activity index.
        let statement = try prepare("""
        DELETE FROM agent_runs
        WHERE run_id NOT IN (
            SELECT run_id FROM agent_runs ORDER BY timestamp DESC, run_id DESC LIMIT ?
        );
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, sqlite3_int64(maximumRows)) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError("SQLite activity retention failed")
        }
    }

    func recentRuns(limit: Int) throws -> [StoredAgentRun] {
        try validateSchemaVersion()
        let statement = try prepare("""
        SELECT run_id, timestamp, outcome, mode, scanned, planned, moved,
               deferred, skipped, errors, detail, source_directory
        FROM agent_runs
        ORDER BY timestamp DESC, run_id DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, sqlite3_int64(limit)) == SQLITE_OK else {
            throw sqliteError("SQLite activity limit bind failed")
        }
        var rows: [StoredAgentRun] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw sqliteError("SQLite activity query failed") }
            guard let runID = text(statement, column: 0),
                  let outcomeValue = text(statement, column: 2),
                  let outcome = ScheduledRunOutcome(rawValue: outcomeValue) else {
                throw StewardError.commandFailed("SQLite activity row is invalid")
            }
            rows.append(StoredAgentRun(
                runID: runID,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                outcome: outcome,
                mode: text(statement, column: 3),
                scanned: integer(statement, column: 4),
                planned: integer(statement, column: 5),
                moved: integer(statement, column: 6),
                deferred: integer(statement, column: 7),
                skipped: integer(statement, column: 8),
                errors: integer(statement, column: 9),
                detail: text(statement, column: 10),
                sourceDirectory: text(statement, column: 11)
            ))
        }
    }

    func backup(to destinationURL: URL) throws -> Int32 {
        guard case .reader = mode, let sourceDatabase = database else {
            throw StewardError.commandFailed("SQLite backup requires a read-only source")
        }
        try validateSchemaVersion()

        var destinationDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
        let openResult = destinationURL.path.withCString { path in
            sqlite3_open_v2(path, &destinationDatabase, flags, nil)
        }
        guard openResult == SQLITE_OK, let destinationDatabase else {
            if let destinationDatabase { sqlite3_close_v2(destinationDatabase) }
            throw StewardError.commandFailed("SQLite recovery destination could not be opened")
        }
        var closeRequired = true
        defer {
            if closeRequired { sqlite3_close_v2(destinationDatabase) }
        }
        guard sqlite3_extended_result_codes(destinationDatabase, 1) == SQLITE_OK,
              sqlite3_busy_timeout(destinationDatabase, 1_500) == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery destination setup failed")
        }
        let lockingMode = try scalarText(
            "PRAGMA locking_mode=EXCLUSIVE;",
            database: destinationDatabase
        )
        guard lockingMode.caseInsensitiveCompare("exclusive") == .orderedSame else {
            throw StewardError.commandFailed("SQLite recovery backup locking mode is unsafe")
        }

        guard let backup = sqlite3_backup_init(
            destinationDatabase,
            "main",
            sourceDatabase,
            "main"
        ) else {
            throw StewardError.commandFailed("SQLite recovery backup could not start")
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery backup did not complete")
        }
        let journalMode = try scalarText(
            "PRAGMA journal_mode=DELETE;",
            database: destinationDatabase
        )
        guard journalMode.caseInsensitiveCompare("delete") == .orderedSame else {
            throw StewardError.commandFailed("SQLite recovery backup journal mode is unsafe")
        }
        guard sqlite3_db_cacheflush(destinationDatabase) == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery backup could not synchronize")
        }
        let integrity = try scalarText("PRAGMA integrity_check;", database: destinationDatabase)
        guard integrity == "ok" else {
            throw StewardError.commandFailed("SQLite recovery backup integrity check failed")
        }
        let schemaVersion = try scalarInt("PRAGMA user_version;", database: destinationDatabase)
        guard schemaVersion == AgentActivityDatabase.schemaVersion else {
            throw StewardError.commandFailed("SQLite recovery backup schema mismatch")
        }
        guard sqlite3_close_v2(destinationDatabase) == SQLITE_OK else {
            throw StewardError.commandFailed("SQLite recovery backup could not close")
        }
        closeRequired = false
        return schemaVersion
    }

    func verifyRecoveryDatabase() throws -> Int32 {
        guard case .reader = mode else {
            throw StewardError.commandFailed("SQLite recovery verification requires read-only mode")
        }
        try validateSchemaVersion()
        let integrity = try scalarText("PRAGMA integrity_check;")
        guard integrity == "ok" else {
            throw StewardError.commandFailed("SQLite recovery integrity check failed")
        }
        return try scalarInt("PRAGMA user_version;")
    }

    func checkpoint() throws {
        guard case .writer = mode, let database else { return }
        guard sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) == SQLITE_OK else {
            throw sqliteError("SQLite checkpoint failed")
        }
    }

    func applyPrivatePermissions() throws {
        guard case .writer = mode else { return }
        for candidate in relatedDatabaseFiles where try FileSystemSecurity.pathEntryExists(candidate) {
            try FileSystemSecurity.setPrivateFilePermissions(candidate)
        }
    }

    private func validateSchemaVersion() throws {
        let version = try scalarInt("PRAGMA user_version;")
        guard version == AgentActivityDatabase.schemaVersion else {
            throw StewardError.commandFailed("unsupported SQLite activity schema version")
        }
    }

    private func scalarInt(_ sql: String) throws -> Int32 {
        guard let database else { throw StewardError.commandFailed("SQLite connection is closed") }
        return try scalarInt(sql, database: database)
    }

    private func scalarText(_ sql: String) throws -> String {
        guard let database else { throw StewardError.commandFailed("SQLite connection is closed") }
        return try scalarText(sql, database: database)
    }

    private func scalarText(_ sql: String, database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StewardError.commandFailed("SQLite recovery statement could not be prepared")
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw StewardError.commandFailed(
                "SQLite recovery statement returned no value: \(String(cString: sqlite3_errmsg(database)))"
            )
        }
        return String(cString: value)
    }

    private func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StewardError.commandFailed("SQLite recovery statement could not be prepared")
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw StewardError.commandFailed(
                "SQLite recovery statement returned no value: \(String(cString: sqlite3_errmsg(database)))"
            )
        }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StewardError.commandFailed("SQLite connection is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw StewardError.commandFailed("SQLite statement failed: \(message)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw StewardError.commandFailed("SQLite connection is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError("SQLite prepare failed")
        }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        if let value {
            result = value.withCString {
                sqlite3_bind_text(statement, index, $0, -1, Self.transientDestructor)
            }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw sqliteError("SQLite text bind failed") }
    }

    private func bind(_ value: Int?, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.map {
            sqlite3_bind_int64(statement, index, sqlite3_int64($0))
        } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw sqliteError("SQLite integer bind failed") }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func integer(_ statement: OpaquePointer, column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(exactly: sqlite3_column_int64(statement, column))
    }

    private func sqliteError(_ context: String) -> StewardError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
        return StewardError.commandFailed("\(context): \(message)")
    }
}
