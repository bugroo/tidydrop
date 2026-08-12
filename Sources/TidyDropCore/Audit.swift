import Foundation

public struct AuditEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let runID: String
    public let level: String
    public let mode: String
    public let action: String
    public let source: String?
    public let destination: String?
    public let category: String?
    public let reason: String?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case runID = "run_id"
        case level
        case mode
        case action
        case source
        case destination
        case category
        case reason
        case detail
    }

    public init(
        timestamp: Date = Date(),
        runID: String,
        level: String,
        mode: String,
        action: String,
        source: String? = nil,
        destination: String? = nil,
        category: String? = nil,
        reason: String? = nil,
        detail: String? = nil
    ) {
        self.timestamp = timestamp
        self.runID = runID
        self.level = level
        self.mode = mode
        self.action = action
        self.source = source
        self.destination = destination
        self.category = category
        self.reason = reason
        self.detail = detail
    }
}

public final class AuditLogger {
    public let humanLogURL: URL
    public let auditLogURL: URL
    private let encoder: JSONEncoder
    private let dateFormatter: ISO8601DateFormatter
    private let maxFileBytes: UInt64
    private let rotatedFileCount: Int
    public private(set) var recordCount: Int = 0

    public init(
        humanLogURL: URL,
        auditLogURL: URL,
        maxFileBytes: UInt64 = 5_242_880,
        rotatedFileCount: Int = 3
    ) throws {
        self.humanLogURL = humanLogURL
        self.auditLogURL = auditLogURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.dateFormatter = ISO8601DateFormatter()
        self.maxFileBytes = maxFileBytes
        self.rotatedFileCount = rotatedFileCount

        try FileSystemSecurity.ensureRegularFileExists(humanLogURL)
        try FileSystemSecurity.ensureRegularFileExists(auditLogURL)
    }

    public func record(_ event: AuditEvent) throws {
        var json = try encoder.encode(event)
        json.append(0x0A)
        try FileSystemSecurity.appendBounded(
            json,
            to: auditLogURL,
            maxBytes: maxFileBytes,
            retainedFiles: rotatedFileCount
        )

        let humanLine = [
            dateFormatter.string(from: event.timestamp),
            event.level.uppercased(),
            "run=\(sanitize(event.runID))",
            "mode=\(sanitize(event.mode))",
            "action=\(sanitize(event.action))",
            event.source.map { "source=\(quote($0))" },
            event.destination.map { "destination=\(quote($0))" },
            event.category.map { "category=\(quote($0))" },
            event.reason.map { "reason=\(quote($0))" },
            event.detail.map { "detail=\(quote($0))" }
        ]
        .compactMap { $0 }
        .joined(separator: " ") + "\n"

        try FileSystemSecurity.appendBounded(
            Data(humanLine.utf8),
            to: humanLogURL,
            maxBytes: maxFileBytes,
            retainedFiles: rotatedFileCount
        )
        recordCount += 1
    }

    private func quote(_ value: String) -> String {
        "\"\(sanitize(value).replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
