#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED_HTML_SHA="269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/markdownviewer-visual-tools.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM

fail() {
    echo "VisualToolTests: $*" >&2
    exit 1
}

ACTUAL_HTML_SHA="$(shasum -a 256 "$ROOT/ui/Markdown Viewer.dc.html" | awk '{print $1}')"
if [[ "$ACTUAL_HTML_SHA" != "$EXPECTED_HTML_SHA" ]]; then
    fail "authoritative HTML hash changed"
fi

bash -n "$ROOT/scripts/visual/visual-matrix.sh"
bash -n "$ROOT/scripts/visual/capture-reference.sh"
bash -n "$ROOT/scripts/visual/compare-real-app.sh"
PYTHONPYCACHEPREFIX="$TEMP_ROOT/pycache" python3 -m py_compile \
    "$ROOT/scripts/visual/pixel_acceptance.py" \
    "$ROOT/scripts/visual/compose-diff.py" \
    "$ROOT/scripts/visual/evaluate-acceptance.py" \
    "$ROOT/scripts/visual/verify-support-runtime.py"
python3 -m json.tool "$ROOT/scripts/visual/acceptance-contract.json" > /dev/null
[[ "$(shasum -a 256 "$ROOT/scripts/visual/acceptance-contract.json" | awk '{print $1}')" == \
    "1b28f6d306b97f18afbffda694bb659955a69298a9557b5a24e3d2d0a8d010dc" ]] \
    || fail "visual acceptance contract bytes changed"

. "$ROOT/scripts/visual/visual-matrix.sh"
[[ "$VISUAL_DEFAULT_SIZES" == "1180x760,860x560,1440x900" ]] \
    || fail "unexpected shared default sizes"
[[ "$VISUAL_DEFAULT_STATES" == "default,palette,find,preview,sidebar-hidden,source-editor,table-editor" ]] \
    || fail "unexpected shared default states"
rg -Fq -- '--sizes "$VISUAL_DEFAULT_SIZES"' "$ROOT/scripts/visual/capture-reference.sh"
rg -Fq -- '--states "$VISUAL_DEFAULT_STATES"' "$ROOT/scripts/visual/capture-reference.sh"
rg -Fq 'STATES="$VISUAL_DEFAULT_STATES"' "$ROOT/scripts/visual/compare-real-app.sh"
rg -Fq 'SIZES="$VISUAL_DEFAULT_SIZES"' "$ROOT/scripts/visual/compare-real-app.sh"
rg -Fq 'states: ["default", "palette", "find", "preview", "sidebar-hidden", "source-editor", "table-editor"]' "$ROOT/scripts/visual/ReferenceSnapshot.swift"
rg -Fq 'captureVisualProbe' "$ROOT/scripts/visual/ReferenceSnapshot.swift"
rg -Fq 'screenshotSHA256: pngHash' "$ROOT/scripts/visual/ReferenceSnapshot.swift"

python3 - "$ROOT/scripts/visual/acceptance-contract.json" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert contract["schemaVersion"] == 2
assert contract["kind"] == "markdown-viewer-visual-acceptance-contract"
assert contract["authoritativeHTMLSHA256"] == "269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d"
assert contract["coordinateSpace"] == "viewportPixels"
assert contract["requiredSizes"] == ["1180x760", "860x560", "1440x900"]
assert contract["tolerancePolicy"] == {"1180x760": 1, "otherSizes": 2}
assert contract["pixelAcceptancePolicy"] == {
    "analysis": {
        "algorithm": "full-frame-spatial-diff-v1",
        "changedPixelThreshold": 8,
        "edgeLocalRangeThreshold": 12,
        "edgeRadiusPixels": 1,
        "highMagnitudeThreshold": 48,
        "componentConnectivity": 8,
        "tileSizePixels": 16,
        "partialTilePolicy": "zero-pad-to-full-tile",
    },
    "limits": {
        "maximumChangedPixelRatio": 0.015,
        "maximumStructuralPixelRatio": 0.0001,
        "maximumHighMagnitudePixelRatio": 0.0001,
        "maximumMeanAbsoluteChannelDifference": 1.0,
        "maximumRootMeanSquareChannelDifference": 6.0,
        "maximumChangedComponentPixels": 64,
        "maximumChangedComponentWidthPixels": 24,
        "maximumChangedComponentHeightPixels": 32,
        "maximumChangedHorizontalRunPixels": 24,
        "maximumChangedVerticalRunPixels": 32,
        "maximumChangedTilePixelRatio": 0.35,
        "maximumStructuralComponentPixels": 8,
        "maximumStructuralComponentWidthPixels": 8,
        "maximumStructuralComponentHeightPixels": 8,
        "maximumStructuralHorizontalRunPixels": 8,
        "maximumStructuralVerticalRunPixels": 8,
        "maximumStructuralTilePixelRatio": 0.03125,
    },
    "antiAliasPolicy": {
        "classification": "changed pixels near luminance edges in both images and at or below the high-magnitude threshold",
        "pixelsRemainInChangedAggregate": True,
        "pixelsRemainInSpatialChecks": True,
        "masking": "none",
    },
}
assert contract["maskingPolicy"] == {
    "mode": "none",
    "ordinaryUIRegionsMasked": False,
    "antialiasMaskRadiusPixels": 0,
}
expected_mappings = {
    "default": "baseline",
    "palette": "palette-open",
    "find": "find-open",
    "preview": "preview-on",
    "sidebar-hidden": "sidebar-hidden",
    "source-editor": "source-editing",
    "table-editor": "table-grid",
}
assert {name: contract["states"][name]["appLabel"] for name in expected_mappings} == expected_mappings
expected_assertions = {
    "default": ["document-visible", "sidebar-visible", "palette-hidden", "find-panel-hidden", "source-editor-hidden", "table-grid-hidden"],
    "palette": ["document-visible", "palette-visible"],
    "find": ["document-visible", "find-panel-visible"],
    "preview": ["document-visible", "preview-active", "source-editor-hidden", "table-grid-hidden"],
    "sidebar-hidden": ["document-visible", "sidebar-hidden"],
    "source-editor": ["document-visible", "source-editor-visible", "table-grid-hidden"],
    "table-editor": ["document-visible", "table-grid-visible", "source-editor-hidden"],
}
common = ["sidebar-frame", "tab-bar-frame", "document-surface-frame", "document-page-frame", "outline-rail-frame"]
expected_anchors = {
    "default": common,
    "palette": common + ["palette-panel-frame"],
    "find": common + ["find-panel-frame"],
    "preview": common + ["preview-control-frame"],
    "sidebar-hidden": common[1:],
    "source-editor": common + ["source-editor-frame"],
    "table-editor": common + ["table-grid-frame"],
}
assert {name: contract["states"][name]["requiredStateAssertions"] for name in expected_mappings} == expected_assertions
assert {name: contract["states"][name]["requiredGeometryAnchors"] for name in expected_mappings} == expected_anchors
assert contract["allowedEvidenceSources"] == {
    "referenceState": ["authoritative-dom"],
    "referenceGeometry": ["authoritative-dom"],
    "appState": ["macos-accessibility", "debug-diagnostics", "image-analysis", "combined-machine-probes"],
    "appGeometry": ["macos-accessibility", "image-analysis", "combined-machine-probes"],
}
PY

