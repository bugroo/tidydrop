# Installed runtime audit — 2026-08-14

This audit inspected the Community Preview already installed on macOS before
building the 1.1.1 hotfix. It did not expose file names and did not perform
apply or undo operations against a personal folder.

## Observed installation

- The system application was TidyDrop 1.1.0 build 4, Universal 2, ad hoc signed
  with Hardened Runtime; `codesign --verify --deep --strict` passed.
- The bundled `SMAppService` agent was loaded, had completed 172 launches, and
  reported exit status 0 for its latest run.
- The active folder was `~/Downloads`, automatic mode was `apply`, and the
  latest natural scheduled pass reported `success`, 0 moves, and 0 errors.
- Configuration and state files were private (`0600`) and their directories
  were private (`0700`). No symlinks were present in the installed bundle,
  application support, or log tree.
- Both transaction manifests were terminal and internally consistent: 14
  completed moves, no execution errors, and all 14 undo entries still pending.
  A read-only undo preview planned one restore and performed none.
- Logs occupied about 340 KiB, contained no engine error entries, and no
  unbounded launchd stdout/stderr files existed.

## Runtime and energy observation

One explicit dry-run scanned 11 top-level entries, moved 0 files, and completed
in 0.03 seconds with approximately 14.3 MiB maximum resident memory. After it
finished there were no TidyDrop processes and no TidyDrop power assertions.
The Mac was connected to power, so this session cannot quantify battery
percentage drain. The observed short-lived execution, five-minute interval,
background priority, silent no-op behavior, and absence of a resident process
show no abnormal energy pattern.

## Anomalies found and corrected

1. `folder show` reported `not_installed` because the CLI only looked for the
   legacy user LaunchAgent plist. It now queries the bundled
   `io.github.bugroo.tidydrop.agent` job and resolves the latest scheduled
   outcome through a tested central helper.
2. Active-folder protection covered the legacy user-local bundle but not the
   current `/Applications/TidyDrop.app`. Validation now rejects the system
   bundle, its descendants, and a source root broad enough to contain it.
3. A legacy CLI symlink still targeted the old user-local 1.0.2 bundle. This is
   an installation-coherence issue, not an engine failure. The local update
   repointed it to the CLI embedded in `/Applications/TidyDrop.app`.
4. Replacing the ad hoc bundle left `launchd` holding build 4 and the updated
   agent failed with `EX_CONFIG`. The app now exposes bundle-local
   ServiceManagement register, unregister, status, and refresh operations. The
   update flow re-registers only TidyDrop's own agent before its dry-run gate.
   macOS then exposed the deeper cause: an ad hoc executable has no Team ID and
   the old launch constraint was bound to its previous code hash. Community
   build 5 therefore performs a one-time migration to the versioned
   `io.github.bugroo.tidydrop.agent.community.v5` label; Developer ID releases
   keep the stable production label.

## Final installed state

- TidyDrop 1.1.1 build 5 is installed in `/Applications/TidyDrop.app`; app, CLI,
  and agent are Universal 2 and the complete bundle passes strict code-signature
  verification.
- The Community v5 agent registered as `enabled`, completed its first fresh
  background pass with exit code 0, and the previous build-4 job is not loaded.
- The mandatory post-update gate observed `success`, `dry-run`, `moved=0`, and
  `errors=0`. Only after that evidence was recorded was the previous
  `apply_enabled=true` state restored. No apply execution was forced during the
  update.
- The installed CLI reports version 1.1.1 and resolves background access as
  `success`.
- The next unforced five-minute execution then ran naturally in `apply` mode
  and completed with `success`, 0 moves, and 0 errors. This confirms the final
  configuration without issuing a manual `run --apply` against the personal
  folder.

## Verification of the hotfix

- Debug and release builds with warnings as errors: PASS.
- Swift 6 language-mode build: PASS.
- Independent self-tests: 66 PASS, 0 SKIP, 0 FAIL.
- Stability-race repetition: 20/20 PASS.
- CLI, native folder chooser, LaunchAgent rendering, uninstall isolation,
  static audit, and dry-run demo: PASS.
- Universal 2 Community Preview and development DMGs: built, signed, mounted,
  and revalidated successfully.
- Apply and undo integration remained confined to `/private/tmp`.

## Remaining limits

The Community Preview remains ad hoc signed and not notarized. Updating its
binary may cause macOS to request a new Files & Folders decision. TidyDrop still
uses one active folder and a five-minute scheduled agent rather than FSEvents.
The final metadata check cannot remove the residual TOCTOU window between the
last `lstat(2)` and the atomic rename.
