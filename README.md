# Markdown Viewer

Markdown Viewer is a native macOS editor for local Markdown and MDX files.
It renders the document as a quiet reading surface, then turns only the block you click into editable Markdown source.
Tables use a native grid editor, and a pure preview mode presents the same document without block-source or table-grid editing affordances.

## Features

- `.md`, `.markdown`, and `.mdx` files use a lossless block-based editing model with stable block identities.
- Headings, inline formatting, code, quotes, nested lists, tasks, tables, links, images, horizontal rules, and footnotes render natively.
- Clicking a rendered block edits that block in place, while clicking a table cell opens the table grid editor.
- Pure preview mode is available with `Command+Shift+P` and does not create a split pane.
- Code copying, task toggling, links, and footnote navigation remain available in pure preview.
- Find and replace searches visible text instantly and supports case sensitivity, whole words, regular expressions, capture groups, and replace-all.
- The file sidebar supports folders, recursive filtering, keyboard selection, resizing, and collapse.
- The content outline sits along the left edge of the document canvas and follows the current heading while scrolling.
- Tabs preserve unsaved edits, support guarded close and reopen, and restore the previous session and scroll positions.
- Common text and source formats such as YAML, JSON, TOML, Swift, shell, and plain text open in an editable source view.
- The command palette, macOS menu commands, toasts, tooltips, code copying, link hover feedback, and task toggles keep interaction lightweight.

## Requirements

- macOS 13 or newer is required.
- Xcode Command Line Tools or full Xcode is required.
- Python 3 is required by the E2E evidence assembler, visual tools, and Release smoke.
- Pillow is required only by visual comparison and its tool checks, and can be installed with `python3 -m pip install Pillow`.
- `rg` from ripgrep is required by the three E2E infrastructure checks and `Tests/Visual/VisualToolTests.sh`, but not by the packaged application or the real-app E2E runner itself.
- Authoritative reference capture always uses `openssl` for SRI verification and uses `curl` only when a pinned browser-runtime file is absent or invalid in the local cache.
- Real-app screenshots require macOS Screen Recording permission.
- The default passive E2E tier does not require input or Accessibility permission and does not take focus or move the pointer.
- Explicit keyboard E2E requires permission to post input events through Input Monitoring or Accessibility and takes focus.
- Explicit foreground smoke requires Accessibility for targeting, Input Monitoring listen-event access for interference detection, and an unlocked macOS console session.
- Explicit extended full-pointer E2E requires Accessibility and an unlocked console session, but does not use the foreground smoke's listen-only interference monitor.

## Release build

Build the USER application with:

```bash
./scripts/build.sh
```

The application is written to `dist/MarkdownViewer.app` and is ad hoc signed.
The build injects the marketing version from `VERSION`, a numeric `CFBundleVersion` from the Git commit count, and the short Git commit into `MVGitCommit`.

Create the application and a zip archive with:

```bash
./scripts/build.sh --zip
```

Launch the application with:

```bash
open dist/MarkdownViewer.app
```

Release builds ignore Debug diagnostics and visual-test flags.

## Debug and isolated visual profile

Build the true Debug bundle with:

```bash
./scripts/build-debug.sh
```

The Debug application is written to `dist/debug/MarkdownViewer.app` with bundle identifier `local.codex.markdownviewer.debug`.
`ui/格式示例.md` is the sole source fixture, and the Debug application contains a verified byte-for-byte copy while the Release bundle does not contain it.

Repeated test setup can reuse a verified, current Debug bundle explicitly:

```bash
./scripts/build-debug.sh --if-needed
```

The reuse check validates the bundle structure and signature, fixture and icon contents, build identity in `Info.plist`, and an exact content-addressed manifest stored inside the signed application.
The manifest binds source and resource paths and contents, package metadata, the build script, toolchain and SDK identity, target architecture, relevant build environment, and fixed build parameters.
Concurrent invocations share a lock and publish only a completely assembled and verified staging bundle.
The default command still performs a full build and assembly every time.