REACT_URL="https://unpkg.com/react@18.3.1/umd/react.production.min.js"
REACT_SRI="sha384-DGyLxAyjq0f9SPpVevD6IgztCFlnMF6oW/XQGmfe+IsZ8TqEiDrcHkMLKI6fiB/Z"
REACT_DOM_URL="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js"
REACT_DOM_SRI="sha384-gTGxhz21lVGYNMcdJOyq01Edg0jhn/c22nsx0kyqP0TxaV5WVdsSH1fSDUf5YJj1"

verify_runtime() {
    local support_js="$1"
    python3 "$ROOT/scripts/visual/verify-support-runtime.py" \
        --support-js "$support_js" \
        --react-url "$REACT_URL" \
        --react-sri "$REACT_SRI" \
        --react-dom-url "$REACT_DOM_URL" \
        --react-dom-sri "$REACT_DOM_SRI"
}

verify_runtime "$ROOT/ui/support.js"
python3 - "$ROOT/ui/support.js" "$TEMP_ROOT/support-mismatch.js" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
source = source.replace(
    "https://unpkg.com/react@18.3.1/umd/react.production.min.js",
    "https://example.invalid/react.js",
    1,
)
pathlib.Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY
if verify_runtime "$TEMP_ROOT/support-mismatch.js" > /dev/null 2> "$TEMP_ROOT/pin-error.txt"; then
    fail "mismatched support.js runtime pins were accepted"
fi
rg -q "capture runtime pins do not match support.js" "$TEMP_ROOT/pin-error.txt"

xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -framework AppKit \
    -framework WebKit \
    "$ROOT/scripts/visual/ReferenceSnapshot.swift" \
    -o "$TEMP_ROOT/ReferenceSnapshot"
"$TEMP_ROOT/ReferenceSnapshot" --help > "$TEMP_ROOT/runner-help.txt"
rg -q "1180x760" "$TEMP_ROOT/runner-help.txt"
rg -q "table-editor" "$TEMP_ROOT/runner-help.txt"
rg -q "named state.*matched the default snapshot" "$ROOT/scripts/visual/ReferenceSnapshot.swift"
rg -q "capture matrix incomplete" "$ROOT/scripts/visual/ReferenceSnapshot.swift"

if "$TEMP_ROOT/ReferenceSnapshot" --states default,default \
    > /dev/null 2> "$TEMP_ROOT/duplicate-state-error.txt"; then
    fail "duplicate capture states were accepted"
fi
rg -q "states cannot contain duplicates" "$TEMP_ROOT/duplicate-state-error.txt"

if "$TEMP_ROOT/ReferenceSnapshot" --sizes 1180x760,,860x560 \
    > /dev/null 2> "$TEMP_ROOT/empty-size-error.txt"; then
    fail "empty capture size entries were accepted"
fi
rg -q "invalid viewport" "$TEMP_ROOT/empty-size-error.txt"

python3 - "$TEMP_ROOT" <<'PY'
import pathlib
import sys
from PIL import Image, ImageDraw

root = pathlib.Path(sys.argv[1])
reference = Image.new("RGB", (4, 2), (255, 255, 255))
app = reference.copy()
app.putpixel((1, 0), (245, 235, 225))
reference.save(root / "reference.png")
app.save(root / "app.png")
PY

python3 "$ROOT/scripts/visual/compose-diff.py" \
    --reference "$TEMP_ROOT/reference.png" \
    --app "$TEMP_ROOT/app.png" \
    --output-dir "$TEMP_ROOT/diff" \
    --label smoke \
    --threshold 8 \
    > "$TEMP_ROOT/metrics-path.txt"

python3 - "$TEMP_ROOT" <<'PY'
import json
import math
import pathlib
import sys
from PIL import Image

root = pathlib.Path(sys.argv[1])
metrics = json.loads((root / "diff/smoke-metrics.json").read_text(encoding="utf-8"))
assert metrics["schemaVersion"] == 2
assert metrics["kind"] == "unmasked-full-frame-visual-measurement"
assert metrics["measurementOnly"] is True
assert metrics["acceptance"]["evaluated"] is False
assert metrics["acceptance"]["status"] == "notEvaluated"
assert metrics["pixelSize"] == {"width": 4, "height": 2}
assert metrics["totalPixels"] == 8
assert metrics["exactChangedPixels"] == 1
assert metrics["changedPixels"] == 1
assert math.isclose(metrics["changedPixelRatio"], 0.125)
assert math.isclose(metrics["meanAbsoluteChannelDifference"], 2.5)
assert metrics["maximumChannelDifference"] == 30
assert metrics["masking"] == "none"
analysis = metrics["pixelAnalysis"]
assert analysis["algorithm"] == "full-frame-spatial-diff-v1"
assert analysis["parameters"]["changedPixelThreshold"] == 8
assert analysis["changed"]["pixels"] == 1
assert analysis["structural"]["pixels"] == 1
assert analysis["antialiasCandidates"]["pixels"] == 0
assert analysis["changed"]["largestConnectedComponent"] == {
    "pixels": 1,
    "bounds": {"x": 1, "y": 0, "width": 1, "height": 1},
}
overlay = Image.open(root / "diff/smoke-overlay-50.png").convert("RGB")
heatmap = Image.open(root / "diff/smoke-diff-heatmap.png").convert("RGB")
assert overlay.size == (4, 2)
assert heatmap.size == (4, 2)
assert overlay.getpixel((1, 0)) == (250, 245, 240)
assert heatmap.getpixel((0, 0)) == (0, 0, 0)
assert heatmap.getpixel((1, 0)) == (120, 24, 0)
PY

