# Visual reference and acceptance tools

These tools run outside the MarkdownViewer product target and do not add WebKit to the application or Swift package dependencies.
The reference runner uses WebKit only to render and measure the authoritative HTML.
The comparison workflow uses real-app PNGs plus machine-captured state and geometry evidence.

## Requirements

Reference capture requires Xcode Command Line Tools or full Xcode, Python 3, and `openssl` for every SRI verification.
It requires `curl` and network access only when a pinned browser-runtime file is absent or invalid in the local cache.
The first uncached capture may need network access to download the pinned React UMD files.
Comparison requires Python 3 and Pillow but not `rg`.
`Tests/Visual/VisualToolTests.sh` additionally requires `rg`.

```bash
python3 -m pip install Pillow
```

## Capture the authoritative reference

Run the default reference capture with:

```bash
./scripts/visual/capture-reference.sh
```

The default capture writes `default`, `palette`, `find`, `preview`, `sidebar-hidden`, `source-editor`, and `table-editor` at logical viewports `1180x760`, `860x560`, and `1440x900`.
This is the complete set of states that currently has a real-app screenshot mapping.
The runner verifies the exact SHA-256 of `ui/Markdown Viewer.dc.html` before compiling.
It also parses the React and ReactDOM URL and SRI constants from `ui/support.js`, requires them to match the capture pins, and verifies downloaded or cached runtime bytes against the matching SHA-384 SRI values.
The runner clears prototype web storage in a nonpersistent WebKit data store and writes normalized 2x PNGs plus `build/visual-reference/manifest.json`.

Each snapshot record contains schema-v2 `visualEvidence` captured from the settled authoritative DOM.
The evidence records required visibility assertions, required non-text geometry rectangles in `viewportPixels`, and the exact PNG SHA-256.
Capture fails if a required state assertion or geometry anchor cannot be measured.

Capture the reference-only replace state with:

```bash
./scripts/visual/capture-reference.sh \
  --sizes 1180x760 \
  --states replace
```

Capture every supported reference state with:

```bash
./scripts/visual/capture-reference.sh \
  --states default,palette,find,replace,preview,sidebar-hidden,source-editor,table-editor
```

The reference-only `replace` state is measured by the contract but has no current real-app screenshot mapping.
Pinned browser runtime files are cached only under `build/visual-tools/cache` after verification.

## Real-app evidence contract

`scripts/visual/acceptance-contract.json` is the committed schema-v2 acceptance contract.
It fixes the state mapping, required visibility assertions, required non-text geometry anchors, coordinate space, geometry tolerance, pixel analysis algorithm, and pixel acceptance limits.
The normal comparison command has no option that can relax an anchor set, geometry tolerance, changed-pixel threshold, or pixel limit.
The reference manifest and real-app evidence must both record the pinned contract SHA-256, and the evaluator rejects alternate contract bytes.

Every mapped real-app screenshot record in `evidence.json` must contain `visualEvidence` with this shape:

```json
{
  "schemaVersion": 2,
  "kind": "machine-captured-visual-evidence",
  "screenshotSHA256": "<the exact screenshot hash>",
  "stateEvaluation": {
    "evaluated": true,
    "status": "passed",
    "expectedState": "baseline",
    "observedState": "baseline",
    "source": "combined-machine-probes",
    "assertions": [
      {
        "name": "document-visible",
        "evaluated": true,
        "passed": true
      }
    ]
  },
  "geometryEvaluation": {
    "evaluated": true,
    "status": "passed",
    "coordinateSpace": "viewportPixels",
    "anchors": [
      {
        "name": "sidebar-frame",
        "evaluated": true,
        "source": "image-analysis",
        "rect": {
          "x": 0,
          "y": 0,
          "width": 216,
          "height": 760
        }
      }
    ]
  }
}
```

The example is intentionally incomplete because the required assertions and anchors vary by state.
The committed contract is authoritative for each complete list.
The gate also requires matching authoritative HTML hashes, complete reference coverage, passed per-size E2E evidence, and tier-appropriate machine preflight and lifecycle evidence.
The primary eligible tier is a complete passive run that records all 21 required size and state pairs in distinct isolated App processes.
Each passive launch must select one layer-zero main window, and every window belonging to that process must remain offscreen both after state settlement and immediately before capture.
The process must never become frontmost, must exit before its lifecycle observer stops, and must leave the pointer endpoint unchanged.
The legacy `extended-full-pointer` tier remains eligible when it records the complete input preflights and full-interaction flags.
Keyboard-only evidence and the bounded foreground smoke remain intentionally ineligible for the strict visual gate.
Accepted app state sources are macOS Accessibility, Debug diagnostics, image analysis, or a recorded combination of those machine probes.
Accepted app geometry sources are macOS Accessibility, image analysis, or a recorded combination of those probes.
Screenshot labels, filenames, manual claims, and a changed-pixel total are not accepted as state or geometry evidence.

The gate independently hashes both PNGs.
It rejects a missing manifest hash, a stale manifest hash, or `visualEvidence` bound to any other screenshot.
The evaluator also recomputes the complete pixel analysis directly from those bound PNGs and rejects modified or fabricated metrics JSON.
Old schema-v1 evidence and schema-v2 evidence without the required fields fail by design and must be recaptured.

## Compare and gate the real application

First produce the complete passive 3-size by 7-state evidence:

```bash
./scripts/e2e/run-real-app-e2e.sh
```

This tier does not activate the App or post keyboard and pointer events.
After the passive run has produced complete machine evidence, run:

