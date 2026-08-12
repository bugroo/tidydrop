import Foundation

public enum ConfigurationIO {
    private static let maximumConfigurationBytes: UInt64 = 4_194_304

    public static func defaultConfigPath(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("TidyDrop", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static func load(from url: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ResolvedConfiguration {
        guard try FileSystemSecurity.pathEntryExists(url) else {
            throw StewardError.configurationNotFound(url.path)
        }
        let data = try FileSystemSecurity.readRegularFile(
            url,
            maximumBytes: maximumConfigurationBytes
        )
        let decoder = JSONDecoder()
        let config: StewardConfig
        do {
            config = try decoder.decode(StewardConfig.self, from: data)
        } catch {
            throw StewardError.invalidConfiguration("JSON ilegible en \(url.path): \(error)")
        }
        return try resolve(config, homeDirectory: homeDirectory)
    }

    public static func save(_ config: StewardConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        guard UInt64(data.count) <= maximumConfigurationBytes else {
            throw StewardError.invalidConfiguration("la configuración supera 4 MiB")
        }
        try FileSystemSecurity.atomicWritePrivate(
            data,
            to: url,
            maximumBytes: maximumConfigurationBytes
        )
    }

    public static func resolve(
        _ config: StewardConfig,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ResolvedConfiguration {
        try validate(config)

        _ = try ActiveFolderManager.validate(
            path: config.paths.sourceDirectory,
            homeDirectory: homeDirectory,
            requireAvailable: false
        )
        let source = canonicalURL(expand(config.paths.sourceDirectory, homeDirectory: homeDirectory))
        let destination = canonicalURL(expand(config.paths.destinationRoot, homeDirectory: homeDirectory))
        let state = canonicalURL(expand(config.paths.stateDirectory, homeDirectory: homeDirectory))
        let logs = canonicalURL(expand(config.paths.logDirectory, homeDirectory: homeDirectory))

        guard source.path != "/" else {
            throw StewardError.unsafePath("source_directory no puede ser / ")
        }
        guard destination.path != "/" else {
            throw StewardError.unsafePath("destination_root no puede ser / ")
        }
        guard state.path != "/", logs.path != "/" else {
            throw StewardError.unsafePath("state_directory y log_directory no pueden ser / ")
        }

        guard isSameOrDescendant(destination, of: source) else {
            throw StewardError.unsafePath(
                "destination_root debe ser source_directory o estar dentro de él: \(destination.path)"
            )
        }
        if isSameOrDescendant(state, of: source) || isSameOrDescendant(logs, of: source) {
            throw StewardError.unsafePath(
                "state_directory y log_directory deben quedar fuera de source_directory"
            )
        }

        return ResolvedConfiguration(
            config: config,
            paths: ResolvedPaths(
                sourceDirectory: source,
                destinationRoot: destination,
                stateDirectory: state,
                logDirectory: logs
            )
        )
    }

    public static func validate(_ config: StewardConfig) throws {
        guard config.version == 1 else {
            throw StewardError.invalidConfiguration("version debe ser 1")
        }
        guard !config.paths.sourceDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StewardError.invalidConfiguration("source_directory está vacío")
        }
        guard !config.paths.destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StewardError.invalidConfiguration("destination_root está vacío")
        }
        let rawPaths = [
            config.paths.sourceDirectory,
            config.paths.destinationRoot,
            config.paths.stateDirectory,
            config.paths.logDirectory
        ]
        for path in rawPaths {
            guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else {
                throw StewardError.invalidConfiguration("las rutas deben ser absolutas o comenzar por ~/: \(path)")
            }
        }
        guard config.automation.intervalSeconds >= 15 else {
            throw StewardError.invalidConfiguration("interval_seconds debe ser >= 15")
        }
        guard config.stability.minimumAgeSeconds >= 0 else {
            throw StewardError.invalidConfiguration("minimum_age_seconds debe ser >= 0")
        }
        guard config.stability.minimumStableObservations >= 1 else {
            throw StewardError.invalidConfiguration("minimum_stable_observations debe ser >= 1")
        }
        guard (0...30_000).contains(config.stability.probeDelayMilliseconds) else {
            throw StewardError.invalidConfiguration("probe_delay_milliseconds debe estar entre 0 y 30000")
        }
        guard config.stability.stateRetentionSeconds >= 60 else {
            throw StewardError.invalidConfiguration("state_retention_seconds debe ser >= 60")
        }
        guard config.collision.strategy == "numbered_suffix" else {
            throw StewardError.invalidConfiguration("collision.strategy solo admite numbered_suffix")
        }
        guard (1...100_000).contains(config.collision.maxAttempts) else {
            throw StewardError.invalidConfiguration("collision.max_attempts debe estar entre 1 y 100000")
        }
        guard (65_536...104_857_600).contains(config.logging.maxFileBytes) else {
            throw StewardError.invalidConfiguration(
                "logging.max_file_bytes debe estar entre 65536 y 104857600"
            )
        }
        guard (1...10).contains(config.logging.rotatedFileCount) else {
            throw StewardError.invalidConfiguration(
                "logging.rotated_file_count debe estar entre 1 y 10"
            )
        }
        guard (10...10_000).contains(config.logging.transactionManifestLimit) else {
            throw StewardError.invalidConfiguration(
                "logging.transaction_manifest_limit debe estar entre 10 y 10000"
            )
        }
        guard config.safety.requireDestinationInsideSource else {
            throw StewardError.invalidConfiguration(
                "require_destination_inside_source debe permanecer en true por seguridad"
            )
        }
        guard (1...100_000).contains(config.safety.maxFilesPerRun) else {
            throw StewardError.invalidConfiguration("max_files_per_run debe estar entre 1 y 100000")
        }
        guard !config.classification.categories.isEmpty else {
            throw StewardError.invalidConfiguration("debe existir al menos una categoría")
        }
        guard config.classification.categories.count <= 128 else {
            throw StewardError.invalidConfiguration("no puede haber más de 128 categorías")
        }
        guard config.classification.fallbackCategory.count <= 120 else {
            throw StewardError.invalidConfiguration("fallback_category es demasiado largo")
        }

        var categoryNames = Set<String>()
        var extensionOwners: [String: String] = [:]
        var totalPatterns = 0
        for category in config.classification.categories {
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == category.name else {
                throw StewardError.invalidConfiguration(
                    "el nombre de categoría no puede comenzar ni terminar con espacios: \(category.name)"
                )
            }
            guard isSafeSinglePathComponent(name) else {
                throw StewardError.invalidConfiguration("nombre de categoría inseguro: \(category.name)")
            }
            let foldedName = normalized(name)
            guard categoryNames.insert(foldedName).inserted else {
                throw StewardError.invalidConfiguration("categoría duplicada: \(category.name)")
            }
            guard category.extensions.count <= 2_048,
                  category.mimeTypes.count <= 2_048,
                  category.mimePrefixes.count <= 2_048,
                  category.namePatterns.count <= 256 else {
                throw StewardError.invalidConfiguration(
                    "demasiadas reglas en la categoría \(category.name)"
                )
            }

            for ext in category.extensions {
                let normalizedExtension = normalizeExtension(ext)
                guard !normalizedExtension.isEmpty,
                      normalizedExtension.count <= 64,
                      !normalizedExtension.contains("/"),
                      !normalizedExtension.contains("\\") else {
                    throw StewardError.invalidConfiguration("extensión insegura en \(category.name): \(ext)")
                }
                if let owner = extensionOwners[normalizedExtension], owner != category.name {
                    throw StewardError.invalidConfiguration(
                        "la extensión .\(normalizedExtension) aparece en \(owner) y \(category.name)"
                    )
                }
                extensionOwners[normalizedExtension] = category.name
            }

            for mime in category.mimeTypes + category.mimePrefixes {
                guard !mime.isEmpty,
                      mime.count <= 256,
                      !mime.contains("\0"),
                      mime.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                    throw StewardError.invalidConfiguration(
                        "tipo MIME inseguro en \(category.name)"
                    )
                }
            }

            for pattern in category.namePatterns {
                guard pattern.count <= 1_024 else {
                    throw StewardError.invalidConfiguration(
                        "regex demasiado larga en \(category.name)"
                    )
                }
                totalPatterns += 1
                do {
                    _ = try NSRegularExpression(pattern: pattern)
                } catch {
                    throw StewardError.invalidConfiguration(
                        "regex inválida en \(category.name): \(pattern) — \(error)"
                    )
                }
            }
        }
        guard totalPatterns <= 1_024 else {
            throw StewardError.invalidConfiguration("demasiadas regex de clasificación")
        }

        guard categoryNames.contains(normalized(config.classification.fallbackCategory)) else {
            throw StewardError.invalidConfiguration(
                "fallback_category no coincide con ninguna categoría: \(config.classification.fallbackCategory)"
            )
        }

        guard config.exclusions.filenames.count <= 4_096,
              config.exclusions.extensions.count <= 4_096,
              config.exclusions.namePatterns.count <= 1_024 else {
            throw StewardError.invalidConfiguration("demasiadas reglas de exclusión")
        }
        for value in config.exclusions.filenames {
            guard value.count <= 255, !value.contains("\0") else {
                throw StewardError.invalidConfiguration("nombre de exclusión inseguro")
            }
        }
        for value in config.exclusions.extensions {
            let normalizedExtension = normalizeExtension(value)
            guard !normalizedExtension.isEmpty,
                  normalizedExtension.count <= 64,
                  !normalizedExtension.contains("/"),
                  !normalizedExtension.contains("\\") else {
                throw StewardError.invalidConfiguration("extensión de exclusión insegura: \(value)")
            }
        }
        for pattern in config.exclusions.namePatterns {
            guard pattern.count <= 1_024 else {
                throw StewardError.invalidConfiguration("regex de exclusión demasiado larga")
            }
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw StewardError.invalidConfiguration("regex de exclusión inválida: \(pattern) — \(error)")
            }
        }
    }

