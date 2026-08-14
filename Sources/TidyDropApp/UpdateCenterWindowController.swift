import AppKit
import TidyDropCore

@MainActor
final class UpdateCenterWindowController: NSWindowController {
    private let productVersion: String
    private let buildIdentity: String
    private let channel: UpdateChannel?
    private let currentVersion: ReleaseVersion?
    private let service = UpdateCheckService()

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let checkButton = NSButton()
    private let releaseButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private var availableRelease: AvailableRelease?
    private var checkTask: Task<Void, Never>?

    init(productVersion: String, buildIdentity: String, distributionChannel: String) {
        self.productVersion = productVersion
        self.buildIdentity = buildIdentity
        switch distributionChannel {
        case "community":
            channel = .community
            currentVersion = ReleaseVersion.parse(tag: buildIdentity, channel: .community)
        case "distribution":
            channel = .stable
            currentVersion = ReleaseVersion.parse(tag: "v\(productVersion)", channel: .stable)
        default:
            channel = nil
            currentVersion = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidyDrop Updates"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        checkTask?.cancel()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityLabel("TidyDrop application icon")

        let titleLabel = NSTextField(labelWithString: "Software Updates")
        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)

        let identityLabel = NSTextField(labelWithString:
            "Installed: \(buildIdentity)  ·  Channel: \(channelName)"
        )
        identityLabel.textColor = .secondaryLabelColor
        identityLabel.lineBreakMode = .byTruncatingMiddle
        identityLabel.toolTip = buildIdentity

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setAccessibilityLabel("Update status")

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.setAccessibilityLabel("Update details")

        checkButton.title = "Check for Updates"
        checkButton.bezelStyle = .rounded
        checkButton.target = self
        checkButton.action = #selector(checkForUpdates)
        checkButton.keyEquivalent = "\r"
        checkButton.toolTip = "Contact the official bugroo/tidydrop GitHub release channel once"
        checkButton.isEnabled = channel != nil && currentVersion != nil

        releaseButton.title = "View Official Release"
        releaseButton.bezelStyle = .rounded
        releaseButton.target = self
        releaseButton.action = #selector(openOfficialRelease)
        releaseButton.isEnabled = false
        releaseButton.toolTip = "Open the validated release tag on github.com/bugroo/tidydrop"

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        if channel == nil {
            statusLabel.stringValue = "Update checks are disabled for development builds."
            detailLabel.stringValue = "Official Community and distribution bundles carry a release channel identity."
        } else if currentVersion == nil {
            statusLabel.stringValue = "This build has an invalid release identity."
            detailLabel.stringValue = "TidyDrop will not guess a version or contact an update service."
        } else {
            statusLabel.stringValue = "No update check has been made."
            detailLabel.stringValue = privacyDescription
        }

        let headerText = NSStackView(views: [titleLabel, identityLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4

        let header = NSStackView(views: [icon, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let statusRow = NSStackView(views: [progressIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let buttonRow = NSStackView(views: [releaseButton, NSView(), closeButton, checkButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [header, separator(), statusRow, detailLabel, NSView(), buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    @objc private func checkForUpdates() {
        guard checkTask == nil, let channel, let currentVersion else { return }
        availableRelease = nil
        releaseButton.isEnabled = false
        checkButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "Checking the official release channel…"
        detailLabel.stringValue = privacyDescription

        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await service.check(
                    channel: channel,
                    currentVersion: currentVersion,
                    productVersion: productVersion
                )
                guard !Task.isCancelled else { return }
                finishCheck(with: release)
            } catch {
                guard !Task.isCancelled else { return }
                finishCheck(with: error)
            }
        }
    }

    private func finishCheck(with release: AvailableRelease?) {
        checkTask = nil
        progressIndicator.stopAnimation(nil)
        checkButton.isEnabled = true
        availableRelease = release
        releaseButton.isEnabled = release != nil
        if let release {
            statusLabel.stringValue = "A newer TidyDrop release is available: \(release.version.tag)"
            detailLabel.stringValue =
                "\(release.displayName)\nTidyDrop will not download or install it. Review the official release page before updating manually."
        } else {
            statusLabel.stringValue = "TidyDrop is up to date on the \(channelName) channel."
            detailLabel.stringValue = privacyDescription
        }
    }

    private func finishCheck(with error: Error) {
        checkTask = nil
        progressIndicator.stopAnimation(nil)
        checkButton.isEnabled = true
        statusLabel.stringValue = "TidyDrop could not check for updates."
        detailLabel.stringValue = error.localizedDescription
    }

    @objc private func openOfficialRelease() {
        guard let url = availableRelease?.officialPageURL,
              url.scheme == "https",
              url.host == "github.com",
              url.path.hasPrefix("/bugroo/tidydrop/releases/tag/") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeWindow() {
        close()
    }

    private var channelName: String {
        switch channel {
        case .community: return "Community Preview"
        case .stable: return "Stable"
        case nil: return "Development"
        }
    }

    private var privacyDescription: String {
        "Checks run only when you press the button. The request sends no file names, folder paths, cookies, credentials, or telemetry."
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
