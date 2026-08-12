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
                observations: previous.observations + 1,
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
        try JSONFile.save(database, to: url)
        isDirty = false
    }
}
