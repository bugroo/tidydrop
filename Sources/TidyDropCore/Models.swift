import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public enum StewardError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case configurationNotFound(String)
    case lockBusy(String)
    case sourceUnavailable(String)
    case noUndoableTransaction
    case unsafePath(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "Configuración no válida: \(message)"
        case .configurationNotFound(let path):
            return "No se encontró la configuración: \(path)"
        case .lockBusy(let path):
            return "Ya hay una ejecución activa (lock: \(path))"
        case .sourceUnavailable(let path):
            return "source_unavailable: \(path)"
        case .noUndoableTransaction:
            return "No existe ninguna ejecución con movimientos pendientes de deshacer"
        case .unsafePath(let message):
            return "Ruta insegura: \(message)"
        case .commandFailed(let message):
            return message
        }
    }
}

public enum ExecutionMode: String, Codable, Sendable {
    case dryRun = "dry-run"
    case apply
}

public enum UndoMode: String, Codable, Sendable {
    case preview
    case apply
}

public struct PathsConfig: Codable, Equatable, Sendable {
    public var sourceDirectory: String
    public var destinationRoot: String
    public var stateDirectory: String
    public var logDirectory: String

    enum CodingKeys: String, CodingKey {
        case sourceDirectory = "source_directory"
        case destinationRoot = "destination_root"
        case stateDirectory = "state_directory"
        case logDirectory = "log_directory"
    }

    public init(
        sourceDirectory: String,
        destinationRoot: String,
        stateDirectory: String,
        logDirectory: String
    ) {
        self.sourceDirectory = sourceDirectory
        self.destinationRoot = destinationRoot
        self.stateDirectory = stateDirectory
        self.logDirectory = logDirectory
    }
}

public struct AutomationConfig: Codable, Equatable, Sendable {
    public var applyEnabled: Bool
    public var intervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case applyEnabled = "apply_enabled"
        case intervalSeconds = "interval_seconds"
    }

    public init(applyEnabled: Bool, intervalSeconds: Int) {
        self.applyEnabled = applyEnabled
        self.intervalSeconds = intervalSeconds
    }
}

public struct StabilityConfig: Codable, Equatable, Sendable {
    public var minimumAgeSeconds: Double
    public var minimumStableObservations: Int
    public var probeDelayMilliseconds: Int
    public var stateRetentionSeconds: Double

    enum CodingKeys: String, CodingKey {
        case minimumAgeSeconds = "minimum_age_seconds"
        case minimumStableObservations = "minimum_stable_observations"
        case probeDelayMilliseconds = "probe_delay_milliseconds"
        case stateRetentionSeconds = "state_retention_seconds"
    }

    public init(
        minimumAgeSeconds: Double,
        minimumStableObservations: Int,
        probeDelayMilliseconds: Int,
        stateRetentionSeconds: Double
    ) {
        self.minimumAgeSeconds = minimumAgeSeconds
        self.minimumStableObservations = minimumStableObservations
        self.probeDelayMilliseconds = probeDelayMilliseconds
        self.stateRetentionSeconds = stateRetentionSeconds
    }
}

public struct CategoryRule: Codable, Equatable, Sendable {
    public var name: String
    public var extensions: [String]
    public var mimeTypes: [String]
    public var mimePrefixes: [String]
    public var namePatterns: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case extensions
        case mimeTypes = "mime_types"
        case mimePrefixes = "mime_prefixes"
        case namePatterns = "name_patterns"
    }

    public init(
        name: String,
        extensions: [String] = [],
        mimeTypes: [String] = [],
        mimePrefixes: [String] = [],
        namePatterns: [String] = []
    ) {
        self.name = name
        self.extensions = extensions
        self.mimeTypes = mimeTypes
        self.mimePrefixes = mimePrefixes
        self.namePatterns = namePatterns
    }
}

public struct ClassificationConfig: Codable, Equatable, Sendable {
    public var useMIMEFallback: Bool
    public var fallbackCategory: String
    public var categories: [CategoryRule]

    enum CodingKeys: String, CodingKey {
        case useMIMEFallback = "use_mime_fallback"
        case fallbackCategory = "fallback_category"
        case categories
    }

    public init(
        useMIMEFallback: Bool,
        fallbackCategory: String,
        categories: [CategoryRule]
    ) {
        self.useMIMEFallback = useMIMEFallback
        self.fallbackCategory = fallbackCategory
        self.categories = categories
    }
}

public struct ExclusionConfig: Codable, Equatable, Sendable {
    public var ignoreHidden: Bool
    public var ignoreSymlinks: Bool
    public var filenames: [String]
    public var extensions: [String]
    public var namePatterns: [String]