The recommended launcher builds and opens the real Debug `.app` with an isolated visual-test profile:

```bash
./scripts/run-debug.sh --reset
```

The profile contains its own Application Support data, `session.json`, temporary workspace, PID marker, and crash-only log directory.
`--reset` stops only the marked app for that profile and then removes only the selected marked profile, so it does not touch the normal USER session.

Use a clean screenshot launch with:

```bash
./scripts/run-debug.sh --reset --visual-test-hide-hud
```

The launcher accepts these visual controls:

- `--visual-test-root PATH` selects the disposable profile root.
- `--visual-test-size WIDTHxHEIGHT` fixes the logical window size and requires at least `860x560`.
- `--visual-test-document NAME` selects a bundled Debug fixture by filename.
- `--visual-test-scroll Y` sets a nonnegative initial scroll offset.
- `--visual-test-state STATE` selects one of the seven deterministic Debug launch-state presets used by the passive matrix.
- `--visual-test-hide-hud` hides the diagnostic HUD without changing layout pixels.
- `--background` launches without taking focus or moving the system pointer and is mandatory for every E2E tier.
- `--show-hud` keeps the diagnostic HUD visible.

Run `./scripts/run-debug.sh --help` for the current option contract.
The launcher supplies `--debug` and `--visual-test` itself, and those arguments are honored only by a Debug build.

### Persistent Debug diagnostics

The Debug HUD is a supported diagnostic surface and is shown by default when `scripts/run-debug.sh` launches the visual profile.
It reports the current document, active block UUID and block type, edit or preview mode, source selection, active table row and column, dirty state, find status, outline heading count and active index, vertical scroll offset, session path, parse count, local mutation count, and rendered block-view update counts.
The isolated Debug visual profile also atomically writes its latest structured snapshot to `Profile/Diagnostics/state.json`, where `Profile` is the root selected with `--visual-test-root`.
The versioned JSON schema includes nullable `blockID` and `blockType`; a nullable UTF-16 `selection` with `location` and `length`; a nullable `activeTableCell` with `row` and `column`; and the current `document`, `mode`, `dirty`, `scrollY`, `sessionPath`, parse counts, render counts, and `updatedAt` value.
The `find` object records `query`, `display`, `matchCount`, `currentIndex`, `invalidRegex`, `replaceExpanded`, `caseSensitive`, `wholeWord`, and `regex`, while `outline` records `headingCount` and `activeIndex`.
`renderedBlockUpdateCount` is the process-lifetime total of block renderer view-update callbacks, `activeBlockRenderUpdateCount` is the total for the currently active block or zero when no block is active, and `renderedBlockUpdates` contains the cumulative count for each observed block UUID.
The counters accumulate for the current app process within the isolated profile session and reset when a new process starts.
These counters provide direct renderer-update evidence for the current isolated app process, but they do not count WindowServer paints, compositing passes, or pixels redrawn on screen.
The `local` field counts local document mutations and is separate from both renderer updates and screen painting.
The HUD can be collapsed, and clicking its expanded body copies its available diagnostic text to the pasteboard.
`--visual-test-hide-hud` removes the HUD from screenshot pixels without disabling the underlying Debug instrumentation.
The real-app E2E harness waits for expected snapshot state, validates the exact top-level schema, fixture or requested document, isolated session path, and nonempty positive renderer counters, then copies each labeled snapshot into the per-size evidence manifest.
Debug launches without an isolated visual profile and all Release launches do not write this snapshot file.

Normal logging stays in a bounded in-memory ring buffer.
Only a crash attempts to flush recent entries under the active profile's `Logs/crash/` directory, so the profile does not contain a continuously persisted application log.

## Tests

Run the complete Swift test suite with:

```bash
./scripts/test.sh
```

The suite uses Apple's Swift Testing framework.
The wrapper derives framework search paths from `xcode-select -p`, so it works with both a Command Line Tools-only setup and full Xcode without hardcoded developer paths.

Additional SwiftPM arguments pass through to the underlying test command:

```bash
./scripts/test.sh --filter MarkdownDocumentTests
```

Coverage includes the lossless block parser, local mutations, editing commands, tables, passive rendering, source highlighting, visible-text search and replacement, document lifecycle, session migration and recovery, launch gating, the exact Debug fixture, and large-document performance checks.
Use the current command exit status as the test result instead of relying on a recorded test count in documentation.

Run the E2E infrastructure regressions with:

```bash
bash Tests/E2E/RealAppHarnessTests.sh
bash Tests/E2E/BuildDebugIncrementalTests.sh
bash Tests/E2E/RunDebugLaunchIdentityTests.sh
```

The first two are non-GUI infrastructure checks.
The launch-identity regression opens isolated background Debug instances and verifies that profile tokens resolve and terminate only their own processes.

## Real-app E2E

Run the default passive real-app harness with:

```bash
./scripts/e2e/run-real-app-e2e.sh
```

The harness compiles a standalone AppKit driver, builds and launches isolated Debug applications with `--background`, inspects window state, captures sRGB-normalized screenshots, and records labeled structured Debug snapshots.
The passive default captures `default`, `palette`, `find`, `preview`, `sidebar-hidden`, `source-editor`, and `table-editor` at `1180x760`, `860x560`, and `1440x900` without activating the app, posting input, or inspecting through focus-changing Accessibility calls.
Those seven states are deterministic Debug launch-state presets for settled rendering and geometry, not evidence that a user reached them by clicking, typing, hovering, or dragging.
Each of the 21 size and state pairs uses an independent profile and PID.
Before each launch the harness starts a read-only observer that combines activation notifications with 25 ms frontmost sampling until the Debug app has exited.
It also brackets every process with frontmost-process and pointer snapshots.
The passive run fails closed if its observer exits early, if its own Debug app becomes frontmost, or if the bracketing pointer endpoint changes, including when the user moves the pointer and leaves it at a different location while the run is active.
It writes its root evidence file to `build/e2e/real-app-latest/evidence.json` by default.

For a fast non-interfering development probe, select only the canonical pairs being investigated:

```bash
./scripts/e2e/run-real-app-e2e.sh \
  --probe-sizes 1180x760 \
  --probe-states preview
```

Probe filters accept comma-separated subsets and default to `build/e2e/real-app-probe-latest`.
The runner executes the Cartesian product of the selected sizes and states; omitting one probe option keeps the complete canonical axis for that dimension.
Any explicit `--probe-sizes` or `--probe-states` option marks the run `runScope=development-probe` and `strictVisualAcceptanceEligible=false`, even if its values enumerate the complete 21-pair matrix.
Probes keep the same offscreen lifecycle and no-input guarantees but cannot replace the unfiltered 21-pair run.

Run the short palette and Find interaction batch explicitly with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-smoke
```

This is an alias for `--foreground-batch palette-find`.
It uses only `1180x760` and performs a real block click and commit, Find control clicks and text input, double-Shift palette opening, palette hover and keyboard selection, backdrop close, and font shortcuts.
The suite runs as two independent foreground phases named `block-find` and `palette-keyboard`, conservatively estimated at 2190 ms and 1690 ms.
Each phase has its own 4-second hard limit and final 400 ms cleanup reserve, restores focus and pointer before the next phase, and persists an immutable session and diagnostic snapshot.
The second phase repeats `Command+F` before double Shift so it explicitly re-establishes the Find panel and focus instead of depending on transient window state from the first activation.
The flattened aggregate requires exactly two activation requests, no interference in either phase, two successful desktop restores, the complete action sequence, and the expected intermediate and final persisted states.
Run the independent table batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch table-controls
```

The table batch launches at a deterministic scroll position but does not preset the grid state.
It uses a real hover and click on a reading-state table cell, edits the native field, presses Tab, exercises alignment and row and column controls, and presses Escape to commit.
Run the independent structured-editor batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch editor-structure
```

The structured-editor batch clicks reading-state quote and list blocks, exercises continuation, Tab, Shift+Tab, bold insertion, Escape commits, undo, and redo, then verifies the exact lossless session source and mutation counts.
Run the independent editor-boundaries batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch editor-boundaries
```

