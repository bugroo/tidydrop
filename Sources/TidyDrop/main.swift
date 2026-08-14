import Foundation
import TidyDropCore
#if os(macOS)
import AppKit
#endif
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private let programVersion = "1.2.0"

private struct Arguments {
    let command: String
    let values: [String]

    init(_ raw: [String]) {
        self.command = raw.first ?? "help"
        self.values = Array(raw.dropFirst())
    }

    func contains(_ flag: String) -> Bool {
        values.contains(flag)
    }

    func value(after option: String) -> String? {
        guard let index = values.firstIndex(of: option), values.indices.contains(index + 1) else {
            return nil
        }
        return values[index + 1]
    }

    func validate(allowedFlags: Set<String>, valueOptions: Set<String>) throws {
        var index = 0
        var seen = Set<String>()
        while index < values.count {
            let token = values[index]
            if valueOptions.contains(token) {
                guard seen.insert(token).inserted else {
                    throw StewardError.commandFailed("Opción repetida: \(token)")
                }
                guard values.indices.contains(index + 1), !values[index + 1].hasPrefix("--") else {
                    throw StewardError.commandFailed("Falta el valor de \(token)")
                }
                index += 2
                continue
            }
            if allowedFlags.contains(token) {
                guard seen.insert(token).inserted else {
                    throw StewardError.commandFailed("Opción repetida: \(token)")
                }
                index += 1
                continue
            }
            throw StewardError.commandFailed("Opción o argumento desconocido: \(token)")
        }
    }
}

private func printHelp() {
    print("""
    TidyDrop \(programVersion)

    Uso:
      tidydrop doctor [--config RUTA]
      tidydrop init-config [--config RUTA] [--force]
      tidydrop run [--dry-run | --apply | --scheduled] [--config RUTA] [--json]
      tidydrop undo [--apply] [--config RUTA] [--json]
      tidydrop activate [--config RUTA]
      tidydrop deactivate [--config RUTA]
      tidydrop status [--config RUTA] [--json]
      tidydrop folder show [--config RUTA]
      tidydrop folder set RUTA [--config RUTA_CONFIG]
      tidydrop folder choose [--config RUTA]
      tidydrop folder reset-downloads [--config RUTA]
      tidydrop folder validate [--config RUTA]
      tidydrop print-default-config
      tidydrop version

    Seguridad:
      • run usa dry-run por defecto.
      • --apply es obligatorio para mover archivos manualmente.
      • undo solo previsualiza; undo --apply restaura la última transacción.
      • activate únicamente cambia la configuración para futuras pasadas programadas.
    """)
}

private func validateArguments(_ arguments: Arguments) throws {
    let configOption: Set<String> = ["--config"]
    switch arguments.command {
    case "help", "--help", "-h", "version", "--version", "print-default-config":
        try arguments.validate(allowedFlags: [], valueOptions: [])
    case "doctor":
        try arguments.validate(allowedFlags: [], valueOptions: configOption)
    case "init-config":
        try arguments.validate(allowedFlags: ["--force"], valueOptions: configOption)
    case "run":
        try arguments.validate(
            allowedFlags: ["--dry-run", "--apply", "--scheduled", "--json"],
            valueOptions: configOption
        )
    case "undo":
        try arguments.validate(allowedFlags: ["--apply", "--json"], valueOptions: configOption)
    case "activate", "deactivate":
        try arguments.validate(allowedFlags: [], valueOptions: configOption)
    case "status":
        try arguments.validate(allowedFlags: ["--json"], valueOptions: configOption)
    case "folder":
        try validateFolderArguments(arguments)
    default:
        break
    }
}

private func validateFolderArguments(_ arguments: Arguments) throws {
    guard let subcommand = arguments.values.first else {
        throw StewardError.commandFailed("Falta el subcomando de folder")
    }
    var trailing = Array(arguments.values.dropFirst())
    switch subcommand {
    case "show", "choose", "reset-downloads", "validate":
        let nested = Arguments([subcommand] + trailing)
        try nested.validate(allowedFlags: [], valueOptions: ["--config"])
    case "set":
        guard let path = trailing.first, path != "--config" else {
            throw StewardError.commandFailed("Falta la ruta para folder set")
        }
        trailing.removeFirst()
        let nested = Arguments([subcommand] + trailing)
        try nested.validate(allowedFlags: [], valueOptions: ["--config"])
    default:
        throw StewardError.commandFailed("Subcomando folder desconocido: \(subcommand)")
    }
}

