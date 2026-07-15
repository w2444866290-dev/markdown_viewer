# Real macOS App E2E Harness

`scripts/e2e/run-real-app-e2e.sh` launches the packaged Debug app through `scripts/run-debug.sh` with an isolated profile and bundled visual fixture.
It never drives the USER app or reads USER documents or application-session data.
Passive safety evidence reads only process identifiers for frontmost applications plus two pointer-coordinate endpoints.
Every passive size and interface state receives its own marked profile and process under the selected evidence directory.

## Requirements and permissions

The runner requires Xcode Command Line Tools or full Xcode, Python 3, the macOS `screencapture`, `sips`, and `caffeinate` tools, and Screen Recording permission.
Pillow is not required by the E2E runner itself.

| Tier | Screen Recording | CGEvent posting | Listen-event access | Accessibility trust | Unlocked console | Takes user focus or pointer |
|---|---|---|---|---|---|---|
| Default passive | Required | Not required | Not required | Not required | Not required | No |
| `--foreground-smoke` or `--foreground-batch NAME` | Required | Required | Required | Required | Required | Yes, one bounded call or five independently bounded tab/session phases |
| `--keyboard-only` | Required | Required | Not required | Not required | Not required | Yes, legacy matrix |
| `--extended-full-pointer` | Required | Required | Not required | Required | Required | Yes, legacy matrix |

Every tier launches each isolated Debug app through `scripts/run-debug.sh --background`.
The passive tier neither activates the app nor posts keyboard, mouse, scroll, or synthetic wake events.
It also skips `reset-sidebar-filter` and forces the sidebar inspector's non-mutating `--passive` path.
Input Monitoring or Accessibility can satisfy the CGEvent posting preflight used by keyboard-only mode.
Bounded foreground batches and extended full-pointer separately need Accessibility so they can focus the intended app and target pointer controls.
Bounded foreground batches also require Input Monitoring listen-event access so their listen-only event tap can stop safely when the user operates the keyboard or pointer.
Extended full-pointer does not run that interference monitor and therefore does not require separate listen-event access beyond its posting and Accessibility preflights.
Those pointer tiers exit with code 3 and write schema-version-2 blocked `evidence.json` before launch when `CGSSessionScreenIsLocked` is true or Accessibility trust is unavailable.

## Test tiers

### Passive tier

Run the default, non-interfering tier with:

```bash
./scripts/e2e/run-real-app-e2e.sh
```

The passive tier captures seven states at `1180x760`, `860x560`, and `1440x900` without taking focus, moving the pointer, or posting input.
The state matrix is `default`, `palette`, `find`, `preview`, `sidebar-hidden`, `source-editor`, and `table-editor`, mapped to the real-app labels required by the strict visual comparator.
These are deterministic Debug launch-state presets for settled rendering and geometry, not evidence of the user actions that would normally open or modify those states.
Every size and state pair launches in a separate profile and PID.
Before each of those 21 app launches it registers for workspace activation notifications, takes an initial frontmost snapshot, atomically publishes a ready handshake, and samples the frontmost PID about every 25 ms.
The observer runs until after the target process exits, and the runner fails closed if the observer exits early, times out, or ever sees the target become frontmost.
The selected native main window must remain at WindowServer layer zero and report `onScreen=false` both when it is identified and immediately before its exact window number is captured.
Separate frontmost-PID and pointer snapshots bracket every process, and any endpoint change is a hard failure, including when the user moves the pointer and leaves it at a different location during that process lifecycle.
State readiness comes from stable Debug diagnostics and required geometry anchors rather than a fixed launch delay.
The table editor additionally proves its deterministic per-size scroll offset, authoritative header-cell selection, reference table-grid frame, and visible page origin before capture.
Sidebar evidence comes from the screenshot and Vision OCR even when Accessibility permission is available, so inspection cannot activate the app.
`--passive` selects this tier explicitly, while `--static-only` remains only as a deprecated compatibility alias.

For a fast development check of one or more canonical pairs, scope the passive runner explicitly:

```bash
./scripts/e2e/run-real-app-e2e.sh \
  --probe-sizes 1180x760 \
  --probe-states preview
```

The probe accepts comma-separated subsets of `1180x760`, `860x560`, and `1440x900`, plus the seven visual state names listed above.
It executes the Cartesian product of the selected axes; when only one probe option is present, the omitted axis keeps its complete canonical list.
It defaults to `build/e2e/real-app-probe-latest`, still enforces offscreen lifecycle and no-input guarantees, and skips every unrequested app launch.
Any explicit probe filter marks the result as `runScope=development-probe` and `strictVisualAcceptanceEligible=false`, even if the caller explicitly lists all 21 pairs.
A development probe is useful for iteration but can never replace the unfiltered 3x7 strict-acceptance run.

