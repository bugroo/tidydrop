import AppKit
import Foundation
import ServiceManagement
import TidyDropCore

private enum ProductIdentity {
    static let stableAgentPlist = "io.github.bugroo.tidydrop.agent.plist"
    static let previousCommunityAgentPlists = [
        "io.github.bugroo.tidydrop.agent.community.v8.plist",
        "io.github.bugroo.tidydrop.agent.community.v7.plist",
        "io.github.bugroo.tidydrop.agent.community.v6.plist",
        "io.github.bugroo.tidydrop.agent.community.v5.plist"
    ]
    static let communityAgentPlist = "io.github.bugroo.tidydrop.agent.community.v9.plist"
    static let legacyAgentLabel = "com.local.tidydrop"
    static let version = "1.3.0"
    static let distributionChannel = Bundle.main.object(
        forInfoDictionaryKey: "TidyDropDistributionChannel"
    ) as? String ?? "development"
    static let buildIdentity = Bundle.main.object(
        forInfoDictionaryKey: "TidyDropBuildIdentity"
    ) as? String ?? version
    static let isCommunityPreview = distributionChannel == "community"
    static var agentPlist: String {
        isCommunityPreview ? communityAgentPlist : stableAgentPlist
    }
    static var previousAgentPlists: [String] {
        isCommunityPreview ? previousCommunityAgentPlists + [stableAgentPlist] : []
    }
    static var agentLabel: String {
        isCommunityPreview
            ? "io.github.bugroo.tidydrop.agent.community.v9"
            : "io.github.bugroo.tidydrop.agent"
    }
}

private struct LegacyAgentMigration {
    let originalPlist: URL
    let disabledPlist: URL
    let wasLoaded: Bool

    func restore() throws {
        guard try FileSystemSecurity.pathEntryExists(disabledPlist) else { return }
        guard try !FileSystemSecurity.pathEntryExists(originalPlist) else {
            throw StewardError.unsafePath("Both active and disabled legacy agent plists exist")
        }
        try FileManager.default.moveItem(at: disabledPlist, to: originalPlist)
        if wasLoaded {
            let result = try Launchctl.run([
                "bootstrap", "gui/\(getuid())", originalPlist.path
            ])
            guard result == 0 else {
                throw StewardError.commandFailed("The previous agent plist was restored but could not be reloaded")
            }
        }
    }
}