python3 - "$TEMP_ROOT" "$ROOT/scripts/visual/acceptance-contract.json" <<'PY'
import hashlib
import json
import pathlib
import shutil
import sys
from PIL import Image, ImageDraw

root = pathlib.Path(sys.argv[1])
contract = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
reference_root = root / "matrix-reference"
evidence_root = root / "matrix-app"
sizes = ["1180x760", "860x560", "1440x900"]
mapping = {
    "default": "baseline",
    "palette": "palette-open",
    "find": "find-open",
    "preview": "preview-on",
    "sidebar-hidden": "sidebar-hidden",
    "source-editor": "source-editing",
    "table-editor": "table-grid",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def visual_evidence(expected_state, screenshot_hash, assertions, anchors, side, offset):
    state_source = "authoritative-dom" if side == "reference" else "combined-machine-probes"
    geometry_source = "authoritative-dom" if side == "reference" else "image-analysis"
    return {
        "schemaVersion": 2,
        "kind": "machine-captured-visual-evidence",
        "screenshotSHA256": screenshot_hash,
        "stateEvaluation": {
            "evaluated": True,
            "status": "passed",
            "expectedState": expected_state,
            "observedState": expected_state,
            "source": state_source,
            "assertions": [
                {"name": name, "evaluated": True, "passed": True}
                for name in assertions
            ],
        },
        "geometryEvaluation": {
            "evaluated": True,
            "status": "passed",
            "coordinateSpace": "viewportPixels",
            "anchors": [
                {
                    "name": name,
                    "evaluated": True,
                    "source": geometry_source,
                    "rect": {
                        component: value + offset
                        for component, value in rect.items()
                    },
                }
                for name, rect in anchors.items()
            ],
        },
    }


snapshots = []
evidence_sizes = []
counter = 0
for size in sizes:
    screenshots = []
    for state, label in mapping.items():
        reference_path = reference_root / size / f"{state}.png"
        app_path = evidence_root / "sizes" / size / f"{label}.png"
        reference_path.parent.mkdir(parents=True, exist_ok=True)
        app_path.parent.mkdir(parents=True, exist_ok=True)
        color = (220 + counter % 20, 225, 230)
        reference_image = Image.new("RGB", (64, 64), color)
        app_image = reference_image.copy()
        reference_draw = ImageDraw.Draw(reference_image)
        app_draw = ImageDraw.Draw(app_image)
        reference_draw.line((4, 55, 59, 55), fill=(60, 65, 70))
        app_draw.line((4, 55, 59, 55), fill=(60, 65, 70))
        reference_draw.rectangle((46, 6, 51, 11), fill=(70, 75, 80))
        app_draw.rectangle((46, 6, 51, 11), fill=(70, 75, 80))
        reference_draw.rectangle((28, 20, 40, 32), outline=(80, 85, 90))
        app_draw.rectangle((28, 20, 40, 32), outline=(80, 85, 90))
        if counter == 0:
            reference_draw.line((12, 12, 12, 22), fill=(80, 85, 90))
            app_draw.line((12, 12, 12, 22), fill=(100, 105, 110))
        reference_image.save(reference_path)
        app_image.save(app_path)
        width, height = map(int, size.split("x"))
        reference_hash = digest(reference_path)
        app_hash = digest(app_path)
        state_contract = contract["states"][state]
        anchors = {
            name: {
                "x": 10.0 + anchor_index * 3,
                "y": 20.0 + anchor_index * 2,
                "width": 100.0 + anchor_index * 4,
                "height": 40.0 + anchor_index,
            }
            for anchor_index, name in enumerate(state_contract["requiredGeometryAnchors"])
        }
        allowed_offset = 1.0 if size == "1180x760" else 2.0
        snapshots.append({
            "state": state,
            "viewportWidth": width,
            "viewportHeight": height,
            "pixelWidth": 64,
            "pixelHeight": 64,
            "pngSHA256": reference_hash,
            "relativePath": str(reference_path.relative_to(reference_root)),
            "visualEvidence": visual_evidence(
                state,
                reference_hash,
                state_contract["requiredStateAssertions"],
                anchors,
                "reference",
                0.0,
            ),
        })
        screenshots.append({
            "label": label,
            "path": str(app_path.relative_to(evidence_root)),
            "pixelSize": {"width": 64, "height": 64},
            "sha256": app_hash,
            "visualEvidence": visual_evidence(
                label,
                app_hash,
                state_contract["requiredStateAssertions"],
                anchors,
                "app",
                allowed_offset,
            ),
        })
        counter += 1
    evidence_sizes.append({"status": "passed", "size": size, "screenshots": screenshots})

(reference_root / "manifest.json").write_text(
    json.dumps({
        "schemaVersion": 2,
        "kind": "authoritative-dc-webkit-reference",
        "authoritativeHTMLSHA256": "269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d",
        "acceptanceContractSHA256": "1b28f6d306b97f18afbffda694bb659955a69298a9557b5a24e3d2d0a8d010dc",
        "coverage": {"complete": True, "generatedSnapshotCount": len(snapshots)},
        "snapshots": snapshots,
    }),
    encoding="utf-8",
)
(evidence_root / "evidence.json").write_text(
    json.dumps({
        "schemaVersion": 2,
        "kind": "real-macos-app-e2e",
        "status": "passed",
        "authoritativeHTMLSHA256": "269489c87cef02a29006410cb5a1901a60af918fb7d5ec9de2411ae0e711cd9d",
        "visualAcceptanceContractSHA256": "1b28f6d306b97f18afbffda694bb659955a69298a9557b5a24e3d2d0a8d010dc",
        "interactionTier": "extended-full-pointer",
        "mode": "legacy-extended-full-pointer",
        "staticOnly": False,
        "keyboardOnly": False,
        "extendedFullPointer": True,
        "interactionClaims": {
            "takesFocus": True,
            "postsKeyboardInput": True,
            "movesPointer": True,
        },
        "preflight": {
            "accessibilityTrusted": True,
            "postEventAccess": True,
            "screenCaptureAccess": True,
        },
        "sizes": evidence_sizes,
    }),
    encoding="utf-8",
)

missing_root = root / "matrix-app-missing"
shutil.copytree(evidence_root, missing_root)
missing_evidence = json.loads((missing_root / "evidence.json").read_text(encoding="utf-8"))
for size_record in missing_evidence["sizes"]:
    if size_record["size"] == "860x560":
        size_record["screenshots"] = [
            item for item in size_record["screenshots"] if item["label"] != "palette-open"
        ]
(missing_root / "evidence.json").write_text(
    json.dumps(missing_evidence),
    encoding="utf-8",
)

missing_reference_root = root / "matrix-reference-missing"
shutil.copytree(reference_root, missing_reference_root)
missing_reference = json.loads(
    (missing_reference_root / "manifest.json").read_text(encoding="utf-8")
)
missing_reference["snapshots"] = [
    item
    for item in missing_reference["snapshots"]
    if not (
        item["viewportWidth"] == 1440
        and item["viewportHeight"] == 900
        and item["state"] == "find"
    )
]
(missing_reference_root / "manifest.json").write_text(
    json.dumps(missing_reference),
    encoding="utf-8",
)


def mutate_app_copy(name, mutation):
    destination = root / name
    shutil.copytree(evidence_root, destination)
    path = destination / "evidence.json"
    value = json.loads(path.read_text(encoding="utf-8"))
    mutation(value)
    path.write_text(json.dumps(value), encoding="utf-8")


def screenshot(evidence, size, label):
    size_record = next(item for item in evidence["sizes"] if item["size"] == size)
    return next(item for item in size_record["screenshots"] if item["label"] == label)


def mutate_pixel_copy(name, size, label, mutation):
    destination = root / name
    shutil.copytree(evidence_root, destination)
    evidence_path = destination / "evidence.json"
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    target = screenshot(evidence, size, label)
    image_path = destination / target["path"]
    with Image.open(image_path) as opened:
        image = opened.convert("RGB")
    replacement = mutation(image)
    if replacement is not None:
        image = replacement
    image.save(image_path)
    image_hash = digest(image_path)
    target["sha256"] = image_hash
    target["visualEvidence"]["screenshotSHA256"] = image_hash
    evidence_path.write_text(json.dumps(evidence), encoding="utf-8")


def paint_bulk_patch(image):
    ImageDraw.Draw(image).rectangle((0, 0, 12, 12), fill=(0, 0, 0))


def tint_entire_frame(image):
    return image.point(lambda value: max(0, value - 10))


def change_long_border(image):
    ImageDraw.Draw(image).line((4, 55, 59, 55), fill=(90, 95, 100))


def change_icon_fill(image):
    ImageDraw.Draw(image).rectangle((46, 6, 51, 11), fill=(100, 105, 110))


def shift_layout_box(image):
    background = image.getpixel((0, 63))
    draw = ImageDraw.Draw(image)
    draw.rectangle((27, 19, 41, 33), fill=background)
    draw.rectangle((30, 20, 42, 32), outline=(80, 85, 90))


def make_passive_evidence(evidence):
    launches = []
    lifecycles = []
    for index, (size, state) in enumerate(
        (size, state) for size in sizes for state in mapping
    ):
        pid = 20_000 + index
        window = {
            "pid": pid,
            "windowNumber": 40_000 + index,
            "layer": 0,
            "onScreen": False,
        }
        launches.append({
            "schemaVersion": 1,
            "kind": "deterministic-visual-test-launch",
            "logicalSize": size,
            "requestedState": state,
            "resolvedState": state,
            "appLabel": mapping[state],
            "pid": pid,
            "profileRoot": f"/tmp/markdown-viewer-passive/{size}/{state}",
            "diagnosticSHA256": f"{index + 1:064x}",
            "stableSampleCount": 3,
            "window": window,
            "processWindows": [dict(window)],
        })
        target_screenshot = screenshot(evidence, size, mapping[state])
        target_screenshot["windowIdentityAtCapture"] = dict(window)
        target_screenshot["processWindowsAtCapture"] = [dict(window)]
        lifecycles.append({
            "targetPID": pid,
            "targetExitedBeforeObserverStop": True,
            "targetNeverFrontmost": True,
            "pointerUnchanged": True,
            "lifecycleFrontmostObserver": {
                "targetPID": pid,
                "targetBecameFrontmost": False,
                "stopFileObserved": True,
                "timedOut": False,
            },
            "endpointObservations": {
                "pointerChangedBetweenEndpoints": False,
                "before": {
                    "frontmostPID": 900,
                    "pointer": {"x": 100.0, "y": 200.0},
                },
                "after": {
                    "frontmostPID": 901,
                    "pointer": {"x": 100.0, "y": 200.0},
                },
            },
        })
    evidence.update({
        "interactionTier": "passive",
        "mode": "passive-window-observation",
        "runScope": "strict-acceptance-matrix",
        "strictVisualAcceptanceEligible": True,
        "coverage": {"strictMatrixComplete": True},
        "staticOnly": True,
        "keyboardOnly": False,
        "extendedFullPointer": False,
        "interactionClaims": {
            "takesFocus": False,
            "postsKeyboardInput": False,
            "movesPointer": False,
        },
        "requestedSizes": sizes,
        "requestedVisualStates": list(mapping),
        "resolvedVisualStateLaunches": launches,
        "passiveLifecycleAssertions": lifecycles,
    })


def make_passive_evidence_without_lifecycle(evidence):
    make_passive_evidence(evidence)
    evidence["passiveLifecycleAssertions"] = []


def make_passive_evidence_with_mismatched_capture(evidence):
    make_passive_evidence(evidence)
    capture = screenshot(evidence, "1180x760", "baseline")["windowIdentityAtCapture"]
    capture["pid"] += 1


def make_passive_evidence_with_frontmost_observation(evidence):
    make_passive_evidence(evidence)
    observer = evidence["passiveLifecycleAssertions"][0]["lifecycleFrontmostObserver"]
    observer["targetBecameFrontmost"] = True


def make_passive_evidence_with_onscreen_process_window(evidence):
    make_passive_evidence(evidence)
    evidence["resolvedVisualStateLaunches"][0]["processWindows"][0]["onScreen"] = True


def make_passive_probe_evidence(evidence):
    make_passive_evidence(evidence)
    evidence["runScope"] = "development-probe"
    evidence["strictVisualAcceptanceEligible"] = False
    evidence["coverage"]["strictMatrixComplete"] = False


mutate_app_copy(
    "matrix-app-missing-evidence",
    lambda evidence: screenshot(evidence, "1180x760", "baseline").pop("visualEvidence"),
)
mutate_app_copy(
    "matrix-app-missing-state",
    lambda evidence: screenshot(evidence, "1180x760", "baseline")["visualEvidence"].pop("stateEvaluation"),
)
mutate_app_copy(
    "matrix-app-failed-state",
    lambda evidence: screenshot(evidence, "1180x760", "palette-open")["visualEvidence"]["stateEvaluation"]["assertions"][0].update({"passed": False}),
)
mutate_app_copy(
    "matrix-app-missing-anchor",
    lambda evidence: screenshot(evidence, "860x560", "find-open")["visualEvidence"]["geometryEvaluation"]["anchors"].pop(),
)
mutate_app_copy(
    "matrix-app-unevaluated-anchor",
    lambda evidence: screenshot(evidence, "860x560", "find-open")["visualEvidence"]["geometryEvaluation"]["anchors"][0].update({"evaluated": False}),
)


def move_anchor_outside(evidence, size, label, amount):
    target = screenshot(evidence, size, label)
    target["visualEvidence"]["geometryEvaluation"]["anchors"][0]["rect"]["x"] += amount


mutate_app_copy(
    "matrix-app-anchor-outside-1180",
    lambda evidence: move_anchor_outside(evidence, "1180x760", "baseline", 0.001),
)
mutate_app_copy(
    "matrix-app-anchor-outside-other",
    lambda evidence: move_anchor_outside(evidence, "1440x900", "baseline", 0.001),
)
mutate_app_copy(
    "matrix-app-stale-evidence",
    lambda evidence: screenshot(evidence, "1180x760", "baseline")["visualEvidence"].update({"screenshotSHA256": "0" * 64}),
)
mutate_app_copy(
    "matrix-app-schema1",
    lambda evidence: evidence.update({"schemaVersion": 1}),
)
mutate_app_copy(
    "matrix-app-keyboard-only",
    lambda evidence: evidence.update({
        "interactionTier": "keyboard-only",
        "mode": "legacy-focus-taking-keyboard",
        "keyboardOnly": True,
        "extendedFullPointer": False,
        "interactionClaims": {
            "takesFocus": True,
            "postsKeyboardInput": True,
            "movesPointer": False,
        },
    }),
)
mutate_app_copy(
    "matrix-app-passive",
    make_passive_evidence,
)
mutate_app_copy(
    "matrix-app-passive-missing-lifecycle",
    make_passive_evidence_without_lifecycle,
)
mutate_app_copy(
    "matrix-app-passive-mismatched-capture",
    make_passive_evidence_with_mismatched_capture,
)
mutate_app_copy(
    "matrix-app-passive-frontmost-observation",
    make_passive_evidence_with_frontmost_observation,
)
mutate_app_copy(
    "matrix-app-passive-onscreen-process-window",
    make_passive_evidence_with_onscreen_process_window,
)
mutate_app_copy(
    "matrix-app-passive-probe",
    make_passive_probe_evidence,
)
mutate_app_copy(
    "matrix-app-foreground-smoke",
    lambda evidence: evidence.update({
        "interactionTier": "foreground-smoke",
        "mode": "bounded-foreground-smoke",
        "extendedFullPointer": False,
        "interactionClaims": {
            "takesFocus": True,
            "postsKeyboardInput": True,
            "movesPointer": True,
        },
    }),
)
mutate_app_copy(
    "matrix-app-old-full-pointer-mode",
    lambda evidence: evidence.update({"mode": "full-pointer"}),
)
mutate_app_copy(
    "matrix-app-missing-extended-flag",
    lambda evidence: evidence.pop("extendedFullPointer"),
)
mutate_pixel_copy(
    "matrix-app-bulk-pixel-difference",
    "860x560",
    "baseline",
    paint_bulk_patch,
)
mutate_pixel_copy(
    "matrix-app-background-difference",
    "1180x760",
    "find-open",
    tint_entire_frame,
)
mutate_pixel_copy(
    "matrix-app-border-difference",
    "1440x900",
    "preview-on",
    change_long_border,
)
mutate_pixel_copy(
    "matrix-app-icon-difference",
    "1180x760",
    "sidebar-hidden",
    change_icon_fill,
)
mutate_pixel_copy(
    "matrix-app-layout-difference",
    "860x560",
    "source-editing",
    shift_layout_box,
)
PY

bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --reference "$TEMP_ROOT/matrix-reference" \
    --app-evidence "$TEMP_ROOT/matrix-app" \
    --output "$TEMP_ROOT/default-matrix-output" \
    > "$TEMP_ROOT/default-matrix.log"

python3 - "$TEMP_ROOT/default-matrix-output/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["schemaVersion"] == 2
assert manifest["kind"] == "authoritative-reference-to-real-app-visual-acceptance"
assert manifest["measurementOnly"] is False
assert manifest["requestedMatrix"] == {
    "sizes": ["1180x760", "860x560", "1440x900"],
    "states": ["default", "palette", "find", "preview", "sidebar-hidden", "source-editor", "table-editor"],
    "expectedPairCount": 21,
}
assert manifest["coverage"] == {"complete": True, "generatedPairCount": 21}
assert manifest["geometryTolerancePolicy"] == {"1180x760": 1, "otherSizes": 2}
assert manifest["measurement"]["acceptanceUsesAggregatePixelScore"] is True
assert manifest["measurement"]["acceptanceUsesSpatialPixelChecks"] is True
assert manifest["measurement"]["acceptanceUsesOnlyAggregatePixelScore"] is False
assert manifest["measurement"]["pixelChangeThreshold"] == 8
assert manifest["masking"] == {
    "mode": "none",
    "ordinaryUIRegionsMasked": False,
    "antialiasMaskRadiusPixels": 0,
}
assert manifest["acceptance"] == {
    "evaluated": True,
    "status": "passed",
    "passedPairCount": 21,
    "failedPairCount": 0,
    "failures": [],
}
assert len(manifest["comparisons"]) == 21
assert all(item["schemaVersion"] == 2 for item in manifest["comparisons"])
assert all(item["acceptance"] == {"evaluated": True, "status": "passed", "failures": []} for item in manifest["comparisons"])
assert all(item["stateEvaluation"]["status"] == "passed" for item in manifest["comparisons"])
assert all(item["geometryEvaluation"]["evaluated"] for item in manifest["comparisons"])
assert all(item["pixelEvaluation"]["evaluated"] for item in manifest["comparisons"])
assert all(item["pixelEvaluation"]["status"] == "passed" for item in manifest["comparisons"])
assert all(item["pixelEvaluation"]["masking"] == "none" for item in manifest["comparisons"])
assert all(item["pixelEvaluation"]["checks"] for item in manifest["comparisons"])
assert all(all(anchor["withinTolerance"] for anchor in item["geometryEvaluation"]["anchors"]) for item in manifest["comparisons"])
assert {item["geometryEvaluation"]["tolerancePixels"] for item in manifest["comparisons"] if item["size"] == "1180x760"} == {1.0}
assert {item["geometryEvaluation"]["tolerancePixels"] for item in manifest["comparisons"] if item["size"] != "1180x760"} == {2.0}
assert all(item["pixelMeasurement"]["masking"] == "none" for item in manifest["comparisons"])
baseline = next(
    item
    for item in manifest["comparisons"]
    if item["size"] == "1180x760"
    and item["statePair"]["referenceState"] == "default"
)
analysis = baseline["pixelEvaluation"]["analysis"]
assert analysis["changed"]["pixels"] == 11
assert analysis["antialiasCandidates"]["pixels"] == 11
assert analysis["structural"]["pixels"] == 0
PY

bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --reference "$TEMP_ROOT/matrix-reference" \
    --app-evidence "$TEMP_ROOT/matrix-app" \
    --output "$TEMP_ROOT/all-mappings-output" \
    --sizes 1180x760 \
    --states default,palette,find,preview,sidebar-hidden,source-editor,table-editor \
    > "$TEMP_ROOT/all-mappings.log"

python3 - "$TEMP_ROOT/all-mappings-output/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["coverage"] == {"complete": True, "generatedPairCount": 7}
expected_labels = {
    "baseline.png",
    "palette-open.png",
    "find-open.png",
    "preview-on.png",
    "sidebar-hidden.png",
    "source-editing.png",
    "table-grid.png",
}
actual_labels = {
    pathlib.Path(item["pixelMeasurement"]["app"]["path"]).name
    for item in manifest["comparisons"]
}
assert actual_labels == expected_labels
PY

bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --reference "$TEMP_ROOT/matrix-reference" \
    --app-evidence "$TEMP_ROOT/matrix-app-passive" \
    --output "$TEMP_ROOT/passive-matrix-output" \
    > "$TEMP_ROOT/passive-matrix.log"

python3 - "$TEMP_ROOT/passive-matrix-output/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["coverage"] == {"complete": True, "generatedPairCount": 21}
assert manifest["acceptance"] == {
    "evaluated": True,
    "status": "passed",
    "passedPairCount": 21,
    "failedPairCount": 0,
    "failures": [],
}
PY

python3 - "$TEMP_ROOT/default-matrix-output" "$TEMP_ROOT/tampered-metrics-list.txt" <<'PY'
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
metrics_paths = []
for size in ("1180x760", "860x560", "1440x900"):
    for state in (
        "default",
        "palette",
        "find",
        "preview",
        "sidebar-hidden",
        "source-editor",
        "table-editor",
    ):
        metrics_paths.append(output / size / state / f"{state}-metrics.json")
target = metrics_paths[0]
metrics = json.loads(target.read_text(encoding="utf-8"))
metrics["changedPixelRatio"] = 0.0
metrics["pixelAnalysis"]["changed"]["pixelRatio"] = 0.0
target.write_text(json.dumps(metrics), encoding="utf-8")
pathlib.Path(sys.argv[2]).write_text(
    "".join(f"{path}\n" for path in metrics_paths),
    encoding="utf-8",
)
PY

python3 "$ROOT/scripts/visual/evaluate-acceptance.py" \
    --reference-manifest "$TEMP_ROOT/matrix-reference/manifest.json" \
    --app-evidence "$TEMP_ROOT/matrix-app/evidence.json" \
    --contract "$ROOT/scripts/visual/acceptance-contract.json" \
    --metrics-list "$TEMP_ROOT/tampered-metrics-list.txt" \
    --sizes "1180x760,860x560,1440x900" \
    --states "default,palette,find,preview,sidebar-hidden,source-editor,table-editor" \
    --mapping "default=baseline,palette=palette-open,find=find-open,preview=preview-on,sidebar-hidden=sidebar-hidden,source-editor=source-editing,table-editor=table-grid" \
    --threshold 8 \
    > "$TEMP_ROOT/tampered-metrics-manifest.json"

python3 - "$TEMP_ROOT/tampered-metrics-manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["acceptance"]["status"] == "failed"
assert any(
    "pixel measurement does not match recomputation from bound screenshots" in failure
    for failure in manifest["acceptance"]["failures"]
)
PY

if bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --reference "$TEMP_ROOT/matrix-reference" \
    --app-evidence "$TEMP_ROOT/matrix-app-missing" \
    --output "$TEMP_ROOT/incomplete-output" \
    --sizes 1180x760,860x560 \
    --states default,palette \
    > /dev/null 2> "$TEMP_ROOT/incomplete-error.txt"; then
    fail "an incomplete requested comparison matrix was accepted"
fi
rg -q "requested matrix is incomplete" "$TEMP_ROOT/incomplete-error.txt"
rg -q "missing requested app pair 860x560/palette" "$TEMP_ROOT/incomplete-error.txt"
[[ ! -e "$TEMP_ROOT/incomplete-output/manifest.json" ]] \
    || fail "incomplete comparison emitted a manifest"

if bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --reference "$TEMP_ROOT/matrix-reference-missing" \
    --app-evidence "$TEMP_ROOT/matrix-app" \
    --output "$TEMP_ROOT/missing-reference-output" \
    --sizes 1180x760,1440x900 \
    --states default,find \
    > /dev/null 2> "$TEMP_ROOT/missing-reference-error.txt"; then
    fail "a missing requested reference pair was accepted"
fi
rg -q "missing requested reference pair 1440x900/find" \
    "$TEMP_ROOT/missing-reference-error.txt"
[[ ! -e "$TEMP_ROOT/missing-reference-output/manifest.json" ]] \
    || fail "missing reference comparison emitted a manifest"

expect_gate_failure() {
    local name="$1"
    local app_root="$2"
    local size="$3"
    local state="$4"
    local expected_error="$5"
    local output="$TEMP_ROOT/$name-output"
    local error="$TEMP_ROOT/$name-error.txt"
    if bash "$ROOT/scripts/visual/compare-real-app.sh" \
        --reference "$TEMP_ROOT/matrix-reference" \
        --app-evidence "$app_root" \
        --output "$output" \
        --sizes "$size" \
        --states "$state" \
        > /dev/null 2> "$error"; then
        fail "$name acceptance failure was accepted"
    fi
    rg -Fq "$expected_error" "$error"
    [[ -s "$output/manifest.json" ]] \
        || fail "$name did not emit its failed acceptance manifest"
    python3 - "$output/manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["schemaVersion"] == 2
assert manifest["acceptance"]["evaluated"] is True
assert manifest["acceptance"]["status"] == "failed"
assert manifest["acceptance"]["failures"]
PY
}

expect_gate_failure \
    "missing-evidence" \
    "$TEMP_ROOT/matrix-app-missing-evidence" \
    "1180x760" \
    "default" \
    "app visualEvidence is missing"

expect_gate_failure \
    "missing-state" \
    "$TEMP_ROOT/matrix-app-missing-state" \
    "1180x760" \
    "default" \
    "app state evaluation is missing"

expect_gate_failure \
    "failed-state" \
    "$TEMP_ROOT/matrix-app-failed-state" \
    "1180x760" \
    "palette" \
    "app required state assertion 'document-visible' did not pass"

expect_gate_failure \
    "missing-anchor" \
    "$TEMP_ROOT/matrix-app-missing-anchor" \
    "860x560" \
    "find" \
    "app is missing required geometry anchor 'find-panel-frame'"

expect_gate_failure \
    "unevaluated-anchor" \
    "$TEMP_ROOT/matrix-app-unevaluated-anchor" \
    "860x560" \
    "find" \
    "app geometry anchor 'sidebar-frame' was not evaluated"

expect_gate_failure \
    "outside-anchor-1180" \
    "$TEMP_ROOT/matrix-app-anchor-outside-1180" \
    "1180x760" \
    "default" \
    "geometry anchor 'sidebar-frame' error 1.001 px exceeds 1 px"

expect_gate_failure \
    "outside-anchor-other" \
    "$TEMP_ROOT/matrix-app-anchor-outside-other" \
    "1440x900" \
    "default" \
    "geometry anchor 'sidebar-frame' error 2.001 px exceeds 2 px"

expect_gate_failure \
    "stale-evidence" \
    "$TEMP_ROOT/matrix-app-stale-evidence" \
    "1180x760" \
    "default" \
    "app visualEvidence is not bound to the screenshot hash"

expect_gate_failure \
    "schema1-evidence" \
    "$TEMP_ROOT/matrix-app-schema1" \
    "1180x760" \
    "default" \
    "real-app evidence is not schema-v2 evidence"

expect_gate_failure \
    "keyboard-only-evidence" \
    "$TEMP_ROOT/matrix-app-keyboard-only" \
    "1180x760" \
    "default" \
    "real-app evidence interactionTier is not eligible for visual acceptance"

expect_gate_failure \
    "passive-missing-lifecycle-evidence" \
    "$TEMP_ROOT/matrix-app-passive-missing-lifecycle" \
    "1180x760" \
    "default" \
    "passive real-app lifecycle evidence is incomplete"

expect_gate_failure \
    "passive-mismatched-capture-evidence" \
    "$TEMP_ROOT/matrix-app-passive-mismatched-capture" \
    "1180x760" \
    "default" \
    "passive real-app screenshot window identity does not match launch for 1180x760/default"

expect_gate_failure \
    "passive-frontmost-observation-evidence" \
    "$TEMP_ROOT/matrix-app-passive-frontmost-observation" \
    "1180x760" \
    "default" \
    "passive real-app lifecycle observer evidence is invalid"

expect_gate_failure \
    "passive-onscreen-process-window-evidence" \
    "$TEMP_ROOT/matrix-app-passive-onscreen-process-window" \
    "1180x760" \
    "default" \
    "passive real-app visual launch process windows are unsafe for 1180x760/default"

expect_gate_failure \
    "passive-development-probe-evidence" \
    "$TEMP_ROOT/matrix-app-passive-probe" \
    "1180x760" \
    "default" \
    "passive real-app evidence is not strict-acceptance eligible"

expect_gate_failure \
    "foreground-smoke-evidence" \
    "$TEMP_ROOT/matrix-app-foreground-smoke" \
    "1180x760" \
    "default" \
    "real-app evidence interactionTier is not eligible for visual acceptance"

expect_gate_failure \
    "old-full-pointer-mode-evidence" \
    "$TEMP_ROOT/matrix-app-old-full-pointer-mode" \
    "1180x760" \
    "default" \
    "real-app evidence mode is not legacy-extended-full-pointer"

expect_gate_failure \
    "missing-extended-flag-evidence" \
    "$TEMP_ROOT/matrix-app-missing-extended-flag" \
    "1180x760" \
    "default" \
    "real-app evidence extendedFullPointer flag is not true"

expect_gate_failure \
    "bulk-pixel-difference" \
    "$TEMP_ROOT/matrix-app-bulk-pixel-difference" \
    "860x560" \
    "default" \
    "pixel changed pixel ratio"

expect_gate_failure \
    "background-pixel-difference" \
    "$TEMP_ROOT/matrix-app-background-difference" \
    "1180x760" \
    "find" \
    "pixel changed pixel ratio"

expect_gate_failure \
    "border-pixel-difference" \
    "$TEMP_ROOT/matrix-app-border-difference" \
    "1440x900" \
    "preview" \
    "pixel largest changed component width"

expect_gate_failure \
    "icon-pixel-difference" \
    "$TEMP_ROOT/matrix-app-icon-difference" \
    "1180x760" \
    "sidebar-hidden" \
    "pixel structural pixel ratio"

expect_gate_failure \
    "layout-pixel-difference" \
    "$TEMP_ROOT/matrix-app-layout-difference" \
    "860x560" \
    "source-editor" \
    "pixel structural pixel ratio"

python3 - \
    "$TEMP_ROOT/bulk-pixel-difference-output/manifest.json" \
    "$TEMP_ROOT/background-pixel-difference-output/manifest.json" \
    "$TEMP_ROOT/border-pixel-difference-output/manifest.json" \
    "$TEMP_ROOT/icon-pixel-difference-output/manifest.json" \
    "$TEMP_ROOT/layout-pixel-difference-output/manifest.json" <<'PY'
import json
import pathlib
import sys

bulk, background, border, icon, layout = [
    json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    for path in sys.argv[1:]
]


def only_comparison(manifest):
    assert manifest["acceptance"]["status"] == "failed"
    assert len(manifest["comparisons"]) == 1
    comparison = manifest["comparisons"][0]
    assert comparison["stateEvaluation"]["status"] == "passed"
    assert comparison["geometryEvaluation"]["status"] == "passed"
    assert comparison["pixelEvaluation"]["status"] == "failed"
    return comparison


bulk_comparison = only_comparison(bulk)
bulk_ratio = bulk_comparison["pixelEvaluation"]["analysis"]["changed"]["pixelRatio"]
assert 0.03 <= bulk_ratio <= 0.06

background_comparison = only_comparison(background)
assert background_comparison["pixelEvaluation"]["analysis"]["changed"]["pixelRatio"] == 1.0

border_comparison = only_comparison(border)
border_checks = {
    check["name"]: check for check in border_comparison["pixelEvaluation"]["checks"]
}
assert border_checks["changedPixelRatio"]["passed"] is True
assert border_checks["changedComponentWidthPixels"]["passed"] is False
assert border_checks["changedHorizontalRunPixels"]["passed"] is False

icon_comparison = only_comparison(icon)
icon_checks = {
    check["name"]: check for check in icon_comparison["pixelEvaluation"]["checks"]
}
assert icon_checks["changedPixelRatio"]["passed"] is True
assert icon_checks["structuralComponentPixels"]["passed"] is False

layout_comparison = only_comparison(layout)
assert any(
    check["passed"] is False
    for check in layout_comparison["pixelEvaluation"]["checks"]
    if check["name"].startswith("structural")
)
PY

if bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --contract "$ROOT/scripts/visual/acceptance-contract.json" \
    > /dev/null 2> "$TEMP_ROOT/contract-override-error.txt"; then
    fail "compare-real-app accepted an acceptance-contract override"
fi
rg -q "unknown option: --contract" "$TEMP_ROOT/contract-override-error.txt"

if bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --threshold 9 \
    > /dev/null 2> "$TEMP_ROOT/threshold-override-error.txt"; then
    fail "compare-real-app accepted a relaxed pixel threshold"
fi
rg -q "threshold is pinned to 8" "$TEMP_ROOT/threshold-override-error.txt"

if bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --reference "$TEMP_ROOT/matrix-reference" \
    --app-evidence "$TEMP_ROOT/matrix-app" \
    --output "$TEMP_ROOT/unmapped-output" \
    --sizes 1180x760 \
    --states replace \
    > /dev/null 2> "$TEMP_ROOT/unmapped-error.txt"; then
    fail "an unmapped requested state was accepted"
fi
rg -q "state 'replace' has no real-app E2E mapping" "$TEMP_ROOT/unmapped-error.txt"

if bash "$ROOT/scripts/visual/compare-real-app.sh" \
    --states default,,find \
    > /dev/null 2> "$TEMP_ROOT/empty-state-error.txt"; then
    fail "an empty requested state entry was accepted"
fi
rg -q "states must be a nonempty comma-separated list" "$TEMP_ROOT/empty-state-error.txt"

echo "VisualToolTests: PASS"