### Bounded foreground batches

Run the small palette and Find batch explicitly with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-smoke
```

`--foreground-smoke` is an alias for `--foreground-batch palette-find`.
It runs `block-find` and `palette-keyboard` as separate driver calls, conservatively estimated at 2190 ms and 1690 ms.
Each call independently reserves its final 400 ms for cleanup and restores focus and pointer before the runner captures the phase session and diagnostic snapshot.
The second phase begins with `Command+F` to re-establish an open, focused Find panel before double Shift.
Run the independent table-controls batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch table-controls
```

Run the independent structured-editor batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch editor-structure
```

Run the independent editor-boundaries and table-navigation batches with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch editor-boundaries
./scripts/e2e/run-real-app-e2e.sh --foreground-batch table-navigation
```

Run the independent Find options and regex replacement batches with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch find-options
./scripts/e2e/run-real-app-e2e.sh --foreground-batch find-regex-replace
```

Run the independent preview-content batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch preview-content
```

Run the independent preview-footnotes batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch preview-footnotes
```

Run the independent outline-navigation batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch outline-navigation
```

Run the two independent sidebar batches with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch sidebar-filter-navigation
./scripts/e2e/run-real-app-e2e.sh --foreground-batch sidebar-layout-controls
```

Run the tab and session lifecycle suite with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch tab-session-lifecycle
```