    enum CodingKeys: String, CodingKey {
        case ignoreHidden = "ignore_hidden"
        case ignoreSymlinks = "ignore_symlinks"
        case filenames
        case extensions
        case namePatterns = "name_patterns"
    }

    public init(
        ignoreHidden: Bool,
        ignoreSymlinks: Bool,
        filenames: [String],
        extensions: [String],
        namePatterns: [String]
    ) {
        self.ignoreHidden = ignoreHidden
        self.ignoreSymlinks = ignoreSymlinks
        self.filenames = filenames
        self.extensions = extensions
        self.namePatterns = namePatterns
    }
}

public struct CollisionConfig: Codable, Equatable, Sendable {
    public var strategy: String
    public var maxAttempts: Int

    enum CodingKeys: String, CodingKey {
        case strategy
        case maxAttempts = "max_attempts"
    }

    public init(strategy: String, maxAttempts: Int) {
        self.strategy = strategy
        self.maxAttempts = maxAttempts
    }
}

public struct SafetyConfig: Codable, Equatable, Sendable {
    public var requireDestinationInsideSource: Bool
    public var maxFilesPerRun: Int

    enum CodingKeys: String, CodingKey {
        case requireDestinationInsideSource = "require_destination_inside_source"
        case maxFilesPerRun = "max_files_per_run"
    }

    public init(requireDestinationInsideSource: Bool, maxFilesPerRun: Int) {
        self.requireDestinationInsideSource = requireDestinationInsideSource
        self.maxFilesPerRun = maxFilesPerRun
    }
}

public struct LoggingConfig: Codable, Equatable, Sendable {
    public var logSkippedFiles: Bool
    public var maxFileBytes: UInt64
    public var rotatedFileCount: Int
    public var suppressScheduledNoopAudit: Bool
    public var transactionManifestLimit: Int

    enum CodingKeys: String, CodingKey {
        case logSkippedFiles = "log_skipped_files"
        case maxFileBytes = "max_file_bytes"
        case rotatedFileCount = "rotated_file_count"
        case suppressScheduledNoopAudit = "suppress_scheduled_noop_audit"
        case transactionManifestLimit = "transaction_manifest_limit"
    }

    public init(
        logSkippedFiles: Bool,
        maxFileBytes: UInt64 = 5_242_880,
        rotatedFileCount: Int = 3,
        suppressScheduledNoopAudit: Bool = true,
        transactionManifestLimit: Int = 100
    ) {
        self.logSkippedFiles = logSkippedFiles
        self.maxFileBytes = maxFileBytes
        self.rotatedFileCount = rotatedFileCount
        self.suppressScheduledNoopAudit = suppressScheduledNoopAudit
        self.transactionManifestLimit = transactionManifestLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.logSkippedFiles = try container.decodeIfPresent(Bool.self, forKey: .logSkippedFiles) ?? false
        self.maxFileBytes = try container.decodeIfPresent(UInt64.self, forKey: .maxFileBytes) ?? 5_242_880
        self.rotatedFileCount = try container.decodeIfPresent(Int.self, forKey: .rotatedFileCount) ?? 3
        self.suppressScheduledNoopAudit = try container.decodeIfPresent(
            Bool.self,
            forKey: .suppressScheduledNoopAudit
        ) ?? true
        self.transactionManifestLimit = try container.decodeIfPresent(
            Int.self,
            forKey: .transactionManifestLimit
        ) ?? 100
    }
}

public struct StewardConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var paths: PathsConfig
    public var automation: AutomationConfig
    public var stability: StabilityConfig
    public var classification: ClassificationConfig
    public var exclusions: ExclusionConfig
    public var collision: CollisionConfig
    public var safety: SafetyConfig
    public var logging: LoggingConfig

    public init(
        version: Int,
        paths: PathsConfig,
        automation: AutomationConfig,
        stability: StabilityConfig,
        classification: ClassificationConfig,
        exclusions: ExclusionConfig,
        collision: CollisionConfig,
        safety: SafetyConfig,
        logging: LoggingConfig
    ) {
        self.version = version
        self.paths = paths
        self.automation = automation
        self.stability = stability
        self.classification = classification
        self.exclusions = exclusions
        self.collision = collision
        self.safety = safety
        self.logging = logging
    }
}

