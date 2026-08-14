import AppKit
import Foundation
import TidyDropCore

enum WorkbenchSection: Int, CaseIterable {
    case activeFolder
    case activity
    case rules
    case history

    var title: String {
        switch self {
        case .activeFolder: return "Active Folder"
        case .activity: return "Activity"
        case .rules: return "Rules"
        case .history: return "History"
        }
    }

    var symbolName: String {
        switch self {
        case .activeFolder: return "folder"
        case .activity: return "arrow.right.arrow.left"
        case .rules: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct WorkbenchActions {
    let editRule: (Int) -> Void
    let previewUndo: () -> Void
    let applyUndo: () -> Void
    let refresh: () -> Void
}

@MainActor
final class WorkbenchViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let configurationURL: URL
    private let activeFolderView: NSView
    private let actions: WorkbenchActions
    private let sidebarTable = NSTableView()
    private let contentTable = NSTableView()
    private let contentScroll = NSScrollView()
    private let contentContainer = NSView()
    private let sectionTitle = NSTextField(labelWithString: "")
    private let sectionDetail = NSTextField(wrappingLabelWithString: "")
    private let inspectorTitle = NSTextField(labelWithString: "Inspector")
    private let inspectorBody = NSTextField(wrappingLabelWithString: "")
    private let inspectorActions = NSStackView()
    private let editRuleButton = NSButton()
    private let previewUndoButton = NSButton()
    private let applyUndoButton = NSButton()
    private var selectedSection: WorkbenchSection = .activeFolder
    private var activity: [AuditEvent] = []
    private var agentRuns: [StoredAgentRun] = []
    private var rules: [CategoryRule] = []
    private var history: [TransactionManifest] = []
    private var loadError: String?
    private var activityDatabaseError: String?

    init(configurationURL: URL, activeFolderView: NSView, actions: WorkbenchActions) {
        self.configurationURL = configurationURL
        self.activeFolderView = activeFolderView
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        preferredContentSize = NSSize(width: 1_080, height: 680)

        let sidebar = NSViewController()
        sidebar.view = buildSidebar()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 168
        sidebarItem.maximumThickness = 230

        let content = NSViewController()
        content.view = buildContent()
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 480

        let inspector = NSViewController()
        inspector.view = buildInspector()
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 330

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        sidebarTable.selectRowIndexes(IndexSet(integer: selectedSection.rawValue), byExtendingSelection: false)
        reloadData()
        showSelectedSection()
    }

    func reloadData() {
        do {
            let resolved = try ConfigurationIO.load(from: configurationURL)
            rules = resolved.config.classification.categories
            activity = try WorkbenchData.auditEvents(
                at: resolved.paths.auditLogFile,
                rotatedFileCount: resolved.config.logging.rotatedFileCount,
                maximumFileBytes: resolved.config.logging.maxFileBytes,
                limit: 500
            ).filter { event in
                !["run_started", "run_finished"].contains(event.action)
            }
            do {
                agentRuns = try AgentActivityDatabase.recentRuns(
                    at: resolved.paths.activityDatabaseFile,
                    limit: 100
                )
                activityDatabaseError = nil
            } catch {
                agentRuns = []
                activityDatabaseError = "Background activity index unavailable: \(error)"
            }
            if try FileSystemSecurity.pathEntryExists(resolved.paths.transactionsDirectory) {
                history = try TransactionStore(directory: resolved.paths.transactionsDirectory)
                    .manifests(limit: 200)
            } else {
                history = []
            }
            loadError = nil
        } catch {
            activity = []
            agentRuns = []
            rules = []
            history = []
            loadError = "TidyDrop could not load this section safely: \(error)"
            activityDatabaseError = nil
        }
        configureContentColumns()
        contentTable.reloadData()
        if selectedSection != .activeFolder,
           contentTable.numberOfRows > 0,
           !contentTable.selectedRowIndexes.contains(where: { $0 < contentTable.numberOfRows }) {
            contentTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSectionHeader()
        updateInspector()
    }

    func select(_ section: WorkbenchSection) {
        sidebarTable.selectRowIndexes(
            IndexSet(integer: section.rawValue),
            byExtendingSelection: false
        )
        selectedSection = section
        showSelectedSection()
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar-item"))
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.rowHeight = 30
        sidebarTable.style = .sourceList
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.setAccessibilityLabel("TidyDrop sections")

        let scroll = NSScrollView()
        scroll.documentView = sidebarTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func buildContent() -> NSView {
        sectionTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        sectionTitle.setAccessibilityLabel("Current TidyDrop section")
        sectionDetail.textColor = .secondaryLabelColor
        sectionDetail.maximumNumberOfLines = 2

        contentTable.dataSource = self
        contentTable.delegate = self
        contentTable.usesAlternatingRowBackgroundColors = true
        contentTable.allowsMultipleSelection = false
        contentTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        contentTable.setAccessibilityLabel("TidyDrop workbench table")
        contentScroll.documentView = contentTable
        contentScroll.hasVerticalScroller = true
        contentScroll.hasHorizontalScroller = false
        contentScroll.autohidesScrollers = true
        contentScroll.translatesAutoresizingMaskIntoConstraints = false

        activeFolderView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(activeFolderView)
        contentContainer.addSubview(contentScroll)
        NSLayoutConstraint.activate([
            activeFolderView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            activeFolderView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            activeFolderView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            activeFolderView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentScroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        let stack = NSStackView(views: [sectionTitle, sectionDetail, contentContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sectionDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return container
    }

    private func buildInspector() -> NSView {
        inspectorTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        inspectorTitle.setAccessibilityLabel("Inspector heading")
        inspectorBody.textColor = .secondaryLabelColor
        inspectorBody.maximumNumberOfLines = 0
        inspectorBody.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        inspectorBody.setAccessibilityLabel("Selected item details")

        editRuleButton.title = "Edit Rule…"
        editRuleButton.target = self
        editRuleButton.action = #selector(editSelectedRule)
        editRuleButton.setAccessibilityLabel("Edit selected classification rule")
        previewUndoButton.title = "Preview Undo"
        previewUndoButton.target = self
        previewUndoButton.action = #selector(previewSelectedUndo)
        previewUndoButton.setAccessibilityLabel("Preview undo for the latest undoable transaction")
        applyUndoButton.title = "Undo…"
        applyUndoButton.target = self
        applyUndoButton.action = #selector(applySelectedUndo)
        applyUndoButton.setAccessibilityLabel("Undo the latest undoable transaction")

        inspectorActions.orientation = .vertical
        inspectorActions.alignment = .leading
        inspectorActions.spacing = 8
        inspectorActions.addArrangedSubview(editRuleButton)
        inspectorActions.addArrangedSubview(previewUndoButton)
        inspectorActions.addArrangedSubview(applyUndoButton)

        let stack = NSStackView(views: [inspectorTitle, inspectorBody, inspectorActions, NSView()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inspectorBody.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inspectorActions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sidebarTable { return WorkbenchSection.allCases.count }
        switch selectedSection {
        case .activeFolder: return 0
        case .activity: return activity.count
        case .rules: return rules.count
        case .history: return history.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebarTable {
            guard let section = WorkbenchSection(rawValue: row) else { return nil }
            let cell = NSTableCellView()
            let symbol = NSImageView(image: NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil) ?? NSImage())
            let label = NSTextField(labelWithString: section.title)
            label.lineBreakMode = .byTruncatingTail
            symbol.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(symbol)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                symbol.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                symbol.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                symbol.widthAnchor.constraint(equalToConstant: 16),
                symbol.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        let value = contentValue(column: identifier, row: row)
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = identifier == "detail" ? .byTruncatingTail : .byTruncatingMiddle
        field.toolTip = value
        field.setAccessibilityLabel(columnTitle(for: identifier))
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === sidebarTable {
            guard let section = WorkbenchSection(rawValue: max(0, sidebarTable.selectedRow)) else { return }
            selectedSection = section
            showSelectedSection()
        } else if table === contentTable {
            updateInspector()
        }
    }

    private func showSelectedSection() {
        activeFolderView.isHidden = selectedSection != .activeFolder
        contentScroll.isHidden = selectedSection == .activeFolder
        configureContentColumns()
        contentTable.reloadData()
        if contentTable.numberOfRows > 0 {
            contentTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSectionHeader()
        updateInspector()
    }

    private func updateSectionHeader() {
        sectionTitle.stringValue = selectedSection.title
        if let loadError, selectedSection != .activeFolder {
            sectionDetail.stringValue = loadError
            sectionDetail.textColor = .systemRed
            return
        }
        sectionDetail.textColor = .secondaryLabelColor
        switch selectedSection {
        case .activeFolder:
            sectionDetail.stringValue = "Choose one folder, verify background access, and control preview or automatic organization."
        case .activity:
            sectionDetail.stringValue = activity.isEmpty
                ? "No recorded activity yet. A safe preview will show proposed decisions here."
                : "Recent local decisions. Select a row to inspect the complete Drop Path."
        case .rules:
            sectionDetail.stringValue = "Rules run in this order. Saving a change always returns automatic organization to preview mode."
        case .history:
            sectionDetail.stringValue = history.isEmpty
                ? "No apply transactions have been recorded."
                : "Durable move journals. Only the latest eligible transaction can be undone."
        }
    }

    private func configureContentColumns() {
        for column in contentTable.tableColumns {
            contentTable.removeTableColumn(column)
        }
        let columns: [(String, String, CGFloat)]
        switch selectedSection {
        case .activeFolder:
            columns = []
        case .activity:
            columns = [
                ("item", "File", 140), ("decision", "Decision", 115),
                ("destination", "Destination", 135), ("status", "Status", 95),
                ("time", "Time", 115)
            ]
        case .rules:
            columns = [
                ("order", "Order", 50), ("category", "Category", 135),
                ("matches", "Matches", 220), ("destination", "Destination", 135)
            ]
        case .history:
            columns = [
                ("time", "Date", 130), ("run", "Run", 145),
                ("files", "Files", 55), ("status", "Status", 115),
                ("undo", "Undo", 80)
            ]
        }
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = min(width, 60)
            contentTable.addTableColumn(column)
        }
    }

    private func contentValue(column: String, row: Int) -> String {
        switch selectedSection {
        case .activeFolder:
            return ""
        case .activity:
            guard activity.indices.contains(row) else { return "" }
            let event = activity[row]
            switch column {
            case "item": return event.source.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
            case "decision": return event.category ?? event.reason ?? "—"
            case "destination": return event.destination.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? "—"
            case "status": return displayAction(event.action)
            case "time": return Self.dateFormatter.string(from: event.timestamp)
            default: return ""
            }
        case .rules:
            guard rules.indices.contains(row) else { return "" }
            let rule = rules[row]
            switch column {
            case "order": return "\(row + 1)"
            case "category": return rule.name
            case "matches": return ruleSummary(rule)
            case "destination": return rule.name
            default: return ""
            }
        case .history:
            guard history.indices.contains(row) else { return "" }
            let transaction = history[row]
            switch column {
            case "time": return Self.dateFormatter.string(from: transaction.startedAt)
            case "run": return transaction.runID
            case "files": return "\(transaction.moves.count)"
            case "status": return displayStatus(transaction.status)
            case "undo": return transaction.containsUndoableMove ? "Available" : "Complete"
            default: return ""
            }
        }
    }

    private func updateInspector() {
        editRuleButton.isHidden = true
        previewUndoButton.isHidden = true
        applyUndoButton.isHidden = true
        let row = contentTable.selectedRow
        switch selectedSection {
        case .activeFolder:
            inspectorTitle.stringValue = "Privacy boundary"
            var details = [
                "TidyDrop works only inside the selected folder. It does not upload file names, metadata, content, or usage information."
            ]
            if let latestRun = agentRuns.first {
                details.append(
                    "Last background run\n\(Self.dateFormatter.string(from: latestRun.timestamp)) · "
                        + "\(latestRun.outcome.rawValue) · \(latestRun.mode ?? "unknown")"
                )
            }
            if let activityDatabaseError {
                details.append(activityDatabaseError)
            }
            inspectorBody.stringValue = details.joined(separator: "\n\n")
        case .activity:
            inspectorTitle.stringValue = "Drop Path"
            guard activity.indices.contains(row) else {
                inspectorBody.stringValue = "Select an activity row to see why TidyDrop made that decision."
                return
            }
            let event = activity[row]
            inspectorBody.stringValue = [
                "Source\n\(event.source ?? "—")",
                "Rule\n\(event.reason ?? "—")",
                "Destination\n\(event.destination ?? "—")",
                "State\n\(displayAction(event.action)) · \(event.mode)",
                event.detail.map { "Detail\n\($0)" }
            ].compactMap { $0 }.joined(separator: "\n\n")
        case .rules:
            inspectorTitle.stringValue = "Rule"
            guard rules.indices.contains(row) else {
                inspectorBody.stringValue = "Select a rule to inspect or edit its matches."
                return
            }
            let rule = rules[row]
            inspectorBody.stringValue = [
                "Category\n\(rule.name)",
                "Extensions\n\(rule.extensions.isEmpty ? "—" : rule.extensions.joined(separator: ", "))",
                "MIME types\n\(rule.mimeTypes.isEmpty ? "—" : rule.mimeTypes.joined(separator: ", "))",
                "MIME prefixes\n\(rule.mimePrefixes.isEmpty ? "—" : rule.mimePrefixes.joined(separator: ", "))",
                "Name patterns\n\(rule.namePatterns.isEmpty ? "—" : rule.namePatterns.joined(separator: "\n"))"
            ].joined(separator: "\n\n")
            editRuleButton.isHidden = false
        case .history:
            inspectorTitle.stringValue = "Transaction"
            guard history.indices.contains(row) else {
                inspectorBody.stringValue = "Select a transaction to inspect its durable journal."
                return
            }
            let transaction = history[row]
            inspectorBody.stringValue = [
                "Run\n\(transaction.runID)",
                "Started\n\(Self.dateFormatter.string(from: transaction.startedAt))",
                "Status\n\(displayStatus(transaction.status))",
                "Moves\n\(transaction.moves.count)",
                "Errors\n\(transaction.errors.isEmpty ? "None" : transaction.errors.joined(separator: "\n"))"
            ].joined(separator: "\n\n")
            let latestUndoableRunID = history.first(where: \.containsUndoableMove)?.runID
            let selectedIsLatestUndoable = transaction.runID == latestUndoableRunID
            previewUndoButton.isHidden = !selectedIsLatestUndoable
            applyUndoButton.isHidden = !selectedIsLatestUndoable
        }
    }

    @objc private func editSelectedRule() {
        guard rules.indices.contains(contentTable.selectedRow) else { return }
        actions.editRule(contentTable.selectedRow)
    }

    @objc private func previewSelectedUndo() {
        actions.previewUndo()
    }

    @objc private func applySelectedUndo() {
        actions.applyUndo()
    }

    private func ruleSummary(_ rule: CategoryRule) -> String {
        var parts: [String] = []
        if !rule.extensions.isEmpty { parts.append("\(rule.extensions.count) extensions") }
        if !rule.mimeTypes.isEmpty { parts.append("\(rule.mimeTypes.count) MIME types") }
        if !rule.mimePrefixes.isEmpty { parts.append("\(rule.mimePrefixes.count) MIME groups") }
        if !rule.namePatterns.isEmpty { parts.append("\(rule.namePatterns.count) name patterns") }
        return parts.isEmpty ? "Fallback only" : parts.joined(separator: " · ")
    }

    private func displayAction(_ action: String) -> String {
        switch action {
        case "would_move": return "Proposed"
        case "move_planned": return "Prepared"
        case "moved": return "Moved"
        case "deferred": return "Waiting"
        case "skipped": return "Ignored"
        case "restored": return "Restored"
        case "move_error", "item_error", "undo_error": return "Error"
        default: return action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func displayStatus(_ status: TransactionStatus) -> String {
        switch status {
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .completedWithErrors: return "Completed with errors"
        case .fullyUndone: return "Fully undone"
        case .partiallyUndone: return "Partially undone"
        }
    }

    private func columnTitle(for identifier: String) -> String {
        contentTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.title ?? "Value"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