The runner exposes thirteen named bounded foreground suites: `palette-find`, `find-options`, `find-regex-replace`, `preview-content`, `preview-footnotes`, `outline-navigation`, `sidebar-filter-navigation`, `sidebar-layout-controls`, `tab-session-lifecycle`, `table-controls`, `table-navigation`, `editor-structure`, and `editor-boundaries`.
All suites run only at `1180x760`.
`palette-find` uses two independently bounded foreground phases, `block-find` and `palette-keyboard`.
`sidebar-layout-controls` uses two independently bounded foreground phases, `collapse-minimum` and `maximum-toggle`.
The tab and session suite uses five independently bounded foreground phases named `switch-commit`, `close-right-reopen`, `close-left-seed`, `seed-layout`, and `relaunch-scroll-check`.
Their validator-backed conservative foreground estimates are 1640 ms, 2690 ms, 2000 ms, 1660 ms, and 1880 ms respectively.
Every single-call suite and every phase of a multi-phase suite has its own fixed 4-second hard limit, and `--foreground-budget SECONDS` accepts only `4`.
The driver reserves the final 400 ms of every call or phase for releasing synthetic input and restoring the desktop, and the runner never uses a process-level kill timeout that could bypass that cleanup.
The palette and Find batch clicks and commits a rendered block, exercises Find controls and text, opens the palette with double Shift, uses real hover and keyboard selection, closes through the backdrop, and exercises font shortcuts.
Its strict aggregate requires both phase plans and budgets, exactly two activations, two successful focus and pointer restores, reliable interference monitoring, the unchanged fixture, one committed marker, the expected Find transition, and the final font state.
The table batch starts from the reading-state table at a deterministic scroll offset, locates controls by exact accessibility identifiers, and uses real CGEvent hover, click, text, Tab, toolbar, and Escape input.
It checks the exact session source, local mutation counts, unchanged fixture files, semantic element frames, and the final closed-grid diagnostic state after restoration.
The structured-editor batch starts from reading-state quote and list blocks, uses exact accessibility identifiers, and exercises continuation, Tab, Shift+Tab, bold insertion, Escape commits, undo, and redo.
It checks the exact lossless session source and block model, unchanged fixture files, local history mutation counts, semantic element frames, and the final closed-editor diagnostic state after restoration.
The editor-boundaries batch enters exact reading-state blocks and exercises Down and Up boundary movement, italic and inline-code shortcuts, Backspace merging at the start of a block, and Escape commit.
It checks the exact merged source, shifted block model, mutation and parse counts, unchanged fixture files, semantic element frames, and the final closed-editor state.
The table-navigation batch enters the passive table body, verifies exact focused accessibility identifiers after Tab, Shift+Tab, Return, and repeated Tab traversal, creates one row from the original last cell, and commits with Escape.
It checks the full focus sequence, exact serialized source, mutation and parse counts, unchanged fixture files, and the final closed-grid state.
The Find options batch creates controlled text, verifies the query field focus, and toggles case-sensitive and whole-word matching through exact accessibility identifiers before checking the final result count and flags.
The Find regex replacement batch creates controlled text, enables a capture-group query, replaces the current match, replaces all remaining matches with a second template, and checks the exact resulting source and diagnostic state.
The preview-content batch launches the default state at scroll offset 1600, enters pure preview with `Command+Shift+P`, clicks the exact task checkbox, hovers the Bash code card, clicks its exact copy button, verifies the full copied string, and returns to editing with the shortcut.
Its foreground plan is conservatively estimated at 2000 ms inside the fixed 4-second budget.
The preview-footnotes batch launches the default state at scroll offset 3000, enters pure preview, moves to and physically clicks the exact first footnote reference, follows its definition, clicks the native return button, and returns to editing with the shortcut.
Its foreground plan is conservatively estimated at 2760 ms inside the fixed 4-second budget.
The outline-navigation batch launches the default state at scroll offset 650, targets heading 12 by its exact accessibility identifier, expands the rail through a real hover, and physically clicks that heading.
It captures the 300 ms ease-out jump in flight and the 900 ms amber wash at its peak, while fading, and after it clears, then verifies the exact clean source, structured block model, active heading, and settled scroll range.
Its foreground plan is conservatively estimated at 3210 ms inside the fixed 4-second budget.
The sidebar-filter-navigation batch targets the filter and result surfaces by exact accessibility identifiers, checks name, relative-path, and empty-result filtering, uses Down, Up, and Return to open README and return to the fixture, and clears the filter while retaining focus.
It verifies the exact two-tab session, active fixture, clean lossless sources, unchanged four-file workspace, default 216 pt sidebar, expanded `docs`, and closed overlays.
Its foreground plan is conservatively estimated at 3150 ms inside the fixed 4-second budget.
The sidebar-layout-controls batch targets the `docs` folder and resize handle by exact accessibility identifiers, collapses and expands the folder, drags the handle to the 176 pt clamp, uses a fixed-window-coordinate drag from that boundary to the 440 pt clamp, and toggles the entire sidebar off and on.
The `collapse-minimum` and `maximum-toggle` phases are conservatively estimated at 1450 ms and 1690 ms respectively, and each has an independent fixed 4-second budget with a final 400 ms cleanup reserve.
The runner verifies every drag's routing readiness and dual delivery receipts, restores the desktop, then waits for debounced session, diagnostic, and pointer-trace state before producing the phase's immutable `resize-state.json` snapshots.
The strictly flattened aggregate requires exactly two activation requests, both phase-level focus and pointer restores, persisted and diagnostic widths of 176 pt then 440 pt, matching latest resize trace segments, a 760 pt sidebar anchor height, a visible final sidebar, expanded `docs`, an exact clean fixture, an unchanged workspace, and closed overlays.
The tab and session suite first proves that switching tabs commits a draft while preserving its exact dirty source and selection, then exercises guarded close and reopen with both right-neighbor and left-neighbor selection.
After its first four foreground phases, the runner moves the live session artifact aside, requests normal Cocoa termination through `NSRunningApplication.terminate()`, and requires application shutdown to recreate the exact expected session JSON.
It relaunches the same isolated profile offscreen with `--visual-test-restore-session` and no input while a passive frontmost-process observer proves that the restored Debug app did not take focus.
The relaunch verifier requires exact session equality and checks dirty sources, tab order, the non-first active tab, restored font size, sidebar width and visibility, folder expansion, each tab's scroll position, and binding of the fixture workspace row to its original tab without duplication.
The fifth foreground phase exposes the restored sidebar, expands the persisted collapsed folder, activates the exact workspace row, and checks the restored tab ordering and selection through Accessibility frames.
The runner then performs a second normal Cocoa termination and requires a second exact session flush.
Before posting any batch input, the driver snapshots every item, declared type, and raw value on the general pasteboard; after the exact string assertion it restores that snapshot byte for byte and fails if the restored snapshot differs.
The plans, fixed-budget validation, harness checks, and corresponding model, AX, or strict synthetic-fixture tests for these nine newer batches pass offline.
The pasteboard implementation also passes a named-pasteboard self-test for multi-item, multi-type, and empty pasteboards without touching the user's general pasteboard.
Console lock state is sampled by each run's preflight and is not a persistent result.
The most recent read-only preflight reported `sessionLocked=false`, but no current-source-tree matching real-app action pass is claimed here.
On uninterrupted completion, the driver restores the previous focus and pointer before returning.
If the listen-only monitor detects user input, the batch aborts immediately, preserves the user's newer pointer location, and restores prior focus only if the target still owns the foreground.
Screenshot color normalization, image comparisons, OCR, and structured diagnostic verification happen only after that restoration and do not post more input.
The foreground report records the selected `foregroundBatchName`, duration, budget, target activation request count, actions, semantic element frames, interference, deadline, and focus and pointer restoration.
Foreground evidence sets `coverage.visualCoverageApplicable=false` and `coverage.requestedPairsComplete=false` instead of treating an empty visual matrix as complete.
Its separate `interactionCoverage` records planned and completed action counts, one-shot activation, interference, deadline, and focus and pointer restoration.