public struct ResolvedPaths: Equatable, Sendable {
    public let sourceDirectory: URL
    public let destinationRoot: URL
    public let stateDirectory: URL
    public let logDirectory: URL
    public let transactionsDirectory: URL
    public let stabilityStateFile: URL
    public let lockFile: URL
    public let humanLogFile: URL
    public let auditLogFile: URL
    public let agentErrorLogFile: URL
    public let scheduledStatusFile: URL
    public let scheduledDryRunCacheFile: URL

    public init(
        sourceDirectory: URL,
        destinationRoot: URL,
        stateDirectory: URL,
        logDirectory: URL
    ) {
        self.sourceDirectory = sourceDirectory
        self.destinationRoot = destinationRoot
        self.stateDirectory = stateDirectory
        self.logDirectory = logDirectory
        self.transactionsDirectory = stateDirectory.appendingPathComponent("transactions", isDirectory: true)
        self.stabilityStateFile = stateDirectory.appendingPathComponent("stability.json")
        self.lockFile = stateDirectory.appendingPathComponent("run.lock")
        self.humanLogFile = logDirectory.appendingPathComponent("steward.log")
        self.auditLogFile = logDirectory.appendingPathComponent("audit.jsonl")
        self.agentErrorLogFile = logDirectory.appendingPathComponent("agent-errors.log")
        self.scheduledStatusFile = stateDirectory.appendingPathComponent("last-scheduled-run.json")
        self.scheduledDryRunCacheFile = stateDirectory.appendingPathComponent("scheduled-dry-run-cache.json")
    }
}

public struct ResolvedConfiguration: Sendable {
    public let config: StewardConfig
    public let paths: ResolvedPaths

    public init(config: StewardConfig, paths: ResolvedPaths) {
        self.config = config
        self.paths = paths
    }
}

public struct FileSnapshot: Codable, Equatable, Sendable {
    public let size: UInt64
    public let modificationTime: TimeInterval
    public let modificationSeconds: Int64?
    public let modificationNanoseconds: Int64?
    public let creationTime: TimeInterval?
    public let creationSeconds: Int64?
    public let creationNanoseconds: Int64?
    public let documentIdentifier: Int64?
    public let fileIdentifier: String?
    public let deviceID: UInt64?
    public let inode: UInt64?

    public init(
        size: UInt64,
        modificationTime: TimeInterval,
        modificationSeconds: Int64? = nil,
        modificationNanoseconds: Int64? = nil,
        creationTime: TimeInterval? = nil,
        creationSeconds: Int64? = nil,
        creationNanoseconds: Int64? = nil,
        documentIdentifier: Int64? = nil,
        fileIdentifier: String?,
        deviceID: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.size = size
        self.modificationTime = modificationTime
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.creationTime = creationTime
        self.creationSeconds = creationSeconds
        self.creationNanoseconds = creationNanoseconds
        self.documentIdentifier = documentIdentifier
        self.fileIdentifier = fileIdentifier
        self.deviceID = deviceID
        self.inode = inode
    }

    /// Conservative match for journal recovery and undo.
    ///
    /// A rename on the same volume preserves these values. Replacing or editing
    /// the organized file causes the match to fail instead of moving an object
    /// that may no longer be the one recorded in the transaction journal.
    public func matchesJournaledSnapshot(_ other: FileSnapshot) -> Bool {
        guard size == other.size,
              modificationMatches(other) else {
            return false
        }

        var comparedStableIdentity = false

        if let documentIdentifier, let otherDocumentIdentifier = other.documentIdentifier {
            comparedStableIdentity = true
            guard documentIdentifier == otherDocumentIdentifier else { return false }
        }

        if let creationSeconds, let creationNanoseconds,
           let otherCreationSeconds = other.creationSeconds,
           let otherCreationNanoseconds = other.creationNanoseconds {
            comparedStableIdentity = true
            guard creationSeconds == otherCreationSeconds,
                  creationNanoseconds == otherCreationNanoseconds else { return false }
        } else if let creationTime, let otherCreationTime = other.creationTime {
            comparedStableIdentity = true
            guard creationTime == otherCreationTime else { return false }
        }

        if let deviceID, let inode,
           let otherDeviceID = other.deviceID, let otherInode = other.inode {
            comparedStableIdentity = true
            guard deviceID == otherDeviceID, inode == otherInode else { return false }
        }

        if !comparedStableIdentity,
           let fileIdentifier, let otherIdentifier = other.fileIdentifier {
            return fileIdentifier == otherIdentifier
        }

        // Metadata-only fallback exists for filesystems that expose none of the
        // identity keys. It remains deliberately conservative because size and
        // modification time must still be unchanged.
        return true
    }

