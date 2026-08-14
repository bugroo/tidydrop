import Foundation

public struct AgentRunRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let timestamp: Date
    public let sourceDirectory: String

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case timestamp
        case sourceDirectory = "source_directory"
    }

    public init(
        requestID: String = UUID().uuidString,
        timestamp: Date = Date(),
        sourceDirectory: String
    ) {
        self.version = 1
        self.requestID = requestID
        self.timestamp = timestamp
        self.sourceDirectory = sourceDirectory
    }
}

public enum AgentRunRequestValidation: String, Equatable, Sendable {
    case valid
    case missing
    case unreadable
    case unsupportedVersion = "unsupported_version"
    case invalidRequestID = "invalid_request_id"
    case sourceMismatch = "source_mismatch"
    case timestampOutOfRange = "timestamp_out_of_range"
}

public enum AgentRunRequestSignal {
    public static let maximumAge: TimeInterval = 120

    public static func request(
        at url: URL,
        sourceDirectory: URL,
        timestamp: Date = Date()
    ) throws {
        try JSONFile.save(
            AgentRunRequest(
                timestamp: timestamp,
                sourceDirectory: ConfigurationIO.canonicalURL(sourceDirectory).path
            ),
            to: url,
            maximumBytes: 4_096
        )
    }

    public static func isValid(
        at url: URL,
        sourceDirectory: URL,
        now: Date = Date()
    ) -> Bool {
        validation(at: url, sourceDirectory: sourceDirectory, now: now) == .valid
    }

    public static func validation(
        at url: URL,
        sourceDirectory: URL,
        now: Date = Date()
    ) -> AgentRunRequestValidation {
        do {
            guard try FileSystemSecurity.pathEntryExists(url) else { return .missing }
            let request = try JSONFile.load(
                AgentRunRequest.self,
                from: url,
                default: AgentRunRequest(
                    requestID: "invalid",
                    timestamp: .distantPast,
                    sourceDirectory: ""
                ),
                maximumBytes: 4_096
            )
            let age = now.timeIntervalSince(request.timestamp)
            guard request.version == 1 else { return .unsupportedVersion }
            guard UUID(uuidString: request.requestID) != nil else { return .invalidRequestID }
            guard request.sourceDirectory == ConfigurationIO.canonicalURL(sourceDirectory).path else {
                return .sourceMismatch
            }
            guard age >= -5, age <= maximumAge else { return .timestampOutOfRange }
            return .valid
        } catch {
            return .unreadable
        }
    }

    /// A request is a one-shot wake signal, not durable authority. Removing the
    /// private state file after validation prevents unrelated state events from
    /// replaying the same request.
    public static func consumeIfValid(
        at url: URL,
        sourceDirectory: URL,
        now: Date = Date()
    ) -> Bool {
        guard isValid(at: url, sourceDirectory: sourceDirectory, now: now) else {
            return false
        }
        do {
            try FileSystemSecurity.consumePrivateAgentRunRequest(url)
            return true
        } catch {
            return false
        }
    }
}