### Legacy extended tiers

Run the legacy keyboard matrix explicitly with:

```bash
./scripts/e2e/run-real-app-e2e.sh --keyboard-only
```

Keyboard-only mode posts keyboard events directly to the isolated Debug process at all three sizes and takes foreground focus repeatedly.
It records sidebar hide and show, preview toggle, palette interaction, find navigation, lifecycle paths, and deterministic scroll evidence.
It does not claim pointer, source-editing, table-editing, outline-hover, replace, system panel, or drag-and-drop coverage.

Run the former full keyboard and pointer matrix only with:

```bash
./scripts/e2e/run-real-app-e2e.sh --extended-full-pointer
```

The extended tier preserves the previous three-size pointer, keyboard, source, table, find-and-replace, and session assertions for deliberate unattended runs.
It can take focus and move the system pointer many times, so it is never selected by default and should not run while the Mac is in active use.
It does not yet assert every table control, file save, relaunch, or session field.

Use `--output PATH` to select a marked evidence directory.
Use `--keep-last-app` to keep only the final isolated Debug instance running after a successful explicit interaction matrix.
Passive evidence rejects that option because its lifecycle observer must cover target-process exit.
The runner refuses to delete a nonempty output directory unless its harness marker is present.

The runner caches the compiled `RealAppDriver` under `build/e2e/real-app-driver-cache`, outside the selected evidence output.
The cache key binds the driver source hash, Swift compiler path and version, macOS SDK path and version, host architecture, relevant toolchain environment, and the complete optimization and framework argument list.
Every cache hit verifies the executable bit, metadata, and binary SHA-256 before copying the driver into the current output, and the evidence hashes that copied binary again.
Invalid or damaged entries are recompiled, while concurrent writers publish complete temporary files with atomic moves.
An output path that would contain the shared cache is rejected so evidence cleanup cannot delete the cache.

Warm only this compile cache with:

```bash
./scripts/e2e/run-real-app-e2e.sh --prepare-driver-only
```

This mode does not inspect or clean `--output`, perform permission preflight, build or launch Markdown Viewer, or access the GUI.

## Evidence semantics

Successful runs write schema-version-2 `evidence.json` plus one passed `manifest.json` per size.
The root evidence records `interactionTier`, `foregroundBatchName`, a tier-specific `mode`, the dynamically requested size and visual-state lists, `coverage`, `interactionCoverage`, and explicit input, focus, and pointer claims.
It also records `runScope`, `strictVisualAcceptanceEligible`, and exact required, requested, and resolved matrix coverage.
Passive evidence uses mode `passive-window-observation`, records all interaction claims as false, and cannot contain foreground or pointer action reports.
Its per-size `passiveLifecycleAssertions` and root `passiveLifecycleAssertions` contain one full frontmost observer report for every pair actually executed, plus clearly scoped endpoint desktop observations.
For `tab-session-lifecycle`, the root foreground evidence also aggregates the passive lifecycle assertions that bracket the first normal termination, the no-input offscreen relaunch, and the second normal termination, alongside `foregroundPhases` and `sessionRelaunch`.
Only the unfiltered strict-acceptance matrix contains all 21 lifecycle reports; a probe contains exactly its requested Cartesian product.
The singular per-size `passiveLifecycleAssertion` remains the `default` baseline entry for compatibility and is `null` for a probe size when that probe omits `default`.
Each per-size `visualStateLaunches` entry records the independently requested and resolved state, profile, PID, scroll, diagnostic hash, and locked native main-window identity.
Every screenshot record carries the same exact window identity as re-observed immediately before capture and schema-version-2 screenshot-bound visual evidence for the strict comparator.
The lifecycle observer, rather than the two endpoints, proves that the Debug app never became frontmost.
Bounded foreground evidence uses mode `bounded-foreground-smoke`, records `foregroundBatchName`, and includes the complete `foregroundReport`, raw in-batch checkpoints, and normalized post-restoration screenshots.
The legacy modes are named `legacy-focus-taking-keyboard` and `legacy-extended-full-pointer` so their interference characteristics are not obscured.
The evidence binds the run to the authoritative HTML, fixture, E2E script, driver source, compiled driver, app binary, Git commit, and a deterministic hash of all tracked and untracked non-ignored worktree files.
It also records the pinned visual acceptance contract SHA-256 so downstream comparison cannot apply a different anchor set or tolerance policy.
It also records whether that exact source tree was dirty and fails if the source tree changes while evidence is being recorded.
The remaining evidence includes preflight permissions, window ownership and bounds, screenshot hashes and backing scales, action records, sidebar samples, before-and-after image comparisons, labeled Debug diagnostic snapshots, and exact session-source assertions.
Captured PNGs are converted from their source display profile to the system sRGB profile before hashing and comparison.

