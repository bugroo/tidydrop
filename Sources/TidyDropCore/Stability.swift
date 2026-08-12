import Foundation

public struct StabilityRecord: Codable, Equatable, Sendable {
    public var snapshot: FileSnapshot
    public var observations: Int
    public var firstSeen: Date
    public var lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case snapshot
        case observations
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }

    public init(snapshot: FileSnapshot, observations: Int, firstSeen: Date, lastSeen: Date) {
        self.snapshot = snapshot
        self.observations = observations
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct StabilityDatabase: Codable, Equatable, Sendable {
    public var version: Int
    public var records: [String: StabilityRecord]

    public init(version: Int = 1, records: [String: StabilityRecord] = [:]) {
        self.version = version
        self.records = records
    }
}

public struct StabilityEvaluation: Equatable, Sendable {
    public let isStable: Bool
    public let observations: Int
    public let ageSeconds: Double
    public let reason: String

    public init(isStable: Bool, observations: Int, ageSeconds: Double, reason: String) {
        self.isStable = isStable
        self.observations = observations
        self.ageSeconds = ageSeconds
        self.reason = reason
    }
}

public final class StabilityStore {
    private let url: URL
    private var database: StabilityDatabase
    private var isDirty = false

    public init(url: URL) throws {
        self.url = url
        self.database = try JSONFile.load(StabilityDatabase.self, from: url, default: StabilityDatabase())
        if database.version != 1 {
            throw StewardError.invalidConfiguration("versión de stability.json no soportada: \(database.version)")
        }
    }

    public func observe(
        path: String,
        snapshot: FileSnapshot,
        now: Date,
        minimumObservations: Int,
        minimumAgeSeconds: Double
    ) -> StabilityEvaluation {
        let previous = database.records[path]
        let record: StabilityRecord
        if let previous, previous.snapshot == snapshot {
            record = StabilityRecord(
                snapshot: snapshot,
                observations: min(previous.observations + 1, minimumObservations),
                firstSeen: previous.firstSeen,
                lastSeen: now
            )
        } else {
            record = StabilityRecord(
                snapshot: snapshot,
                observations: 1,
                firstSeen: now,
                lastSeen: now
            )
        }
        if database.records[path] != record {
            database.records[path] = record
            isDirty = true
        }

        let age = now.timeIntervalSince1970 - snapshot.modificationTime
        if age < 0 {
            return StabilityEvaluation(
                isStable: false,
                observations: record.observations,
                ageSeconds: age,
                reason: "mtime_in_future"
            )
        }
        if age < minimumAgeSeconds {
            return StabilityEvaluation(
                isStable: false,
                observations: record.observations,
                ageSeconds: age,
                reason: "minimum_age_not_reached"
            )
        }
        if record.observations < minimumObservations {
            return StabilityEvaluation(
                isStable: false,
                observations: record.observations,
                ageSeconds: age,
                reason: "stable_observations_not_reached"
            )
        }
        return StabilityEvaluation(
            isStable: true,
            observations: record.observations,
            ageSeconds: age,
            reason: "stable"
        )
    }

    public func remove(path: String) {
        if database.records.removeValue(forKey: path) != nil {
            isDirty = true
        }
    }

    public func prune(now: Date, retentionSeconds: Double) {
        let retained = database.records.filter { _, record in
            now.timeIntervalSince(record.lastSeen) <= retentionSeconds
        }
        if retained != database.records {
            database.records = retained
            isDirty = true
        }
    }

    public func save() throws {
        guard isDirty else { return }
        try JSONFile.save(database, to: url, maximumBytes: 33_554_432)
        isDirty = false
    }
}

public struct ScheduledDryRunCacheRecord: Codable, Equatable, Sendable {
    public let snapshot: FileSnapshot

    public init(snapshot: FileSnapshot) {
        self.snapshot = snapshot
    }
}

public struct ScheduledDryRunCacheDatabase: Codable, Equatable, Sendable {
    public var version: Int
    public var planSignature: String
    public var records: [String: ScheduledDryRunCacheRecord]

    enum CodingKeys: String, CodingKey {
        case version
        case planSignature = "plan_signature"
        case records
    }

    public init(
        version: Int = 1,
        planSignature: String,
        records: [String: ScheduledDryRunCacheRecord] = [:]
    ) {
        self.version = version
        self.planSignature = planSignature
        self.records = records
    }
}

/// Avoids re-probing and re-auditing an unchanged dry-run plan. This cache is
/// never consulted in apply mode and therefore cannot authorize a move.
public final class ScheduledDryRunCache {
    private let url: URL
    private var database: ScheduledDryRunCacheDatabase
    private var isDirty = false

    public init(url: URL, planSignature: String) throws {
        self.url = url
        let empty = ScheduledDryRunCacheDatabase(planSignature: planSignature)
        let loaded = try JSONFile.load(
            ScheduledDryRunCacheDatabase.self,
            from: url,
            default: empty,
            maximumBytes: 33_554_432
        )
        guard loaded.version == 1 else {
            throw StewardError.commandFailed(
                "versión de scheduled-dry-run-cache.json no soportada: \(loaded.version)"
            )
        }
        if loaded.planSignature == planSignature {
            self.database = loaded
        } else {
            self.database = empty
            self.isDirty = true
        }
    }

    public func contains(path: String, snapshot: FileSnapshot) -> Bool {
        database.records[path]?.snapshot == snapshot
    }

    public func remember(path: String, snapshot: FileSnapshot) {
        let record = ScheduledDryRunCacheRecord(snapshot: snapshot)
        if database.records[path] != record {
            database.records[path] = record
            isDirty = true
        }
    }

    public func retain(paths: Set<String>) {
        let retained = database.records.filter { paths.contains($0.key) }
        if retained != database.records {
            database.records = retained
            isDirty = true
        }
    }

    public func save() throws {
        guard isDirty else { return }
        try JSONFile.save(database, to: url, maximumBytes: 33_554_432)
        isDirty = false
    }
}