The editor-boundaries batch uses exact block targets to exercise Down and Up movement across block boundaries, inline italic and code insertion, Backspace merging at a block start, and Escape commit.
Run the independent table-navigation batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch table-navigation
```

The table-navigation batch enters a reading-state table and checks exact focused cell identities across Tab, Shift+Tab, Return, traversal to the last cell, automatic row creation, and Escape commit.
Run the two independent Find batches with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch find-options
./scripts/e2e/run-real-app-e2e.sh --foreground-batch find-regex-replace
```

The Find options batch verifies query focus together with case-sensitive and whole-word matching against controlled text.
The regex replacement batch verifies a capture-group replacement of the current match followed by replace-all for the remaining matches and checks the exact resulting source.
Run the independent preview-content batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch preview-content
```

The preview-content batch launches at scroll offset 1600, enters pure preview with `Command+Shift+P`, clicks a real task checkbox, hovers the Bash code card, clicks its copy button, checks the exact copied string, restores every original pasteboard item and type, and returns to editing with the same shortcut.
Its conservative foreground estimate is 2.00 seconds inside the fixed 4-second budget.
Run the independent preview-footnotes batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch preview-footnotes
```

The preview-footnotes batch launches at scroll offset 3000, enters pure preview, hovers and physically clicks the exact first footnote reference, follows its definition, clicks the native return button, and returns to editing.
Its conservative foreground estimate is 2.76 seconds inside the fixed 4-second budget.
Run the independent outline-navigation batch with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch outline-navigation
```

The outline-navigation batch launches at scroll offset 650, expands the left outline through a real hover, physically clicks heading 12, captures the 300 ms jump in flight, and captures the 900 ms amber wash at its peak, while fading, and after it clears.
Its conservative foreground estimate is 3.21 seconds inside the fixed 4-second budget.
Run the two independent sidebar batches with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch sidebar-filter-navigation
./scripts/e2e/run-real-app-e2e.sh --foreground-batch sidebar-layout-controls
```

