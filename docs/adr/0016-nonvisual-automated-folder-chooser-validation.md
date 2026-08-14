# ADR-0016: Nonvisual automated folder-chooser validation

- Status: Accepted and implemented
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0001](0001-native-macos-application-architecture.md), [ADR-0005](0005-source-bound-relaunch-verification-and-setup-ui.md)

## Context

TidyDrop exposes a native `NSOpenPanel` through `tidydrop folder choose`. The
original validation script opened that real panel and cancelled it after 150 ms
on every local validation, installation and CI run. On an interactive Mac this
produced a brief visible window even though the background agent itself remained
UI-free.

Routine automated verification must not steal focus or create visible windows.
At the same time, the project must retain evidence that the command, AppKit
configuration and cancellation behavior exist, and it must remain possible to
run a real UI smoke test deliberately.

## Decision

`scripts/test-folder-chooser.sh` is nonvisual by default. It verifies:

1. the compiled CLI advertises `folder choose`;
2. source configuration uses one `NSOpenPanel` that selects directories only,
   disallows multiple selection and permits directory creation;
3. the shared selection path remains wired to `ActiveFolderManager`;
4. the self-test regression proving cancellation leaves configuration unchanged
   remains present.

The script opens the real panel only when an operator explicitly sets:

```sh
TIDYDROP_RUN_INTERACTIVE_FOLDER_CHOOSER_TEST=1 ./scripts/test-folder-chooser.sh
```

That explicit smoke test continues to auto-cancel after 150 ms and compare the
configuration checksum. CI, `validate-project.sh` and `install.sh` use the
default nonvisual path.

The product command is unchanged: a user who deliberately runs
`tidydrop folder choose` still receives the native folder selector.

## Consequences

- Automated validation and installation no longer flash or focus a TidyDrop
  window.
- The LaunchAgent remains independently verifiable as a Foundation/CoreServices
  background executable with no AppKit dependency.
- A real panel smoke test is retained but cannot run accidentally.
- Static inspection is not a substitute for a deliberate visual QA pass before
  a stable UI release; it is the safe default for unattended gates.

## Gates

1. Default `test-folder-chooser.sh` exits successfully without invoking the
   modal selector.
2. Agent and GUI application launch counts do not change during the default
   test.
3. The cancellation self-test remains green.
4. Full validation and CI remain green.
5. The opt-in UI smoke-test path remains present and documented.