private func configURL(from arguments: Arguments) -> URL {
    if let value = arguments.value(after: "--config") {
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
    }
    return ConfigurationIO.defaultConfigPath()
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}

private func printRunSummary(_ summary: RunSummary, asJSON: Bool) throws {
    if asJSON {
        print(try encodeJSON(summary))
    } else {
        print("run_id: \(summary.runID)")
        print("modo: \(summary.mode.rawValue)")
        print("escaneados: \(summary.scanned)")
        print("planificados: \(summary.planned)")
        print("movidos: \(summary.moved)")
        print("aplazados: \(summary.deferred)")
        print("ignorados: \(summary.skipped)")
        print("errores: \(summary.errors)")
    }
}

private func printUndoSummary(_ summary: UndoSummary, asJSON: Bool) throws {
    if asJSON {
        print(try encodeJSON(summary))
    } else {
        print("transacción: \(summary.transactionID)")
        print("modo: undo-\(summary.mode.rawValue)")
        print("planificados: \(summary.planned)")
        print("restaurados: \(summary.restored)")
        print("ignorados: \(summary.skipped)")
        print("errores: \(summary.errors)")
    }
}

private func runDoctor(configurationURL: URL) -> Int32 {
    var failures = 0
    print("TidyDrop doctor")
    print("sistema: \(ProcessInfo.processInfo.operatingSystemVersionString)")
#if os(macOS)
    print("plataforma: macOS [OK]")
#else
    print("plataforma: no es macOS [FALLO para instalación real]")
    failures += 1
#endif

    let requiredExecutables = [
        "/usr/bin/file",
        "/usr/bin/plutil",
        "/bin/launchctl"
    ]
    for path in requiredExecutables {
        if FileManager.default.isExecutableFile(atPath: path) {
            print("utilidad: \(path) [OK]")
        } else {
            print("utilidad: \(path) [FALTA]")
            failures += 1
        }
    }

    do {
        let resolved = try ConfigurationIO.load(from: configurationURL)
        print("config: \(configurationURL.path) [OK]")
        print("source: \(resolved.paths.sourceDirectory.path)")
        print("destination: \(resolved.paths.destinationRoot.path)")
        print("state: \(resolved.paths.stateDirectory.path)")
        print("logs: \(resolved.paths.logDirectory.path)")
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: resolved.paths.sourceDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            print("acceso de lectura a source [OK]")
        } catch {
            print("acceso de lectura a source [FALLO]: \(error)")
            failures += 1
        }
        if FileManager.default.isWritableFile(atPath: resolved.paths.sourceDirectory.path) {
            print("permisos POSIX de escritura en source [OK]")
        } else {
            print("permisos POSIX de escritura en source [FALLO]")
            failures += 1
        }
        print("TCC del LaunchAgent: se valida mediante una pasada real en dry-run durante la instalación")
        print("Acceso total al disco: no requerido ni recomendado")
        print("automatización apply_enabled: \(resolved.config.automation.applyEnabled)")
    } catch {
        print("config [FALLO]: \(error)")
        failures += 1
    }

    if failures == 0 {
        print("resultado: OK")
        return 0
    }
    print("resultado: \(failures) fallo(s)")
    return 4
}

private func setAutomation(enabled: Bool, configurationURL: URL) throws {
    let resolved = try ConfigurationIO.load(from: configurationURL)
    var config = resolved.config
    config.automation.applyEnabled = enabled
    try ConfigurationIO.save(config, to: configurationURL)
    if enabled {
        print("apply_enabled=true")
        print("Las próximas ejecuciones del LaunchAgent podrán mover archivos estables.")
    } else {
        print("apply_enabled=false")
        print("Las próximas ejecuciones del LaunchAgent serán dry-run.")
    }
}

private func launchAgentAccessStatus(for resolved: ResolvedConfiguration) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let legacyAgent = home
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        .appendingPathComponent("com.local.tidydrop.plist")
    let agentInstalled = launchAgentIsLoaded(label: "io.github.bugroo.tidydrop.agent.community.v8")
        || launchAgentIsLoaded(label: "io.github.bugroo.tidydrop.agent.community.v7")
        || launchAgentIsLoaded(label: "io.github.bugroo.tidydrop.agent.community.v6")
        || launchAgentIsLoaded(label: "io.github.bugroo.tidydrop.agent.community.v5")
        || launchAgentIsLoaded(label: "io.github.bugroo.tidydrop.agent")
        || launchAgentIsLoaded(label: "com.local.tidydrop")
        || FileManager.default.fileExists(atPath: legacyAgent.path)
    let record: ScheduledRunRecord?
    if FileManager.default.fileExists(atPath: resolved.paths.scheduledStatusFile.path) {
        record = try? JSONFile.load(
            ScheduledRunRecord.self,
            from: resolved.paths.scheduledStatusFile,
            default: ScheduledRunRecord(outcome: .error, runID: "missing")
        )
    } else {
        record = nil
    }
    return LaunchAgentStatusResolver.accessStatus(
        agentInstalled: agentInstalled,
        scheduledRecord: record
    )
}