The filter-navigation batch focuses the exact sidebar filter, verifies name, relative-path, and empty-result matches, opens README and returns to the fixture with arrow keys and Return, then clears the query.
Its conservative foreground estimate is 3.15 seconds inside the fixed 4-second budget.
The layout-controls batch collapses and expands `docs`, drags the exact resize handle to the 176 pt clamp, uses a fixed-window-coordinate drag from that verified boundary to the 440 pt clamp, and hides and restores the whole sidebar with `Command+\`.
It runs as `collapse-minimum` and `maximum-toggle`, conservatively estimated at 1450 ms and 1690 ms respectively, with a separate fixed 4-second budget and final 400 ms cleanup reserve for each phase.
After each desktop restore, the runner waits for debounced session and diagnostic persistence and verifies the sidebar frame plus the latest `sidebar-resize-began/changed/ended` trace segment.
It then emits one flattened aggregate requiring exactly two activation requests, two successful phase restores, and both embedded resize-state proofs.
Run the tab and session lifecycle suite with:

```bash
./scripts/e2e/run-real-app-e2e.sh --foreground-batch tab-session-lifecycle
```

The runner exposes thirteen named bounded foreground suites, including the `palette-find` name behind `--foreground-smoke` and the `tab-session-lifecycle` suite.
`palette-find` uses two independently bounded foreground phases, `block-find` and `palette-keyboard`.
`sidebar-layout-controls` uses two independently bounded foreground phases.
The tab and session suite uses five independently bounded foreground phases named `switch-commit`, `close-right-reopen`, `close-left-seed`, `seed-layout`, and `relaunch-scroll-check`.
Their conservative foreground estimates are 1640 ms, 2690 ms, 2000 ms, 1660 ms, and 1880 ms respectively.
Every single-call suite and every phase of a multi-phase suite has its own fixed 4-second hard limit, and `--foreground-budget SECONDS` accepts only `4`.
The driver reserves the final 400 ms of every call or phase for input release and desktop restoration instead of using an unsafe process-level kill timeout.
On uninterrupted completion, the driver restores the previous focus and pointer before offline screenshot normalization and verification begin.
If it detects user input, it aborts immediately, does not overwrite the user's newer pointer location, and restores prior focus only while the target still owns the foreground.
The plans and harness checks for `editor-boundaries`, `table-navigation`, `find-options`, `find-regex-replace`, `preview-content`, `preview-footnotes`, `outline-navigation`, `sidebar-filter-navigation`, and `sidebar-layout-controls` pass offline, together with their corresponding model, AX, or strict synthetic-fixture coverage.
The preview-content pasteboard path also passes its named-pasteboard multi-item, multi-type, and empty-state round-trip self-test.
After the first four tab and session phases, the runner requests normal Cocoa termination and proves that application shutdown recreated the exact expected session JSON.
It then relaunches the restored Debug profile offscreen without input under a passive frontmost-process observer before running the fifth bounded phase.
The lifecycle verifier asserts the exact session and dirty sources, tab order, non-first active tab, font size, sidebar width and visibility, folder expansion, each tab's scroll position, and workspace-row binding without accepting duplicate tabs.
It performs a second normal Cocoa termination after the restored-state checks and again proves the exact session flush.
The root foreground evidence aggregates all five phase reports, the session relaunch proof, and the passive lifecycle assertions that bracket termination and the no-input offscreen relaunch.
Console lock state is a fact sampled by each run's preflight rather than a persistent harness status.
The most recent read-only preflight reported `sessionLocked=false`, but current-source-tree matching real-app action evidence is still pending and this document does not claim that the foreground suites have passed.

The legacy keyboard-only matrix remains available explicitly:

```bash
./scripts/e2e/run-real-app-e2e.sh --keyboard-only
```

Keyboard-only mode takes focus repeatedly and covers sidebar, preview, palette, find, lifecycle, and find-driven scroll paths at all three sizes.
It does not claim pointer, source-editing, table-editing, or outline-hover behavior.

The former full keyboard and pointer matrix is also legacy and must be requested explicitly:

```bash
./scripts/e2e/run-real-app-e2e.sh --extended-full-pointer
```

Extended full-pointer can take focus and move the system pointer many times.
Use it only for a deliberate unattended run.
`--static-only` remains a deprecated alias for the default passive tier.

For an explicit interaction tier, keep only the final isolated Debug instance running for manual inspection with:

```bash
./scripts/e2e/run-real-app-e2e.sh --keep-last-app
```

Passive evidence requires observing the target through process exit, so it rejects `--keep-last-app`.

Use `--output PATH` to select another marked evidence directory.
The harness refuses to delete a nonempty output directory unless it carries its own safety marker.
Its before-and-after `changedPixelRatio` assertions are minimum-change guards for expected state transitions, not comparisons with the authoritative prototype and not visual acceptance gates.
See `scripts/e2e/README.md` and the current status matrix in `SPEC-ALIGNMENT.md` for the exact covered and uncovered flows.

## Visual reference and diff

The visual tools are standalone WebKit and image-comparison utilities.
WebKit is not linked into the product target and is not a Swift package dependency.

Capture the authoritative prototype states with:

```bash
./scripts/visual/capture-reference.sh
```

The default reference capture, passive E2E run, and real-app comparison all use the same seven mapped states at `1180x760`, `860x560`, and `1440x900`, for 21 pairs.

Capture the full supported reference state set with:

```bash
./scripts/visual/capture-reference.sh \
  --states default,palette,find,replace,preview,sidebar-hidden,source-editor,table-editor
