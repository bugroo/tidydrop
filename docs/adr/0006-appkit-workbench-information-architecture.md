# ADR-0006: AppKit workbench information architecture

- Status: Accepted and implemented in TidyDrop 1.2.0
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0001](0001-native-macos-application-architecture.md), [ADR-0005](0005-source-bound-relaunch-verification-and-setup-ui.md)

## Context

TidyDrop 1.1.2 has a safe native setup window, but activity, classification
rules, transaction history, and conservative undo remain available only through
the CLI and local files. The next product increment must expose those concepts
without becoming a dashboard or hiding operational detail behind decorative
cards.

The product owner accepted an AppKit-first workbench with native navigation,
tables, an inspector, keyboard operation, and the compact “Drop Path” model:

```text
source file  —  matched rule  →  destination
```

## Decision

The main window uses `NSSplitViewController` with three structural regions:

```text
┌────────────────┬────────────────────────────────────┬──────────────────┐
│ Active Folder  │ Activity / Rules / History table   │ Inspector        │
│ Activity       │                                    │                  │
│ Rules          │ source — rule → destination        │ reason, paths,   │
│ History        │                                    │ safety, undo     │
└────────────────┴────────────────────────────────────┴──────────────────┘
```

### Navigation

- **Active Folder** contains the existing privacy, folder, background-agent,
  preview, and apply controls.
- **Activity** shows bounded recent audit events with file, decision,
  destination, and state.
- **Rules** shows ordered category rules. Editing a rule is explicit, validated,
  atomically saved, and always returns automation to dry-run.
- **History** shows durable apply transaction manifests and their undo state.

The sidebar remains visible on desktop instead of using hidden navigation.
Standard AppKit controls provide keyboard focus and baseline accessibility.
Every actionable icon also has a text label or accessibility label.

### Inspector

The inspector never invents derived certainty. It displays only persisted or
deterministically derived facts: source, destination, rule reason, run mode,
transaction status, errors, and whether a transaction still contains an
undoable move.

Undo is a two-stage action. The workbench first executes the existing preview
path. Applying undo requires a separate confirmation and continues to use the
same conservative device/inode and modification checks as the CLI.

### Data boundaries

- Activity reads the existing bounded `audit.jsonl`; it does not create another
  log.
- History reads validated regular transaction manifests through `TidyDropCore`.
- The workbench never follows symlinks and applies bounded reads.
- The transaction journal remains canonical. No SQLite migration is part of
  this ADR.
- The UI is a reader except for existing explicit configuration, preview,
  apply-toggle, rule-save, and undo actions.

### Empty, error, and unavailable states

Each section has a textual empty state. Read or decode failures appear as an
error in the workbench and do not silently produce an empty history. A missing
active source remains `source_unavailable`; the UI does not create it.

### Visual and accessibility constraints

- Native system type, colors, separators, source list, tables, toolbar, and
  inspector.
- No statistic cards, large hero title, decorative gradients, glass panels,
  giant buttons, or animation unrelated to state changes.
- Complete keyboard navigation, visible focus, descriptive controls, truncation
  with tooltips, VoiceOver labels, reduced-motion-compatible behavior, and no
  information communicated by color alone.

## Consequences

The app becomes operationally useful without keeping it open or changing the
proven file engine. JSON remains sufficient for this increment, although large
searchable histories still motivate the separate SQLite prototype. The
controller architecture must keep data loading separate enough to replace the
read model later without changing the journal.

## Verification gates

1. Existing 68 self-tests and all release gates continue to pass.
2. New tests cover bounded audit parsing, corrupt records, manifest ordering,
   rule-save dry-run reset, and undoable-state derivation.
3. An isolated temporary HOME/config drives UI smoke tests; no personal folder
   is used for apply or undo.
4. Light and dark appearances are inspected at minimum and compact window size.
5. Keyboard navigation and accessibility labels are checked on standard
   controls before release.

## References

- [NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller)
- [Accessibility for AppKit](https://developer.apple.com/documentation/appkit/accessibility-for-appkit)