```bash
./scripts/visual/compare-real-app.sh
```

Use `--extended-full-pointer` only when the explicit full-interaction tier is required and the current macOS session can safely grant it focus and input control.
The strict visual gate rejects keyboard-only and `--foreground-smoke` evidence even if their directories contain matching screenshot labels.

The default gate evaluates all seven mapped states at all three required sizes for 21 state pairs.
Before generating images, the script requires every requested pair in both manifests, rejects blocked evidence, keeps paths inside their evidence roots, and requires matching pixel dimensions.
An incomplete requested matrix fails without emitting a completed acceptance manifest.

The real-app mappings are `default` to `baseline`, `palette` to `palette-open`, `find` to `find-open`, `preview` to `preview-on`, `sidebar-hidden` to `sidebar-hidden`, `source-editor` to `source-editing`, and `table-editor` to `table-grid`.
Source and table screenshots must be clean captures taken before semantic mutations so they can be paired with independently reset reference states.

Use explicit roots when comparing a named E2E run:

```bash
./scripts/visual/compare-real-app.sh \
  --reference build/visual-reference \
  --app-evidence build/e2e/real-app-latest \
  --output build/visual-diff/real-app-latest
```

Each comparison writes the complete frame, a 50 percent overlay, a heatmap, numeric pixel measurements, state evaluation, anchor deltas, and pair acceptance.
The root `manifest.json` uses schema version 2 and reports `acceptance.status` as `passed` or `failed`.
Exit code 0 means every requested state pair had complete evidence, every required anchor stayed within tolerance, and every aggregate and spatial pixel check passed.
Exit code 5 means the acceptance manifest was written but at least one evidence, state, hash, anchor, or pixel check failed.

A scoped `--sizes` or `--states` run reports only the explicitly requested matrix.
It does not replace the default 21-pair gate for final acceptance.
The app evidence must still come from an unfiltered strict-acceptance run.
Evidence produced with `--probe-sizes` or `--probe-states` is explicitly ineligible and remains rejected even when the comparison itself is scoped to the same pair.
Any explicit probe filter has that effect, even if the filter values enumerate every canonical size and state.

A passing strict visual gate proves settled state assertions, required non-text geometry, and the fixed full-frame pixel contract for the complete mapped matrix.
The passive states are deterministic Debug launch-state presets, so this result does not prove the real clicks, input, hover, drag, mutations, or lifecycle flows required by the complete interaction DoD.

## Acceptance semantics

At `1180x760`, every `x`, `y`, `width`, and `height` component of every required non-text rectangle must differ by no more than 1 viewport pixel.
At `860x560`, `1440x900`, and any other explicitly requested size, the limit is 2 viewport pixels.
The limit is inclusive, so exactly 1 px or 2 px passes and any larger finite value fails.
Missing rectangles, malformed numbers, duplicate anchors, unevaluated anchors, disallowed probe sources, and missing required state assertions fail.

The per-channel changed-pixel threshold is pinned to 8 by the committed contract.
A pixel is counted as changed when any RGB channel difference is greater than the threshold.
The metrics also include exact changed pixels, mean absolute channel difference, RMS channel difference, PSNR, and maximum channel difference.
`--threshold 8` is accepted for compatibility, while any other value is rejected before comparison so it cannot weaken the gate.

Acceptance uses both aggregate and spatial pixel checks.
Spatial lengths and tile dimensions use normalized captured PNG pixels, while geometry anchors continue to use viewport pixels.
The aggregate limits are a changed-pixel ratio of 1.5 percent, structural and high-magnitude ratios of 0.01 percent, mean absolute channel difference of 1.0, and RMS channel difference of 6.0.
The spatial limits reject a changed component larger than 64 pixels or wider than 24 by 32 pixels, changed horizontal or vertical runs longer than 24 or 32 pixels, and a 16 by 16 tile with more than 35 percent changed pixels.
The stricter structural limits reject a component larger than 8 pixels or 8 by 8 pixels, runs longer than 8 pixels, and a tile with more than 3.125 percent structural pixels.
All limits are inclusive, all must pass, and a passing aggregate ratio cannot compensate for a failed component, run, or local-density check.
This makes broad background changes, shifted layouts, long borders, and changed icon fills fail even when their total changed area is small.

The current contract masks no pixels.
Its antialias mask radius is zero, and ordinary UI regions may not be masked.
The analyzer classifies a changed pixel as a possible antialias edge only when both images contain a local luminance edge at that pixel and the maximum channel difference is no greater than 48.
Those candidates remain counted in the changed-pixel aggregate, connected components, runs, and tile density.
Only the separate structural category excludes them, so the classification cannot hide long borders, icons, backgrounds, or layout patches.
This preserves bounded text-edge rasterization tolerance without expanding a mask or exempting ordinary UI pixels.

## Tool checks

Run the standalone checks with:

```bash
./Tests/Visual/VisualToolTests.sh
```

The checks validate the authoritative HTML hash, runtime-pin synchronization, scripts, the full default matrix, reference-runner compilation, named-state guards, deterministic unmasked pixel metrics, screenshot hash binding, recomputation after metrics tampering, required state assertions, every required anchor, inclusive 1 px and 2 px boundaries, and rejection immediately outside both tolerances.
Positive coverage includes identical frames and bounded common-edge antialias noise.
Negative coverage includes 3 percent to 6 percent bulk patches, whole-frame background changes, long border changes, icon fills, layout shifts, stale hashes, missing evidence, relaxed thresholds, and forged metrics.