private func launchAgentIsLoaded(label: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/\(label)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func printFolderValidation(
    _ validation: ActiveFolderValidation,
    resolved: ResolvedConfiguration
) {
    print("ruta configurada: \(resolved.config.paths.sourceDirectory)")
    print("ruta canónica: \(validation.canonicalPath)")
    print("destination root: \(resolved.paths.destinationRoot.path)")
    print("existe: \(validation.exists ? "sí" : "no")")
    print("lectura: \(validation.readable ? "sí" : "no")")
    print("escritura: \(validation.writable ? "sí" : "no")")
    print("symlink: \(validation.isSymbolicLink ? "sí" : "no")")
    print("filesystem: \(validation.filesystemType ?? "desconocido")")
    print("device: \(validation.deviceID.map(String.init) ?? "desconocido")")
    print("modo: \(resolved.config.automation.applyEnabled ? "apply" : "dry-run")")
    print("acceso LaunchAgent: \(launchAgentAccessStatus(for: resolved))")
}

@MainActor
private func runFolderCommand(_ arguments: Arguments, configurationURL: URL) throws {
    guard let subcommand = arguments.values.first else {
        throw StewardError.commandFailed("Falta el subcomando de folder")
    }
    switch subcommand {
    case "show":
        let resolved = try ConfigurationIO.load(from: configurationURL)
        let validation = try ActiveFolderManager.validate(
            path: resolved.config.paths.sourceDirectory,
            requireAvailable: false
        )
        printFolderValidation(validation, resolved: resolved)

    case "validate":
        let resolved = try ConfigurationIO.load(from: configurationURL)
        let validation = try ActiveFolderManager.validate(path: resolved.config.paths.sourceDirectory)
        printFolderValidation(validation, resolved: resolved)
        print("validación: OK")

    case "set":
        guard arguments.values.indices.contains(1) else {
            throw StewardError.commandFailed("Falta la ruta para folder set")
        }
        let validation = try ActiveFolderManager.set(
            path: arguments.values[1],
            configurationURL: configurationURL
        )
        print("carpeta activa: \(validation.canonicalPath)")
        print("destination_root actualizado a la carpeta activa")
        print("apply_enabled=false; TidyDrop ha vuelto obligatoriamente a dry-run")

    case "reset-downloads":
        let validation = try ActiveFolderManager.resetToDownloads(configurationURL: configurationURL)
        print("carpeta activa: \(validation.canonicalPath)")
        print("apply_enabled=false; TidyDrop ha vuelto obligatoriamente a dry-run")

    case "choose":
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Elegir carpeta"
        panel.message = "TidyDrop organizará localmente esta carpeta. Cambiarla mantiene dry-run."
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let rawDelay = ProcessInfo.processInfo.environment["TIDYDROP_TEST_CHOOSER_CANCEL_AFTER_MS"],
           let delayMilliseconds = Double(rawDelay),
           delayMilliseconds >= 0,
           delayMilliseconds <= 10_000 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delayMilliseconds / 1_000) {
                panel.cancel(nil)
            }
        }
        let selectedURL = panel.runModal() == .OK ? panel.url : nil
        switch try ActiveFolderManager.applySelection(selectedURL, configurationURL: configurationURL) {
        case .cancelled:
            print("Selección cancelada; la configuración no cambió.")
        case .changed(let validation):
            print("carpeta activa: \(validation.canonicalPath)")
            print("apply_enabled=false; TidyDrop ha vuelto obligatoriamente a dry-run")
        }
#else
        throw StewardError.commandFailed("folder choose solo está disponible en macOS")
#endif

    default:
        throw StewardError.commandFailed("Subcomando folder desconocido: \(subcommand)")
    }
}

