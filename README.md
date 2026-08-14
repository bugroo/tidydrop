# 🗂️ TidyDrop

**A private, native macOS file organizer that keeps Downloads tidy without
uploading, indexing, or profiling your files.**

`🍎 macOS 13+` · `🔒 Local-only runtime` · `↩️ Conservative undo` ·
`⚡ Low-overhead background work` · `🧩 Apple Silicon + Intel`

[⬇️ **Download TidyDrop 1.2.0 Community Preview**](https://github.com/bugroo/tidydrop/releases/download/v1.2.0-community.1/TidyDrop-1.2.0-community-preview-macos-universal.dmg)
· [Release notes](docs/COMMUNITY-PREVIEW-RELEASE-NOTES.md)
· [Security](docs/SECURITY.md)

> [!IMPORTANT]
> The current Community Preview is ad hoc signed and is not Apple-notarized.
> macOS requires a one-time **Open Anyway** approval. Install only from the
> official `bugroo/tidydrop` release and never disable Gatekeeper.

## ✨ Why TidyDrop

Downloads folders quickly become a mix of documents, images, installers,
archives, media, and unfinished downloads. Cleaning them manually is repetitive,
but many automatic organizers are difficult to trust: they may overwrite files,
move downloads that are still being written, require broad permissions, or send
file information to another service.

TidyDrop provides a small, predictable alternative built around a few clear
promises:

- **Private by default.** File names, metadata, and content stay on the Mac.
- **Safe before automatic.** Every installation and folder change returns to a
  non-moving preview before organization can be enabled.
- **Transparent.** Categories and decisions are visible, logged locally, and
  auditable.
- **Reversible.** Completed moves are journaled for a conservative undo that
  refuses unsafe restores.
- **Quiet.** The background agent sleeps on FSEvents when nothing changes and
  avoids periodic scans and repeated log writes.

## 🧭 How it works

1. TidyDrop watches the first level of one selected folder.
2. It waits for downloads to stop changing before classifying them.
3. It previews the result or moves each stable file into a clear category.
4. It records successful moves locally so the latest transaction can be undone.

### Safety boundaries

- Organizes only the first level of one selected folder.
- Waits until a file appears stable before moving it.
- Ignores hidden files, folders, apps, symbolic links, and incomplete downloads.
- Never overwrites an existing file.
- Records completed moves so the latest transaction can be undone safely.
- Responds to filesystem events, reconciles once at startup, and uses one
  short-lived timer only while a candidate is still changing.
- Uses no network connection, telemetry, advertising, or cloud processing.

### Default categories

The default folder is `~/Downloads`. TidyDrop creates category folders only when
they are needed. Folder labels come from the installed configuration and may be
localized; the categories are:

- Documents
- Images
- Videos
- Audio
- Archives
- Installers
- Code
- Disk images (`ISOs`)
- Data
- Torrents
- Other

TidyDrop never reorganizes subfolders recursively.

## ⬇️ Download

TidyDrop 1.2.0 Community Preview is available as a Universal 2 DMG from
[GitHub Releases](https://github.com/bugroo/tidydrop/releases/tag/v1.2.0-community.1).
It contains a native setup app and a bundled background agent, so recipients do
not need Terminal or development tools.

The native workbench provides four focused sections: Active Folder, Activity,
Rules, and History. Its inspector explains the selected item and exposes rule
editing or conservative undo only where those actions are valid.

This preview is not signed with Apple Developer ID and is not notarized by
Apple. macOS therefore requires a one-time manual exception. The notarized
general-public release remains a later milestone.

Requirements:

- macOS 13 or later. The current installed-source path has been verified on
  Apple silicon; the Universal 2 release candidate still requires a real Intel
  installation test.
- Apple Command Line Tools only when building or installing from source.

The DMG requires neither Xcode nor Apple Command Line Tools. Full Xcode,
Homebrew, Python, administrator privileges, and Full Disk Access are not
required.

## Install the Community Preview

1. Download the DMG and checksum from the
   [official prerelease](https://github.com/bugroo/tidydrop/releases/tag/v1.2.0-community.1).
2. Open the DMG and drag `TidyDrop.app` to Applications.
3. Try to open TidyDrop once. macOS is expected to block the first launch.
4. Open **System Settings → Privacy & Security** and select **Open Anyway**.
5. Open TidyDrop, enable background organization, and let it verify a safe preview run.
6. Enable automatic organization only after the preview reports zero errors.

Never disable Gatekeeper, remove quarantine attributes, grant Full Disk Access,
or install TidyDrop through a remote `curl | sh` command.

Download the matching
[SHA-256 checksum](https://github.com/bugroo/tidydrop/releases/download/v1.2.0-community.1/TidyDrop-1.2.0-community-preview-macos-universal.sha256)
and verify the DMG with:

```sh
shasum -a 256 -c TidyDrop-1.2.0-community-preview-macos-universal.sha256
```

## 🛠️ Install from source

The source installation remains available for contributors and auditors:

```sh
git clone https://github.com/bugroo/tidydrop.git
cd tidydrop
./scripts/install.sh
```

The installer adds TidyDrop only to the current user account and leaves automatic
moving disabled. Review the initial dry-run before enabling it:

```sh
"$HOME/.local/bin/tidydrop" status
"$HOME/.local/bin/tidydrop" folder show
"$HOME/.local/bin/tidydrop" run --dry-run
```

Enable automatic organization only when the preview looks correct:

```sh
"$HOME/.local/bin/tidydrop" activate
```

Disable moving at any time:

```sh
"$HOME/.local/bin/tidydrop" deactivate
```

## 📁 Choose a folder

TidyDrop manages one active folder at a time.

```sh
"$HOME/.local/bin/tidydrop" folder show
"$HOME/.local/bin/tidydrop" folder choose
"$HOME/.local/bin/tidydrop" folder set "/path/with spaces"
"$HOME/.local/bin/tidydrop" folder validate
"$HOME/.local/bin/tidydrop" folder reset-downloads
```

Choosing or changing the folder always returns TidyDrop to dry-run and does not
move anything immediately.

The filesystem root, the complete home folder, `~/Library`, TidyDrop's own data,
symbolic-link roots, and unavailable or unwritable folders are rejected. A local,
writable subfolder in iCloud Drive, Google Drive, a network volume, or an external
drive may be selected, but macOS permissions and offline availability must be
checked separately.

## ↩️ Preview and undo

Preview a pass without moving files:

```sh
"$HOME/.local/bin/tidydrop" run --dry-run
```

Preview the latest available undo:

```sh
"$HOME/.local/bin/tidydrop" undo
```

Restore that transaction:

```sh
"$HOME/.local/bin/tidydrop" undo --apply
```

Undo refuses to overwrite a new file or restore an item whose identity no longer
matches the recorded move.

## 🔐 Privacy and macOS permissions

File names and metadata stay on the Mac. TidyDrop does not transmit file content
or usage information.

macOS may request access to Downloads, Documents, Desktop, removable volumes, or
network volumes. Grant access only under:

```text
System Settings → Privacy & Security → Files & Folders
```

Do not grant Full Disk Access. If the selected folder becomes unavailable or
permission is revoked, TidyDrop moves nothing and tries again on a later pass.

## 📋 Status and logs

```sh
"$HOME/.local/bin/tidydrop" status
"$HOME/.local/bin/tidydrop" folder show
```

Local logs and reversible transaction records are stored under:

```text
~/Library/Logs/TidyDrop
~/Library/Application Support/TidyDrop
```

Logs are size-limited and rotated. Empty scheduled passes do not continuously
append log entries.

## 🧹 Uninstall

Remove the app, command, and scheduled agent while preserving configuration and
history:

```sh
./scripts/uninstall.sh
```

Also remove TidyDrop's configuration, logs, and transaction history:

```sh
./scripts/uninstall.sh --purge
```

Uninstalling TidyDrop never removes organized files or category folders.

## ⚠️ Known limitations

- One active folder is supported at a time.
- The Community Preview is ad hoc signed and requires a manual Gatekeeper
  exception; it is not Apple notarized.
- App Sandbox and security-scoped bookmarks are validated prototypes but are
  not enabled in the Community bundle without a stable Developer ID identity.
- A macOS or TidyDrop update may require Files & Folders permission again.
- Cloud and removable-volume files must be available locally before they can be
  organized.
- A file-writing application can still change a file in the very small interval
  between the final safety check and the move.

## 🛡️ Security

Please report vulnerabilities through
[GitHub's private security reporting](https://github.com/bugroo/tidydrop/security/advisories/new).
Do not publish unpatched vulnerability details in a public issue.

## 🤝 Contributing

Bug reports, macOS compatibility results, accessibility feedback, documentation
improvements, and focused pull requests are welcome. Please review the
[architecture decisions](docs/adr/README.md) and run the repository's validation
scripts before submitting code.

If TidyDrop is useful to you, starring the repository helps other people find a
private macOS Downloads organizer without ads, telemetry, or cloud processing.

## License

[MIT](LICENSE)
