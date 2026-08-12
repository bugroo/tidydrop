import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public protocol MIMETypeDetecting {
    func mimeType(for url: URL) -> String?
}

public struct SystemMIMETypeDetector: MIMETypeDetecting {
    private let executableURL: URL
    private let timeoutSeconds: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/file"),
        timeoutSeconds: TimeInterval = 2
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = max(0.05, min(timeoutSeconds, 10))
    }

    public func mimeType(for url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--brief", "--mime-type", "--no-dereference", "--", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.2)
                while process.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            return ConfigurationIO.normalized(value)
        } catch {
            return nil
        }
    }
}

public struct NullMIMETypeDetector: MIMETypeDetecting {
    public init() {}
    public func mimeType(for url: URL) -> String? { nil }
}

public final class FileClassifier {
    private struct CompiledCategory {
        let rule: CategoryRule
        let normalizedName: String
        let extensions: [String]
        let mimeTypes: Set<String>
        let mimePrefixes: [String]
        let namePatterns: [NSRegularExpression]
    }

    private let config: ClassificationConfig
    private let fallbackCategoryName: String
    private let categories: [CompiledCategory]
    private let extensionOwners: [(extensionValue: String, category: String)]
    private let detector: MIMETypeDetecting

    public init(config: ClassificationConfig, detector: MIMETypeDetecting = SystemMIMETypeDetector()) throws {
        self.config = config
        self.detector = detector
        let normalizedFallback = ConfigurationIO.normalized(config.fallbackCategory)
        guard let fallback = config.categories.first(where: {
            ConfigurationIO.normalized($0.name) == normalizedFallback
        }) else {
            throw StewardError.invalidConfiguration(
                "fallback_category no coincide con ninguna categoría: \(config.fallbackCategory)"
            )
        }
        self.fallbackCategoryName = fallback.name

        var compiled: [CompiledCategory] = []
        var extensions: [(String, String)] = []
        for rule in config.categories {
            let normalizedExtensions = rule.extensions
                .map(ConfigurationIO.normalizeExtension)
                .filter { !$0.isEmpty }
            let patterns = try rule.namePatterns.map { try NSRegularExpression(pattern: $0) }
            compiled.append(
                CompiledCategory(
                    rule: rule,
                    normalizedName: ConfigurationIO.normalized(rule.name),
                    extensions: normalizedExtensions,
                    mimeTypes: Set(rule.mimeTypes.map(ConfigurationIO.normalized)),
                    mimePrefixes: rule.mimePrefixes.map(ConfigurationIO.normalized),
                    namePatterns: patterns
                )
            )
            extensions.append(contentsOf: normalizedExtensions.map { ($0, rule.name) })
        }
        self.categories = compiled
        self.extensionOwners = extensions.sorted {
            if $0.0.count == $1.0.count { return $0.0 < $1.0 }
            return $0.0.count > $1.0.count
        }
    }

    public func classify(_ url: URL) -> ClassificationDecision {
        let originalName = url.lastPathComponent
        let normalizedName = ConfigurationIO.normalized(originalName)
        let fullRange = NSRange(originalName.startIndex..<originalName.endIndex, in: originalName)

        if let match = matchingExtensionOwner(in: normalizedName) {
            return ClassificationDecision(
                category: match.category,
                reason: "extension:.\(match.extensionValue)",
                matchedExtension: match.extensionValue,
                mimeType: nil
            )
        }

        for category in categories {
            for regex in category.namePatterns where regex.firstMatch(in: originalName, range: fullRange) != nil {
                return ClassificationDecision(
                    category: category.rule.name,
                    reason: "name_pattern:\(regex.pattern)",
                    matchedExtension: nil,
                    mimeType: nil
                )
            }
        }

        if config.useMIMEFallback, let mime = detector.mimeType(for: url) {
            for category in categories {
                if category.mimeTypes.contains(mime) {
                    return ClassificationDecision(
                        category: category.rule.name,
                        reason: "mime:\(mime)",
                        matchedExtension: nil,
                        mimeType: mime
                    )
                }
            }
            for category in categories {
                if category.mimePrefixes.contains(where: { mime.hasPrefix($0) }) {
                    return ClassificationDecision(
                        category: category.rule.name,
                        reason: "mime_prefix:\(mime)",
                        matchedExtension: nil,
                        mimeType: mime
                    )
                }
            }
        }

        return ClassificationDecision(
            category: fallbackCategoryName,
            reason: "fallback",
            matchedExtension: matchingExtension(in: normalizedName),
            mimeType: nil
        )
    }

    public func matchingExtension(in normalizedFilename: String) -> String? {
        matchingExtensionOwner(in: normalizedFilename)?.extensionValue
    }

    private func matchingExtensionOwner(in normalizedFilename: String) -> (extensionValue: String, category: String)? {
        extensionOwners.first { item in
            normalizedFilename.hasSuffix("." + item.extensionValue)
        }
    }
}

public final class ExclusionEvaluator {
    private let config: ExclusionConfig
    private let filenames: Set<String>
    private let extensions: [String]
    private let patterns: [NSRegularExpression]

    public init(config: ExclusionConfig) throws {
        self.config = config
        self.filenames = Set(config.filenames.map(ConfigurationIO.normalized))
        self.extensions = config.extensions
            .map(ConfigurationIO.normalizeExtension)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        self.patterns = try config.namePatterns.map { try NSRegularExpression(pattern: $0) }
    }

    public func exclusionReason(url: URL, facts: ItemFacts) -> String? {
        let name = url.lastPathComponent
        let normalizedName = ConfigurationIO.normalized(name)

        if facts.isDirectory {
            return "directory"
        }
        if facts.isSymbolicLink && config.ignoreSymlinks {
            return "symlink"
        }
        if !facts.isRegularFile {
            return "not_regular_file"
        }
        if facts.isHidden && config.ignoreHidden {
            return "hidden"
        }
        if filenames.contains(normalizedName) {
            return "excluded_filename"
        }
        if extensions.contains(where: { normalizedName.hasSuffix("." + $0) }) {
            return "temporary_or_incomplete_extension"
        }

        let fullRange = NSRange(name.startIndex..<name.endIndex, in: name)
        if let pattern = patterns.first(where: { $0.firstMatch(in: name, range: fullRange) != nil }) {
            return "excluded_pattern:\(pattern.pattern)"
        }
        return nil
    }
}