```

The capture verifies the SHA-256 of the authoritative HTML, checks its React URL and SRI pins against `ui/support.js`, verifies downloaded or cached runtime bytes, uses a nonpersistent WebKit data store, and emits normalized 2x PNGs plus `build/visual-reference/manifest.json`.
Pinned browser assets are cached only under `build/visual-tools/cache`, and the first uncached run may need network access.

After producing real-app E2E screenshots, generate full-frame comparisons with:

```bash
./scripts/visual/compare-real-app.sh
```

The results are written under `build/visual-diff/real-app-latest/` and include metrics, 50 percent overlays, and difference heatmaps without masks or ignored regions.
Every requested size and state pair must exist in both manifests with matching pixel dimensions, or the command fails without emitting a completed manifest.
The reference-only `replace` state has no real-app mapping.
The strict gate validates screenshot-bound state assertions, all required non-text geometry anchors with at most 1 px error at `1180x760` and at most 2 px error at `860x560` and `1440x900`, and the committed full-frame pixel contract.
Exit code 0 means all requested pairs and top-level strict evidence passed, while exit code 5 means a completed failed acceptance manifest was written.
The pixel threshold is pinned to 8, and acceptance requires aggregate ratios, MAE, RMS, connected components, horizontal and vertical runs, and local tile density to remain within fixed limits.
The evaluator recomputes these values from the screenshot-hash-bound PNGs, so modified metrics cannot bypass the gate.
The workflow still emits the app image, overlay, heatmap, and metrics for diagnosis, and it never masks or ignores ordinary UI pixels.
A scoped `--sizes` or `--states` comparison never makes development-probe evidence eligible for final acceptance.
A passing strict visual matrix proves the settled state, geometry, and pixel contract only.
It does not prove that the states were reached through real user input or satisfy the product's complete interaction DoD.

Run the standalone visual tooling checks with:

```bash
./Tests/Visual/VisualToolTests.sh
```

More details are in `scripts/visual/README.md`.

## Release USER smoke

Run the Release isolation smoke with:

```bash
./scripts/release-smoke.sh
```

The smoke builds the Release application, verifies that prototype and Debug fixture resources are absent, copies the app under a temporary bundle identity, launches it with deliberately forbidden Debug flags, and verifies an isolated blank first-run session.
It never attaches to or terminates an already running USER application.
Set `MV_KEEP_RELEASE_SMOKE=1` only when the temporary profile must be retained for diagnosis.

## Architecture

The SwiftPM package contains one macOS executable target and one Swift Testing target.
Production rendering and editing are native SwiftUI and AppKit, with no embedded web view.

```text
Sources/MarkdownViewer/
  App/        Application entry point, launch gating, Debug fixture loading, versioning, window setup, in-memory logging, and crash-only flush.
  Documents/  File formats, tab and file models, the lossless block document, editing commands, lifecycle, and session persistence.
  Editor/     Block store, rendered block surface, block source editor, table grid editor, scrolling, and passive formatting.
  Find/       Visible-text projection, block search and replacement, find state, and the find/replace panel.
  Outline/    Heading models and the left content outline rail.
  Palette/    Command and document palette plus its transparent host window.
  Shell/      Window composition, tabs, toolbar, status area, drag and drop, and top-level overlays.
  Sidebar/    Recursive file browser, filtering, keyboard navigation, and resizing.
  Styling/    The AppKit Markdown styling and layout compatibility layer retained for characterization and regression coverage.
  UI/         Shared design tokens, icons, toasts, and tooltips.
```

Markdown tabs persist a `MarkdownDocument` whose blocks own exact source slices and stable UUIDs.
Each tab has a `BlockEditorStore`, and edits replace only the active block or table before the manager reconciles a snapshot at lifecycle boundaries.
Plain-source documents continue through the AppKit source editor and do not build a Markdown outline.

## UI reference

The authoritative interface is [`ui/Markdown Viewer.dc.html`](ui/Markdown%20Viewer.dc.html).
See [`SPEC-ALIGNMENT.md`](SPEC-ALIGNMENT.md) for the current implementation and verification matrix and [`ui/README.md`](ui/README.md) for the design-file precedence rules.