private enum Launchctl {
    static func run(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}

private func applicationConfigurationURL() -> URL {
    guard let flagIndex = CommandLine.arguments.firstIndex(of: "--config"),
          CommandLine.arguments.indices.contains(flagIndex + 1) else {
        return ConfigurationIO.defaultConfigPath()
    }
    return URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
        .standardizedFileURL
}

@main
private struct TidyDropApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--bundle-self-check") {
            exit(bundleSelfCheck())
        }
        if let command = CommandLine.arguments.first(where: {
            ["--agent-status", "--agent-register", "--agent-unregister", "--agent-refresh"]
                .contains($0)
        }) {
            exit(agentControl(command: command))
        }
        let application = NSApplication.shared
        switch ProcessInfo.processInfo.environment["TIDYDROP_TEST_APPEARANCE"] {
        case "light": application.appearance = NSAppearance(named: .aqua)
        case "dark": application.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    private static func bundleSelfCheck() -> Int32 {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "io.github.bugroo.tidydrop",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "TidyDropApp",
              ["development", "community", "distribution"].contains(ProductIdentity.distributionChannel),
              !ProductIdentity.buildIdentity.isEmpty else {
            fputs("bundle identity mismatch\n", stderr)
            return 2
        }
        let requiredPaths = [
            "Contents/Resources/tidydrop",
            "Contents/Resources/tidydrop-agent",
            "Contents/Resources/TidyDrop.icns",
            "Contents/Library/LaunchAgents/\(ProductIdentity.stableAgentPlist)",
            "Contents/Library/LaunchAgents/\(ProductIdentity.communityAgentPlist)"
        ] + ProductIdentity.previousCommunityAgentPlists.map {
            "Contents/Library/LaunchAgents/\($0)"
        }
        for relativePath in requiredPaths {
            let candidate = bundle.bundleURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                fputs("missing bundle component: \(relativePath)\n", stderr)
                return 2
            }
        }
        print("TidyDrop bundle self-check: PASS")
        return 0
    }

    private static func agentControl(command: String) -> Int32 {
        let service = SMAppService.agent(plistName: ProductIdentity.agentPlist)
        do {
            switch command {
            case "--agent-status":
                break
            case "--agent-register":
                try service.register()
            case "--agent-unregister":
                try service.unregister()
            case "--agent-refresh":
                for previousPlist in ProductIdentity.previousAgentPlists {
                    let previousService = SMAppService.agent(plistName: previousPlist)
                    if previousService.status == .enabled
                        || previousService.status == .requiresApproval {
                        try previousService.unregister()
                    }
                }
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
                try service.register()
            default:
                return 64
            }
            print("agent_status=\(agentStatusName(service.status))")
            return 0
        } catch {
            fputs("agent control failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func agentStatusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires_approval"
        case .notRegistered: return "not_registered"
        case .notFound: return "not_found"
        @unknown default: return "unknown"
        }
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private enum ToolbarIdentifier {
        static let chooseFolder = NSToolbarItem.Identifier("TidyDropChooseFolder")
        static let preview = NSToolbarItem.Identifier("TidyDropPreview")
        static let refresh = NSToolbarItem.Identifier("TidyDropRefresh")
    }
    private let configurationURL = applicationConfigurationURL()
    private let service = SMAppService.agent(plistName: ProductIdentity.agentPlist)
    private var window: NSWindow?
    private var folderPathControl = NSPathControl()
    private var serviceLabel = NSTextField(labelWithString: "")
    private var modeLabel = NSTextField(labelWithString: "")
    private var lastRunLabel = NSTextField(labelWithString: "")
    private var folderStepLabel = NSTextField(labelWithString: "")
    private var backgroundStepLabel = NSTextField(labelWithString: "")
    private var automationStepLabel = NSTextField(labelWithString: "")
    private var resultLabel = NSTextField(wrappingLabelWithString: "")
    private var backgroundButton = NSButton()
    private var automationButton = NSButton()
    private var previewButton = NSButton()
    private var progressIndicator = NSProgressIndicator()
    private var verificationStartedAt: Date?
    private var verificationTimer: Timer?
    private var verificationAttempts = 0
    private var verificationKickstarted = false
    private var backgroundVerified = false
    private var previewRunning = false
    private var undoRunning = false
    private var workbenchController: WorkbenchViewController?
    private var updateCenterController: UpdateCenterWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try prepareConfigurationForCurrentVersion()
            buildMainMenu()
            buildWindow()
            refreshStatus()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            resumeBackgroundVerification()
        } catch {
            presentFatalError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        verificationTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func prepareConfigurationForCurrentVersion() throws {
        if !FileManager.default.fileExists(atPath: configurationURL.path) {
            try ConfigurationIO.save(DefaultConfiguration.make(), to: configurationURL)
        }

        let resolved = try ConfigurationIO.load(from: configurationURL)
        let marker = resolved.paths.stateDirectory.appendingPathComponent("installed-app-version")
        let recordedVersion = try? String(
            decoding: FileSystemSecurity.readRegularFile(marker, maximumBytes: 128),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if recordedVersion != ProductIdentity.buildIdentity {
            var configuration = resolved.config
            configuration.automation.applyEnabled = false
            try ConfigurationIO.save(configuration, to: configurationURL)
            try FileSystemSecurity.atomicWritePrivate(
                Data("\(ProductIdentity.buildIdentity)\n".utf8),
                to: marker,
                maximumBytes: 128
            )
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidyDrop"
        window.minSize = NSSize(width: 900, height: 560)
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.center()
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "Organize one folder, locally")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString:
            "TidyDrop classifies finished files without uploading names, metadata, or content. " +
            "Setup starts in preview mode and never requires Full Disk Access."
        )
        introduction.textColor = .secondaryLabelColor

        var introductoryViews: [NSView] = [title, introduction]
        var communityWarning: NSTextField?
        if ProductIdentity.isCommunityPreview {
            let previewWarning = NSTextField(wrappingLabelWithString:
                "Community Preview: this build is not notarized by Apple. Install it only from " +
                "the official bugroo/tidydrop GitHub Release and verify its checksum."
            )
            previewWarning.textColor = .systemOrange
            previewWarning.font = .systemFont(ofSize: 13, weight: .medium)
            previewWarning.maximumNumberOfLines = 3
            communityWarning = previewWarning
            introductoryViews.append(previewWarning)
        }

        folderPathControl.pathStyle = .standard
        folderPathControl.isEditable = false
        folderPathControl.toolTip = "The only folder TidyDrop currently watches"
        folderPathControl.setAccessibilityLabel("Active folder")

        let folderRow = statusRow(title: "Active folder", value: folderPathControl)
        let serviceRow = statusRow(title: "Background agent", value: serviceLabel)
        let modeRow = statusRow(title: "Automatic moving", value: modeLabel)
        let lastRunRow = statusRow(title: "Last background run", value: lastRunLabel)

        let chooseButton = actionButton("Choose Folder…", action: #selector(chooseFolder))
        chooseButton.keyEquivalent = "o"
        chooseButton.keyEquivalentModifierMask = [.command]
        chooseButton.toolTip = "Choose one folder to organize; changing it always returns to preview mode"
        previewButton = actionButton("Run Safe Preview", action: #selector(runPreview))
        previewButton.keyEquivalent = "r"
        previewButton.keyEquivalentModifierMask = [.command, .shift]
        previewButton.toolTip = "Show what TidyDrop would do without moving anything"
        backgroundButton = actionButton("Enable Background Organization", action: #selector(handleBackgroundAgent))
        automationButton = actionButton("Enable Automatic Organization", action: #selector(toggleAutomation))

        let setupTitle = NSTextField(labelWithString: "Setup")
        setupTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        for label in [folderStepLabel, backgroundStepLabel, automationStepLabel] {
            label.font = .systemFont(ofSize: 13)
            label.maximumNumberOfLines = 1
        }
        let setupSteps = NSStackView(views: [folderStepLabel, backgroundStepLabel, automationStepLabel])
        setupSteps.orientation = .vertical
        setupSteps.alignment = .leading
        setupSteps.spacing = 7

        let primaryActions = NSStackView(views: [chooseButton, previewButton])
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 10
        primaryActions.distribution = .fillEqually

        let modeActions = NSStackView(views: [backgroundButton, automationButton])
        modeActions.orientation = .horizontal
        modeActions.spacing = 10
        modeActions.distribution = .fillEqually

        resultLabel.textColor = .secondaryLabelColor
        resultLabel.maximumNumberOfLines = 3
        resultLabel.setAccessibilityLabel("TidyDrop status message")

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        let feedbackRow = NSStackView(views: [progressIndicator, resultLabel])
        feedbackRow.orientation = .horizontal
        feedbackRow.alignment = .centerY
        feedbackRow.spacing = 8

        let stack = NSStackView(views: introductoryViews + [
            separator(), folderRow, serviceRow, modeRow, lastRunRow,
            separator(), setupTitle, setupSteps, primaryActions, modeActions, feedbackRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let activeFolderContent = NSView()
        activeFolderContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: activeFolderContent.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: activeFolderContent.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: activeFolderContent.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: activeFolderContent.bottomAnchor, constant: -12),
            introduction.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            serviceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lastRunRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            setupSteps.widthAnchor.constraint(equalTo: stack.widthAnchor),
            primaryActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedbackRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultLabel.widthAnchor.constraint(lessThanOrEqualTo: feedbackRow.widthAnchor)
        ])
        communityWarning?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        self.window = window
        let workbench = WorkbenchViewController(
            configurationURL: configurationURL,
            activeFolderView: activeFolderContent,
            actions: WorkbenchActions(
                editRule: { [weak self] index in self?.editRule(at: index) },
                previewUndo: { [weak self] in self?.runUndo(mode: .preview) },
                applyUndo: { [weak self] in self?.confirmAndApplyUndo() },
                refresh: { [weak self] in self?.refreshWorkbench() }
            )
        )
        self.workbenchController = workbench
        window.contentViewController = workbench
        let toolbar = NSToolbar(identifier: "TidyDropWorkbenchToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About TidyDrop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updatesItem = applicationMenu.addItem(
            withTitle: "Software Updates…",
            action: #selector(showUpdateCenter),
            keyEquivalent: ""
        )
        updatesItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit TidyDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let fileItem = NSMenuItem()
        fileItem.title = "File"
        let fileMenu = NSMenu(title: "File")
        let chooseFolderItem = fileMenu.addItem(withTitle: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: "o")
        chooseFolderItem.target = self
        let refreshItem = fileMenu.addItem(withTitle: "Refresh", action: #selector(refreshWorkbenchAction), keyEquivalent: "r")
        refreshItem.target = self
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let actionItem = NSMenuItem()
        actionItem.title = "Actions"
        let actionMenu = NSMenu(title: "Actions")
        let previewItem = NSMenuItem(title: "Run Safe Preview", action: #selector(runPreview), keyEquivalent: "r")
        previewItem.keyEquivalentModifierMask = [.command, .shift]
        previewItem.target = self
        actionMenu.addItem(previewItem)
        actionItem.submenu = actionMenu
        mainMenu.addItem(actionItem)

        let viewItem = NSMenuItem()
        viewItem.title = "View"
        let viewMenu = NSMenu(title: "View")
        let sections: [(String, Selector, String)] = [
            ("Active Folder", #selector(showActiveFolder), "1"),
            ("Activity", #selector(showActivity), "2"),
            ("Rules", #selector(showRules), "3"),
            ("History", #selector(showHistory), "4")
        ]
        for (title, action, key) in sections {
            let sectionItem = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            sectionItem.target = self
        }
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.chooseFolder,
            ToolbarIdentifier.preview,
            .flexibleSpace,
            ToolbarIdentifier.refresh
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifier.chooseFolder,
            ToolbarIdentifier.preview,
            .flexibleSpace,
            ToolbarIdentifier.refresh
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case ToolbarIdentifier.chooseFolder:
            item.label = "Choose Folder"
            item.paletteLabel = item.label
            item.toolTip = "Choose the single folder TidyDrop organizes"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Choose folder")
            item.target = self
            item.action = #selector(chooseFolder)
        case ToolbarIdentifier.preview:
            item.label = "Preview"
            item.paletteLabel = item.label
            item.toolTip = "Run a safe preview without moving files"
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Run safe preview")
            item.target = self
            item.action = #selector(runPreview)
        case ToolbarIdentifier.refresh:
            item.label = "Refresh"
            item.paletteLabel = item.label
            item.toolTip = "Reload activity, rules, history, and current status"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refreshWorkbenchAction)
        default:
            return nil
        }
        return item
    }

    @objc private func refreshWorkbenchAction() {
        refreshWorkbench()
    }

    @objc private func showUpdateCenter() {
        if updateCenterController == nil {
            updateCenterController = UpdateCenterWindowController(
                productVersion: ProductIdentity.version,
                buildIdentity: ProductIdentity.buildIdentity,
                distributionChannel: ProductIdentity.distributionChannel
            )
        }
        updateCenterController?.showWindow(nil)
        updateCenterController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showActiveFolder() {
        workbenchController?.select(.activeFolder)
    }

    @objc private func showActivity() {
        workbenchController?.select(.activity)
    }

    @objc private func showRules() {
        workbenchController?.select(.rules)
    }

    @objc private func showHistory() {
        workbenchController?.select(.history)
    }

    private func statusRow(title: String, value: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        if let textValue = value as? NSTextField {
            textValue.alignment = .right
            textValue.lineBreakMode = .byTruncatingMiddle
        }
        let row = NSStackView(views: [label, NSView(), value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setAccessibilityLabel(title)
        return button
    }

    private func refreshStatus(message: String? = nil) {
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            folderPathControl.url = resolved.paths.sourceDirectory
            let applyEnabled = resolved.config.automation.applyEnabled
            modeLabel.stringValue = applyEnabled ? "Enabled" : "Preview only"
            serviceLabel.stringValue = serviceStatusDescription
            lastRunLabel.stringValue = lastRunDescription(for: resolved)
            folderStepLabel.stringValue = "✓  Folder selected"
            backgroundStepLabel.stringValue = backgroundVerified
                ? "✓  Background access verified"
                : "○  Background access needs verification"
            automationStepLabel.stringValue = applyEnabled
                ? "✓  Automatic organization enabled"
                : "○  Preview only — no files move"

            updateBackgroundButton()
            automationButton.title = applyEnabled
                ? "Pause Automatic Organization"
                : "Enable Automatic Organization"
            automationButton.isEnabled = applyEnabled || backgroundVerified
            automationButton.bezelStyle = applyEnabled ? .rounded : .texturedRounded
            previewButton.isEnabled = !previewRunning
            if verificationTimer != nil || previewRunning {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
            if let message { resultLabel.stringValue = message }
            workbenchController?.reloadData()
        } catch {
            resultLabel.stringValue = "Configuration error: \(error)"
            backgroundButton.isEnabled = false
            automationButton.isEnabled = false
            previewButton.isEnabled = false
        }
    }

    private func updateBackgroundButton() {
        switch service.status {
        case .enabled:
            backgroundButton.title = backgroundVerified
                ? "Background Access Verified"
                : "Verify Background Access"
            backgroundButton.isEnabled = !backgroundVerified && verificationTimer == nil
        case .requiresApproval:
            backgroundButton.title = "Open Login Item Settings"
            backgroundButton.isEnabled = true
        case .notRegistered:
            backgroundButton.title = "Enable Background Organization"
            backgroundButton.isEnabled = true
        case .notFound:
            backgroundButton.title = "Background Agent Missing"
            backgroundButton.isEnabled = false
        @unknown default:
            backgroundButton.title = "Check Background Organization"
            backgroundButton.isEnabled = true
        }
        backgroundButton.setAccessibilityLabel(backgroundButton.title)
    }

    private var serviceStatusDescription: String {
        switch service.status {
        case .enabled: return backgroundVerified ? "Enabled and verified" : "Enabled; verification pending"
        case .requiresApproval: return "Approval required in Login Items"
        case .notRegistered: return "Not registered"
        case .notFound: return "Agent missing from app bundle"
        @unknown default: return "Unknown"
        }
    }

    private func lastRunDescription(for resolved: ResolvedConfiguration) -> String {
        guard let record = scheduledRecord(for: resolved) else { return "Not yet recorded" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let timestamp = formatter.string(from: record.timestamp)
        switch record.outcome {
        case .success:
            return "Success · \(timestamp) · \(record.moved ?? 0) moved"
        case .lockBusy:
            return "Deferred · \(timestamp) · another run was active"
        case .sourceUnavailable:
            return "Folder unavailable · \(timestamp)"
        case .error:
            return "Failed · \(timestamp)"
        }
    }

    private func scheduledRecord(for resolved: ResolvedConfiguration) -> ScheduledRunRecord? {
        guard FileManager.default.fileExists(atPath: resolved.paths.scheduledStatusFile.path) else {
            return nil
        }
        return try? JSONFile.load(
            ScheduledRunRecord.self,
            from: resolved.paths.scheduledStatusFile,
            default: ScheduledRunRecord(outcome: .error, runID: "missing")
        )
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "TidyDrop will classify files locally inside this folder."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let selected = panel.url else {
                self.refreshStatus(message: "Selection cancelled; nothing changed.")
                return
            }
            do {
                _ = try ActiveFolderManager.applySelection(selected, configurationURL: self.configurationURL)
                self.backgroundVerified = false
                self.refreshStatus(message: "Folder changed. Automatic moving returned to preview mode.")
                if self.service.status == .enabled {
                    self.startFreshBackgroundVerification()
                }
            } catch {
                self.presentError("Folder not accepted", error: error)
            }
        }
    }

    @objc private func handleBackgroundAgent() {
        switch service.status {
        case .enabled:
            do {
                let resolved = try ConfigurationIO.load(from: configurationURL)
                guard !resolved.config.automation.applyEnabled else {
                    refreshStatus(message: "Pause automatic organization before forcing a safe verification run.")
                    return
                }
                startFreshBackgroundVerification()
            } catch {
                presentError("Background access could not be verified", error: error)
            }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            refreshStatus(message: "Allow TidyDrop under Login Items, then return here. Moving remains disabled.")
            beginBackgroundVerification(kickstart: false)
        case .notRegistered:
            registerAgent()
        case .notFound:
            refreshStatus(message: "The background agent is missing from this app bundle.")
        @unknown default:
            refreshStatus(message: "macOS returned an unknown background-agent state.")
        }
    }

    private func registerAgent() {
        var legacyMigration: LegacyAgentMigration?
        do {
            legacyMigration = try disableLegacyAgentIfNeeded()
            for previousPlist in ProductIdentity.previousAgentPlists {
                let previousService = SMAppService.agent(plistName: previousPlist)
                if previousService.status == .enabled || previousService.status == .requiresApproval {
                    try previousService.unregister()
                }
            }
            try service.register()
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                refreshStatus(message: "Allow TidyDrop under Login Items, then return here.")
                beginBackgroundVerification(kickstart: false)
            } else {
                refreshStatus(message: "Agent registered. Verifying background folder access…")
                startFreshBackgroundVerification()
            }
        } catch {
            if let legacyMigration {
                do {
                    try legacyMigration.restore()
                } catch {
                    presentError("The previous agent requires manual recovery", error: error)
                    return
                }
            }
            presentError("The background agent could not be registered", error: error)
        }
    }

    private func disableLegacyAgentIfNeeded() throws -> LegacyAgentMigration? {
        let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(ProductIdentity.legacyAgentLabel).plist")
        guard try FileSystemSecurity.pathEntryExists(legacyPlist) else { return nil }

        let legacyData = try FileSystemSecurity.readRegularFile(
            legacyPlist,
            maximumBytes: 1_048_576
        )
        let propertyList = try PropertyListSerialization.propertyList(from: legacyData, format: nil)
        guard let dictionary = propertyList as? [String: Any],
              dictionary["Label"] as? String == ProductIdentity.legacyAgentLabel,
              let arguments = dictionary["ProgramArguments"] as? [String],
              let executable = arguments.first,
              executable == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/TidyDrop.app/Contents/MacOS/tidydrop")
                .path else {
            throw StewardError.unsafePath("The legacy agent plist does not match a known TidyDrop installation")
        }

        let alert = NSAlert()
        alert.messageText = "Upgrade the existing TidyDrop agent?"
        alert.informativeText = "The previous agent must be disabled before the bundled agent starts. " +
            "Configuration and transaction history will be preserved."
        alert.addButton(withTitle: "Disable Previous Agent")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw StewardError.commandFailed("Upgrade cancelled; the previous agent remains unchanged")
        }

        let resolved = try ConfigurationIO.load(from: configurationURL)
        var configuration = resolved.config
        configuration.automation.applyEnabled = false
        try ConfigurationIO.save(configuration, to: configurationURL)

        let domain = "gui/\(getuid())/\(ProductIdentity.legacyAgentLabel)"
        let wasLoaded = try Launchctl.run(["print", domain]) == 0
        if wasLoaded {
            guard try Launchctl.run(["bootout", domain]) == 0 else {
                throw StewardError.commandFailed("The previous agent could not be disabled safely")
            }
        }

        let resolvedAfterDisable = try ConfigurationIO.load(from: configurationURL)
        let migrationDirectory = resolvedAfterDisable.paths.stateDirectory
            .appendingPathComponent("migration", isDirectory: true)
        try FileSystemSecurity.ensurePrivateDirectory(migrationDirectory)
        let disabledPlist = migrationDirectory
            .appendingPathComponent("\(ProductIdentity.legacyAgentLabel).plist.disabled")
        guard try !FileSystemSecurity.pathEntryExists(disabledPlist) else {
            if wasLoaded {
                _ = try? Launchctl.run([
                    "bootstrap", "gui/\(getuid())", legacyPlist.path
                ])
            }
            throw StewardError.unsafePath("A previous legacy-agent migration backup already exists")
        }
        do {
            try FileManager.default.moveItem(at: legacyPlist, to: disabledPlist)
        } catch {
            if wasLoaded {
                _ = try? Launchctl.run([
                    "bootstrap", "gui/\(getuid())", legacyPlist.path
                ])
            }
            throw error
        }
        guard try !FileSystemSecurity.pathEntryExists(legacyPlist) else {
            throw StewardError.commandFailed("The previous LaunchAgent plist remains active")
        }
        return LegacyAgentMigration(
            originalPlist: legacyPlist,
            disabledPlist: disabledPlist,
            wasLoaded: wasLoaded
        )
    }

    private func resumeBackgroundVerification() {
        guard service.status == .enabled else { return }
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            if let record = scheduledRecord(for: resolved),
               BackgroundVerificationPolicy.accepts(
                   record,
                   sourceDirectory: resolved.paths.sourceDirectory,
                   applyEnabled: resolved.config.automation.applyEnabled,
                   maximumAge: max(TimeInterval(resolved.config.automation.intervalSeconds * 2), 600)
               ) {
                backgroundVerified = true
                refreshStatus(message: "Background access is verified for the active folder.")
            } else if resolved.config.automation.applyEnabled {
                refreshStatus(message: "Background access will be rechecked on the next automatic run.")
            } else {
                startFreshBackgroundVerification()
            }
        } catch {
            presentError("Background verification could not start", error: error)
        }
    }

    private func startFreshBackgroundVerification() {
        beginBackgroundVerification(kickstart: true)
    }

    private func beginBackgroundVerification(kickstart: Bool) {
        verificationTimer?.invalidate()
        verificationStartedAt = Date()
        verificationAttempts = 0
        verificationKickstarted = false
        backgroundVerified = false
        if kickstart {
            verificationKickstarted = kickstartBackgroundAgent()
        }
        verificationTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(checkBackgroundVerificationTimer(_:)),
            userInfo: nil,
            repeats: true
        )
        refreshStatus(message: verificationKickstarted
            ? "Verifying background access with a safe preview run…"
            : "Waiting for macOS to make the background agent available…")
    }

    @objc private func checkBackgroundVerificationTimer(_ timer: Timer) {
        verificationAttempts += 1
        if service.status == .enabled && !verificationKickstarted {
            if let resolved = try? ConfigurationIO.load(from: configurationURL),
               !resolved.config.automation.applyEnabled {
                verificationKickstarted = kickstartBackgroundAgent()
            }
        }
        if verifyLatestBackgroundRun() {
            timer.invalidate()
            verificationTimer = nil
            backgroundVerified = true
            refreshStatus(message: "Background access verified in preview mode with zero moves.")
        } else if verificationAttempts >= 180 {
            timer.invalidate()
            verificationTimer = nil
            refreshStatus(message: "Background access was not verified. Moving remains disabled.")
        } else {
            refreshStatus()
        }
    }

    private func verifyLatestBackgroundRun() -> Bool {
        guard let started = verificationStartedAt,
              let resolved = try? ConfigurationIO.load(from: configurationURL),
              let record = scheduledRecord(for: resolved) else { return false }
        return BackgroundVerificationPolicy.accepts(
            record,
            sourceDirectory: resolved.paths.sourceDirectory,
            applyEnabled: false,
            notOlderThan: started,
            maximumAge: 600
        )
    }

    private func kickstartBackgroundAgent() -> Bool {
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            try AgentRunRequestSignal.request(
                at: resolved.paths.agentRunRequestFile,
                sourceDirectory: resolved.paths.sourceDirectory
            )
            return true
        } catch {
            return false
        }
    }

    @objc private func runPreview() {
        guard !previewRunning else { return }
        previewRunning = true
        refreshStatus(message: "Running preview…")
        let configurationURL = self.configurationURL
        Task.detached(priority: .utility) {
            do {
                let resolved = try ConfigurationIO.load(from: configurationURL)
                let summary = try StewardEngine(configuration: resolved).run(mode: .dryRun)
                await MainActor.run { [weak self] in
                    self?.previewRunning = false
                    self?.refreshStatus(message:
                        "Preview complete: \(summary.scanned) scanned, \(summary.planned) planned, " +
                        "0 moved, \(summary.errors) errors."
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.previewRunning = false
                    self?.presentError("Preview failed", error: error)
                }
            }
        }
    }

    @objc private func toggleAutomation() {
        guard let resolved = try? ConfigurationIO.load(from: configurationURL) else {
            refreshStatus(message: "The configuration could not be loaded safely.")
            return
        }
        if resolved.config.automation.applyEnabled {
            deactivate()
        } else {
            activate()
        }
    }

    private func activate() {
        guard backgroundVerified else {
            refreshStatus(message: "Verify background access before enabling automatic organization.")
            return
        }
        if ProductIdentity.isCommunityPreview {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Enable a non-notarized Community Preview?"
            alert.informativeText = "Only continue if this copy came from the official " +
                "bugroo/tidydrop GitHub Release and its checksum was verified."
            alert.addButton(withTitle: "Enable Automatic Organization")
            alert.addButton(withTitle: "Keep Preview Only")
            guard alert.runModal() == .alertFirstButtonReturn else {
                refreshStatus(message: "Automatic moving remains disabled.")
                return
            }
        }
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            var configuration = resolved.config
            configuration.automation.applyEnabled = true
            try ConfigurationIO.save(configuration, to: configurationURL)
            refreshStatus(message: "Automatic organization is enabled for future stable files.")
        } catch {
            presentError("Moving could not be enabled", error: error)
        }
    }

    private func deactivate() {
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            var configuration = resolved.config
            configuration.automation.applyEnabled = false
            try ConfigurationIO.save(configuration, to: configurationURL)
            refreshStatus(message: "Automatic moving is disabled. Preview remains available.")
            if service.status == .enabled {
                startFreshBackgroundVerification()
            }
        } catch {
            presentError("Moving could not be disabled", error: error)
        }
    }

    private func editRule(at index: Int) {
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            guard resolved.config.classification.categories.indices.contains(index) else {
                throw StewardError.invalidConfiguration("The selected rule no longer exists")
            }
            let rule = resolved.config.classification.categories[index]
            let nameField = NSTextField(string: rule.name)
            let extensionsField = NSTextField(string: rule.extensions.joined(separator: ", "))
            let mimeTypesField = NSTextField(string: rule.mimeTypes.joined(separator: ", "))
            let mimePrefixesField = NSTextField(string: rule.mimePrefixes.joined(separator: ", "))
            let patternsView = NSTextView()
            patternsView.string = rule.namePatterns.joined(separator: "\n")
            patternsView.isRichText = false
            patternsView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let patternsScroll = NSScrollView()
            patternsScroll.documentView = patternsView
            patternsScroll.hasVerticalScroller = true
            patternsScroll.borderType = .bezelBorder
            patternsScroll.translatesAutoresizingMaskIntoConstraints = false
            patternsScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

            let fields: [(String, NSView)] = [
                ("Category", nameField),
                ("Extensions (comma separated)", extensionsField),
                ("MIME types (comma separated)", mimeTypesField),
                ("MIME prefixes (comma separated)", mimePrefixesField),
                ("Name patterns (one per line)", patternsScroll)
            ]
            let editor = NSStackView()
            editor.orientation = .vertical
            editor.alignment = .leading
            editor.spacing = 6
            editor.translatesAutoresizingMaskIntoConstraints = false
            for (labelText, field) in fields {
                let label = NSTextField(labelWithString: labelText)
                label.font = .systemFont(ofSize: 12, weight: .medium)
                field.translatesAutoresizingMaskIntoConstraints = false
                editor.addArrangedSubview(label)
                editor.addArrangedSubview(field)
                field.widthAnchor.constraint(equalToConstant: 470).isActive = true
            }

            let alert = NSAlert()
            alert.messageText = "Edit \(rule.name)"
            alert.informativeText = "Saving validates the complete configuration and returns automatic organization to preview mode. Existing files and transaction history are not changed."
            alert.addButton(withTitle: "Save Rule")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = editor
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let updated = CategoryRule(
                name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                extensions: commaSeparatedValues(extensionsField.stringValue),
                mimeTypes: commaSeparatedValues(mimeTypesField.stringValue),
                mimePrefixes: commaSeparatedValues(mimePrefixesField.stringValue),
                namePatterns: patternsView.string.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            _ = try WorkbenchData.replaceCategory(
                at: index,
                with: updated,
                configurationURL: configurationURL
            )
            refreshStatus(message: "Rule saved. Automatic organization returned to preview mode.")
        } catch {
            presentError("The rule could not be saved", error: error)
        }
    }

    private func commaSeparatedValues(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func confirmAndApplyUndo() {
        guard !undoRunning else { return }
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            let manifest = try TransactionStore(directory: resolved.paths.transactionsDirectory)
                .latestUndoable()
            let undoableCount = manifest.moves.filter {
                $0.executionStatus == .completed && $0.undoStatus != .undone
            }.count
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Undo the latest transaction?"
            alert.informativeText = "TidyDrop will first pause automatic organization, then conservatively attempt to restore \(undoableCount) item(s) from \(manifest.runID). Files that changed or would overwrite another item are skipped."
            alert.addButton(withTitle: "Undo \(undoableCount) Item(s)")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            var configuration = resolved.config
            configuration.automation.applyEnabled = false
            try ConfigurationIO.save(configuration, to: configurationURL)
            runUndo(mode: .apply)
        } catch {
            presentError("Undo could not start", error: error)
        }
    }

    private func runUndo(mode: UndoMode) {
        guard !undoRunning else { return }
        undoRunning = true
        refreshStatus(message: mode == .preview ? "Previewing undo…" : "Applying conservative undo…")
        let configurationURL = self.configurationURL
        Task.detached(priority: .utility) {
            do {
                let resolved = try ConfigurationIO.load(from: configurationURL)
                let summary = try StewardEngine(configuration: resolved).undoLatest(mode: mode)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.undoRunning = false
                    if mode == .preview {
                        self.refreshStatus(message: "Undo preview: \(summary.planned) eligible, \(summary.skipped) skipped, \(summary.errors) errors.")
                        self.presentUndoSummary(summary, title: "Undo Preview")
                    } else {
                        self.refreshStatus(message: "Undo complete: \(summary.restored) restored, \(summary.skipped) skipped, \(summary.errors) errors. Automatic organization remains paused.")
                        self.presentUndoSummary(summary, title: "Undo Complete")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.undoRunning = false
                    self?.presentError("Undo failed safely", error: error)
                }
            }
        }
    }

    private func presentUndoSummary(_ summary: UndoSummary, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        if summary.mode == .preview {
            alert.informativeText = "\(summary.planned) item(s) are currently eligible to restore. \(summary.skipped) would be skipped and \(summary.errors) produced errors. No files were moved by this preview."
        } else {
            alert.informativeText = "\(summary.restored) item(s) restored. \(summary.skipped) skipped and \(summary.errors) produced errors. Automatic organization remains paused."
        }
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func refreshWorkbench() {
        refreshStatus()
        workbenchController?.reloadData()
    }

    private func presentError(_ title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        if let window { alert.beginSheetModal(for: window) }
        refreshStatus(message: "\(title). No files were moved by this action.")
    }

    private func presentFatalError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "TidyDrop could not start safely"
        alert.runModal()
        NSApp.terminate(nil)
    }
}
