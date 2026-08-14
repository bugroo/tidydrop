import Foundation
import SQLite3

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
        self.databaseURL = databaseURL.standardizedFileURL
        self.mode = mode

        switch mode {
        case .writer:
            try FileSystemSecurity.ensurePrivateDirectory(databaseURL.deletingLastPathComponent())
        case .reader:
            break
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
        let openResult = databaseURL.path.withCString { path in
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
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError("SQLite scalar query failed")
        }
        return sqlite3_column_int(statement, 0)
    }

    private func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw sqliteError("SQLite text scalar query failed")
        }
        return String(cString: value)
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