    public static func expand(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    public static func normalizeExtension(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        return normalized(result)
    }

    public static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = canonicalURL(child).pathComponents
        let parentComponents = canonicalURL(parent).pathComponents
        guard childComponents.count >= parentComponents.count else { return false }
        return Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }

    public static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSafeSinglePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 120,
              value != ".",
              value != "..",
              !value.hasPrefix("."),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return true
    }
}

public enum DefaultConfiguration {
    public static func make() -> StewardConfig {
        StewardConfig(
            version: 1,
            paths: PathsConfig(
                sourceDirectory: "~/Downloads",
                destinationRoot: "~/Downloads",
                stateDirectory: "~/Library/Application Support/TidyDrop/state",
                logDirectory: "~/Library/Logs/TidyDrop"
            ),
            automation: AutomationConfig(
                applyEnabled: false,
                intervalSeconds: 300
            ),
            stability: StabilityConfig(
                minimumAgeSeconds: 45,
                minimumStableObservations: 2,
                probeDelayMilliseconds: 750,
                stateRetentionSeconds: 86_400
            ),
            classification: ClassificationConfig(
                useMIMEFallback: true,
                fallbackCategory: "Otros",
                categories: [
                    CategoryRule(
                        name: "Documentos",
                        extensions: [
                            "pdf", "doc", "docx", "odt", "rtf", "txt", "md", "markdown",
                            "pages", "xls", "xlsx", "ods", "numbers", "ppt", "pptx", "odp",
                            "key", "epub", "mobi", "azw", "azw3"
                        ],
                        mimeTypes: [
                            "application/pdf", "application/rtf", "text/rtf", "text/plain",
                            "application/vnd.oasis.opendocument.text",
                            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                            "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                        ],
                        namePatterns: [
                            "(?i)^(readme|license|licence|changelog|changes)(\\..*)?$"
                        ]
                    ),
                    CategoryRule(
                        name: "Imágenes",
                        extensions: [
                            "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff",
                            "bmp", "svg", "ico", "avif", "dng", "cr2", "cr3", "nef", "arw", "orf"
                        ],
                        mimePrefixes: ["image/"]
                    ),
                    CategoryRule(
                        name: "Vídeos",
                        extensions: [
                            "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpg", "mpeg", "mts",
                            "m2ts", "3gp", "ogv"
                        ],
                        mimePrefixes: ["video/"]
                    ),
                    CategoryRule(
                        name: "Audio",
                        extensions: [
                            "mp3", "m4a", "wav", "flac", "aac", "ogg", "oga", "opus", "aif",
                            "aiff", "wma", "alac"
                        ],
                        mimePrefixes: ["audio/"]
                    ),
                    CategoryRule(
                        name: "Archivos comprimidos",
                        extensions: [
                            "zip", "7z", "rar", "tar", "tar.gz", "tgz", "tar.bz2", "tbz2",
                            "tar.xz", "txz", "gz", "bz2", "xz", "zst", "cab"
                        ],
                        mimeTypes: [
                            "application/zip", "application/x-7z-compressed", "application/vnd.rar",
                            "application/x-rar-compressed", "application/x-tar", "application/gzip",
                            "application/x-bzip2", "application/x-xz", "application/zstd"
                        ]
                    ),
                    CategoryRule(
                        name: "Instaladores",
                        extensions: [
                            "dmg", "pkg", "mpkg", "exe", "msi", "deb", "rpm", "apk", "xip"
                        ],
                        mimeTypes: [
                            "application/x-apple-diskimage", "application/vnd.apple.installer+xml",
                            "application/x-msdownload", "application/vnd.microsoft.portable-executable",
                            "application/vnd.android.package-archive"
                        ]
                    ),
                    CategoryRule(
                        name: "Código",
                        extensions: [
                            "swift", "py", "pyw", "js", "mjs", "cjs", "ts", "tsx", "jsx", "html",
                            "htm", "css", "scss", "sass", "less", "sh", "zsh", "bash", "fish", "c",
                            "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh", "rs", "go", "java",
                            "kt", "kts", "rb", "php", "pl", "lua", "r", "sql", "vue", "svelte"
                        ],
                        mimeTypes: [
                            "text/x-python", "text/x-shellscript", "text/x-c", "text/x-c++",
                            "application/javascript", "text/javascript", "text/html", "text/css"
                        ],
                        namePatterns: [
                            "(?i)^(dockerfile|containerfile|makefile|justfile|rakefile|gemfile|podfile)$"
                        ]
                    ),
                    CategoryRule(
                        name: "ISOs",
                        extensions: ["iso", "img", "vhd", "vhdx", "qcow", "qcow2"],
                        mimeTypes: ["application/x-iso9660-image", "application/x-raw-disk-image"]
                    ),
                    CategoryRule(
                        name: "Datos",
                        extensions: [
                            "csv", "tsv", "json", "jsonl", "ndjson", "xml", "yaml", "yml", "toml",
                            "plist", "sqlite", "sqlite3", "db", "parquet", "avro", "orc", "feather"
                        ],
                        mimeTypes: [
                            "text/csv", "text/tab-separated-values", "application/json", "application/x-ndjson",
                            "application/xml", "text/xml", "application/x-yaml", "application/toml",
                            "application/x-sqlite3"
                        ]
                    ),
                    CategoryRule(
                        name: "Torrents",
                        extensions: ["torrent"],
                        mimeTypes: ["application/x-bittorrent"]
                    ),
                    CategoryRule(name: "Otros")
                ]
            ),
            exclusions: ExclusionConfig(
                ignoreHidden: true,
                ignoreSymlinks: true,
                filenames: [
                    ".DS_Store", ".localized", "Icon\r"
                ],
                extensions: [
                    "crdownload", "download", "part", "partial", "tmp", "temp", "opdownload",
                    "filepart", "aria2", "icloud"
                ],
                namePatterns: [
                    "(?i)^~\\$.*",
                    "(?i)^\\.com\\.google\\.Chrome\\..*",
                    "(?i).*\\.(crdownload|download|part|partial|tmp|temp|opdownload|filepart|aria2|icloud)$"
                ]
            ),
            collision: CollisionConfig(
                strategy: "numbered_suffix",
                maxAttempts: 10_000
            ),
            safety: SafetyConfig(
                requireDestinationInsideSource: true,
                maxFilesPerRun: 5_000
            ),
            logging: LoggingConfig(
                logSkippedFiles: false,
                maxFileBytes: 5_242_880,
                rotatedFileCount: 3,
                suppressScheduledNoopAudit: true,
                transactionManifestLimit: 100
            )
        )
    }
}