    public func matchesFreshPOSIXStat(_ information: stat) -> Bool {
#if os(macOS)
        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanoseconds = Int64(information.st_mtimespec.tv_nsec)
#else
        let seconds = Int64(information.st_mtim.tv_sec)
        let nanoseconds = Int64(information.st_mtim.tv_nsec)
#endif
        guard information.st_size >= 0,
              size == UInt64(information.st_size),
              deviceID == UInt64(information.st_dev),
              inode == UInt64(information.st_ino) else {
            return false
        }
        if let modificationSeconds, let modificationNanoseconds {
            return modificationSeconds == seconds && modificationNanoseconds == nanoseconds
        }
        return modificationTime == TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000
    }

    private func modificationMatches(_ other: FileSnapshot) -> Bool {
        if let modificationSeconds, let modificationNanoseconds,
           let otherSeconds = other.modificationSeconds,
           let otherNanoseconds = other.modificationNanoseconds {
            return modificationSeconds == otherSeconds && modificationNanoseconds == otherNanoseconds
        }
        return modificationTime == other.modificationTime
    }
}

public struct ClassificationDecision: Equatable, Sendable {
    public let category: String
    public let reason: String
    public let matchedExtension: String?
    public let mimeType: String?

    public init(category: String, reason: String, matchedExtension: String?, mimeType: String?) {
        self.category = category
        self.reason = reason
        self.matchedExtension = matchedExtension
        self.mimeType = mimeType
    }
}

public struct RunSummary: Codable, Equatable, Sendable {
    public var runID: String
    public var mode: ExecutionMode
    public var scanned: Int
    public var planned: Int
    public var moved: Int
    public var deferred: Int
    public var skipped: Int
    public var errors: Int

    public init(
        runID: String,
        mode: ExecutionMode,
        scanned: Int = 0,
        planned: Int = 0,
        moved: Int = 0,
        deferred: Int = 0,
        skipped: Int = 0,
        errors: Int = 0
    ) {
        self.runID = runID
        self.mode = mode
        self.scanned = scanned
        self.planned = planned
        self.moved = moved
        self.deferred = deferred
        self.skipped = skipped
        self.errors = errors
    }
}


public enum ScheduledRunOutcome: String, Codable, Sendable {
    case success
    case lockBusy = "lock_busy"
    case sourceUnavailable = "source_unavailable"
    case error
}

public struct ScheduledRunRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let timestamp: Date
    public let outcome: ScheduledRunOutcome
    public let runID: String
    public let mode: String?
    public let scanned: Int?
    public let planned: Int?
    public let moved: Int?
    public let deferred: Int?
    public let skipped: Int?
    public let errors: Int?
    public let detail: String?
    public let sourceDirectory: String?

    enum CodingKeys: String, CodingKey {
        case version
        case timestamp
        case outcome
        case runID = "run_id"
        case mode
        case scanned
        case planned
        case moved
        case deferred
        case skipped
        case errors
        case detail
        case sourceDirectory = "source_directory"
    }

    public init(
        timestamp: Date = Date(),
        outcome: ScheduledRunOutcome,
        runID: String,
        mode: String? = nil,
        scanned: Int? = nil,
        planned: Int? = nil,
        moved: Int? = nil,
        deferred: Int? = nil,
        skipped: Int? = nil,
        errors: Int? = nil,
        detail: String? = nil,
        sourceDirectory: String? = nil
    ) {
        self.version = 1
        self.timestamp = timestamp
        self.outcome = outcome
        self.runID = runID
        self.mode = mode
        self.scanned = scanned
        self.planned = planned
        self.moved = moved
        self.deferred = deferred
        self.skipped = skipped
        self.errors = errors
        self.detail = detail
        self.sourceDirectory = sourceDirectory
    }

    public init(summary: RunSummary, timestamp: Date = Date()) {
        self.init(
            timestamp: timestamp,
            outcome: .success,
            runID: summary.runID,
            mode: summary.mode.rawValue,
            scanned: summary.scanned,
            planned: summary.planned,
            moved: summary.moved,
            deferred: summary.deferred,
            skipped: summary.skipped,
            errors: summary.errors
        )
    }
}

public struct UndoSummary: Codable, Equatable, Sendable {
    public var transactionID: String
    public var mode: UndoMode
    public var planned: Int
    public var restored: Int
    public var skipped: Int
    public var errors: Int

    public init(
        transactionID: String,
        mode: UndoMode,
        planned: Int = 0,
        restored: Int = 0,
        skipped: Int = 0,
        errors: Int = 0
    ) {
        self.transactionID = transactionID
        self.mode = mode
        self.planned = planned
        self.restored = restored
        self.skipped = skipped
        self.errors = errors
    }
}