An isolated Debug visual profile atomically maintains its latest diagnostic state at `Profile/Diagnostics/state.json`.
The versioned snapshot includes nullable `blockID` and `blockType`; a nullable UTF-16 `selection` with `location` and `length`; a nullable `activeTableCell` with `row` and `column`; and the current `document`, `mode`, `dirty`, `scrollY`, `sessionPath`, parse counts, render counts, and `updatedAt` value.
The `mode` value is `edit` or `preview` for rendered Markdown, `source` for a plain-source document, and `empty` when no document is open.
The `find` object records `query`, `display`, `matchCount`, `currentIndex`, `invalidRegex`, `replaceExpanded`, `caseSensitive`, `wholeWord`, and `regex`, while `outline` records `headingCount` and `activeIndex`.
`renderedBlockUpdateCount` totals block renderer view-update callbacks for the current app process, `activeBlockRenderUpdateCount` reports the current active block's cumulative total or zero when no block is active, and `renderedBlockUpdates` maps every observed block UUID to its cumulative total.
The counters accumulate for the current app process within that isolated profile session and reset when a new process starts.
These counters are direct renderer-update observations, not WindowServer paint, compositing, or changed-pixel counts.
The runner waits for each requested state, validates the exact top-level schema, expected document, isolated session path, positive total renderer count, nonempty per-block map, and any requested mode or find query.
It then wraps the snapshot with its action label in `diagnostic-<label>.json` and includes that object in the per-size manifest's `diagnostics` array.

The harness image comparisons use a per-channel threshold of 8 and assert only that selected before-and-after states changed by a minimum ratio.
They are transition guards, not comparisons with `ui/Markdown Viewer.dc.html`, and they are not pixel-fidelity pass criteria.
An action report proves only that an event was posted to the target PID, while state correctness must come from the matching screenshot or direct assertion.
For a completed foreground smoke, raw screenshots are captured inside the bounded batch and then normalized and verified after the driver reports focus and pointer restoration.
An interrupted batch keeps its report as failure evidence and does not proceed to those success assertions.
Hiding the HUD with `--visual-test-hide-hud` changes only screenshot pixels and does not disable snapshot generation or harness validation.

Evidence paths under `build/e2e/` are local build artifacts and must be regenerated after relevant source, harness, OS, display, or permission changes.
The exact verified, blocked, and uncovered size matrix is maintained in `SPEC-ALIGNMENT.md`.

## Infrastructure checks

The infrastructure check typechecks the driver, validates the compile-cache warm-up and reuse path, validates every deterministic visual launch state, rejects on-screen passive windows and invalid launcher states, validates preflight and desktop-state schemas, exercises a short read-only frontmost observer handshake, exercises passive sidebar argument handling, validates foreground plans and budgets, and checks bounded error handling without launching Markdown Viewer.

```bash
bash Tests/E2E/RealAppHarnessTests.sh
```

This test script requires `rg` for its error-message assertions.

The incremental Debug build regression uses a temporary fake repository to verify content-addressed reuse, invalidation, locking, and atomic publication without launching the app:

```bash
bash Tests/E2E/BuildDebugIncrementalTests.sh
```

It also requires `rg`.

The launch identity regression opens two isolated Debug instances with `open -g`, verifies that unique launch tokens select distinct PIDs, and confirms that a stale PID file cannot terminate the wrong instance:

```bash
bash Tests/E2E/RunDebugLaunchIdentityTests.sh
```

It also requires `rg`.