private func printStatus(configurationURL: URL, asJSON: Bool) throws {
    let resolved = try ConfigurationIO.load(from: configurationURL)
    if asJSON {
        let payload: [String: Any] = [
            "version": programVersion,
            "configuration": configurationURL.path,
            "source_directory": resolved.paths.sourceDirectory.path,
            "destination_root": resolved.paths.destinationRoot.path,
            "state_directory": resolved.paths.stateDirectory.path,
            "log_directory": resolved.paths.logDirectory.path,
            "apply_enabled": resolved.config.automation.applyEnabled,
            "scheduled_mode": resolved.config.automation.applyEnabled ? "apply" : "dry-run",
            "interval_seconds": resolved.config.automation.intervalSeconds
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("versión: \(programVersion)")
        print("configuración: \(configurationURL.path)")
        print("origen: \(resolved.paths.sourceDirectory.path)")
        print("destino: \(resolved.paths.destinationRoot.path)")
        print("modo programado: \(resolved.config.automation.applyEnabled ? "apply" : "dry-run")")
        print("intervalo configurado: \(resolved.config.automation.intervalSeconds) s")
        print("log: \(resolved.paths.humanLogFile.path)")
        print("auditoría: \(resolved.paths.auditLogFile.path)")
        print("errores del agente: \(resolved.paths.agentErrorLogFile.path)")
        print("límite por log: \(resolved.config.logging.maxFileBytes) bytes")
        print("copias rotadas: \(resolved.config.logging.rotatedFileCount)")
        print("límite de manifiestos terminales: \(resolved.config.logging.transactionManifestLimit)")
        print("última pasada programada: \(resolved.paths.scheduledStatusFile.path)")
    }
}

private let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
private var exitCode: Int32 = 0

 do {
    try validateArguments(arguments)
    let configurationURL = configURL(from: arguments)
    switch arguments.command {
    case "help", "--help", "-h":
        printHelp()

    case "version", "--version":
        print(programVersion)

    case "print-default-config":
        print(try encodeJSON(DefaultConfiguration.make()))

    case "init-config":
        if FileManager.default.fileExists(atPath: configurationURL.path), !arguments.contains("--force") {
            throw StewardError.commandFailed(
                "La configuración ya existe: \(configurationURL.path). Usa --force para reemplazarla."
            )
        }
        try ConfigurationIO.save(DefaultConfiguration.make(), to: configurationURL)
        print("Configuración creada: \(configurationURL.path)")
        print("apply_enabled=false")

    case "doctor":
        exitCode = runDoctor(configurationURL: configurationURL)

    case "run":
        let explicitApply = arguments.contains("--apply")
        let explicitDryRun = arguments.contains("--dry-run")
        let scheduled = arguments.contains("--scheduled")
        if explicitApply && explicitDryRun {
            throw StewardError.commandFailed("No combines --apply y --dry-run")
        }
        if scheduled && (explicitApply || explicitDryRun) {
            throw StewardError.commandFailed("No combines --scheduled con --apply o --dry-run")
        }

        if scheduled {
            exitCode = ScheduledExecution.run(configurationURL: configurationURL)
            break
        }

        let resolved = try ConfigurationIO.load(from: configurationURL)
        let mode: ExecutionMode
        if explicitApply {
            mode = .apply
        } else {
            mode = .dryRun
        }
        let engine = try StewardEngine(configuration: resolved)
        do {
            let summary = try engine.run(
                mode: mode,
                recordEmptyRun: true,
                suppressUnchangedDryRunPlans: false
            )
            try printRunSummary(summary, asJSON: arguments.contains("--json"))
            if summary.errors > 0 { exitCode = 5 }
        }

    case "undo":
        let resolved = try ConfigurationIO.load(from: configurationURL)
        let engine = try StewardEngine(configuration: resolved)
        let mode: UndoMode = arguments.contains("--apply") ? .apply : .preview
        let summary = try engine.undoLatest(mode: mode)
        try printUndoSummary(summary, asJSON: arguments.contains("--json"))
        if summary.errors > 0 { exitCode = 5 }

    case "activate":
        try setAutomation(enabled: true, configurationURL: configurationURL)

    case "deactivate":
        try setAutomation(enabled: false, configurationURL: configurationURL)

    case "status":
        try printStatus(configurationURL: configurationURL, asJSON: arguments.contains("--json"))

    case "folder":
        try MainActor.assumeIsolated {
            try runFolderCommand(arguments, configurationURL: configurationURL)
        }

    default:
        throw StewardError.commandFailed("Comando desconocido: \(arguments.command)")
    }
 } catch {
    fputs("ERROR: \(error)\n", stderr)
    if arguments.command == "help" {
        printHelp()
    }
    if exitCode == 0 { exitCode = 2 }
}

exit(exitCode)
