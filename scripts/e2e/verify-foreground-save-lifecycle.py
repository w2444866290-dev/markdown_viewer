#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import pathlib
from typing import Any


BOM = b"\xef\xbb\xbf"
MARKDOWN_BASELINE = BOM + b"# Save lifecycle\r\n\r\nmarkdown original\r\n"
MARKDOWN_SAVED = BOM + b"# Save lifecycle\r\n\r\nmarkdown latest\r\n"
TABLE_BASELINE = (
    b"# Table lifecycle\n\n"
    b"| Name | Value |\n"
    b"| --- | --- |\n"
    b"| row | table original |"
)
TABLE_SAVED = TABLE_BASELINE.replace(b"table original", b"table latest")
CONFLICT_BASELINE = b"# Conflict lifecycle\n\nconflict baseline\n"
CONFLICT_EXTERNAL = b"# Conflict lifecycle\n\nexternal replacement\n"
CONFLICT_DRAFT_TEXT = "# Conflict lifecycle\n\nconflict draft\n"
CURRENT_CONFLICT_DRAFT_TEXT = "# Conflict lifecycle\n\ncurrent conflict draft\n"
SESSION_BASELINE = b"# Session lifecycle\n\nsession baseline\n"
SESSION_EXTERNAL = b"# Session lifecycle\n\nsession external replacement\n"
SESSION_DRAFT_TEXT = "# Session lifecycle\n\nsession conflict draft\n"
PLAIN_BASELINE = BOM + b"model: gpt-4o\r\ntemperature: 0.2\r\n"
PLAIN_SAVED = BOM + b"model: gpt-4o\r\ntemperature: 0.7\r\n"

STAGES = (
    "markdown-save",
    "table-save",
    "conflict-open",
    "conflict-save",
    "save-as-new",
    "conflict-save-as-current",
    "conflict-save-as-symlink",
    "session-draft",
    "restored-conflict-save",
    "plain-open-diagnostic",
    "plain-save",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify one real-App Goal 2 save lifecycle phase."
    )
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--diagnostic", required=True)
    parser.add_argument("--foreground-report", required=True)
    parser.add_argument("--workspace-root", required=True)
    parser.add_argument("--expected-session-path", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--ocr")
    parser.add_argument(
        "--report-kind",
        choices=("session", "diagnostic"),
    )
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if args.check_only == (args.report_kind is not None):
        parser.error("choose exactly one of --check-only or --report-kind")
    return args


def load_object(raw_path: str, label: str) -> tuple[pathlib.Path, dict[str, Any]]:
    path = pathlib.Path(raw_path).expanduser().resolve()
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is not readable JSON: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must contain a JSON object")
    return path, value


def require_directory(raw_path: str, label: str) -> pathlib.Path:
    path = pathlib.Path(raw_path).expanduser().resolve()
    if not path.is_dir():
        raise SystemExit(f"{label} must be an existing directory: {path}")
    return path


def normalized_path(raw_path: str) -> str:
    return os.path.realpath(os.path.abspath(os.path.expanduser(raw_path)))


def read_bytes(path: pathlib.Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise SystemExit(f"required lifecycle file is unreadable: {path}: {error}") from error


def tab_url(tab: dict[str, Any]) -> str | None:
    value = tab.get("url")
    return normalized_path(value) if isinstance(value, str) else None


def active_tab(session: dict[str, Any]) -> dict[str, Any]:
    tabs = session.get("tabs")
    if not isinstance(tabs, list) or any(not isinstance(tab, dict) for tab in tabs):
        raise SystemExit("session has no structured tabs array")
    active_id = session.get("activeTabID")
    matches = [tab for tab in tabs if tab.get("id") == active_id]
    if len(matches) != 1:
        raise SystemExit("session does not identify exactly one active tab")
    return matches[0]


def tab_for_path(session: dict[str, Any], path: pathlib.Path) -> dict[str, Any] | None:
    expected = normalized_path(str(path))
    tabs = session.get("tabs", [])
    matches = [tab for tab in tabs if isinstance(tab, dict) and tab_url(tab) == expected]
    if len(matches) > 1:
        raise SystemExit(f"session contains duplicate canonical tabs for {path}")
    return matches[0] if matches else None


def baseline_bytes(tab: dict[str, Any]) -> tuple[str, bytes] | None:
    baseline = tab.get("diskBaseline")
    if baseline is None:
        return None
    if not isinstance(baseline, dict):
        raise SystemExit("tab diskBaseline is not an object")
    canonical = baseline.get("canonicalPath")
    encoded = baseline.get("bytes")
    if not isinstance(canonical, str) or not isinstance(encoded, str):
        raise SystemExit("tab diskBaseline has an invalid schema")
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise SystemExit("tab diskBaseline bytes are not canonical base64") from error
    return normalized_path(canonical), payload


def report_complete(report: dict[str, Any]) -> bool:
    actions = report.get("actions")
    return (
        report.get("completed") is True
        and report.get("deadlineExceeded") is False
        and report.get("error") in (None, "")
        and isinstance(actions, list)
        and bool(actions)
        and all(
            isinstance(action, dict) and action.get("status") == "completed"
            for action in actions
        )
    )


def diagnostics_match(
    diagnostic: dict[str, Any],
    *,
    document: str,
    mode: str,
    dirty: bool,
    expected_session_path: str,
) -> bool:
    return (
        diagnostic.get("schemaVersion") == 1
        and diagnostic.get("document") == document
        and diagnostic.get("mode") == mode
        and diagnostic.get("dirty") is dirty
        and normalized_path(str(diagnostic.get("sessionPath", "")))
        == normalized_path(expected_session_path)
    )


def markdown_editor_visible(diagnostic: dict[str, Any], block_type: str) -> bool:
    visual = diagnostic.get("visual")
    return (
        diagnostic.get("blockID") is not None
        and diagnostic.get("blockType") == block_type
        and isinstance(visual, dict)
        and visual.get("documentVisible") is True
        and visual.get("sourceEditorVisible") is (block_type != "table")
        and visual.get("tableGridVisible") is (block_type == "table")
    )


def ocr_contains(ocr: dict[str, Any] | None, values: tuple[str, ...]) -> bool:
    if ocr is None:
        return False
    recognized = ocr.get("recognizedText")
    if not isinstance(recognized, list) or any(not isinstance(item, str) for item in recognized):
        return False
    normalized = "".join(character.lower() for character in "\n".join(recognized) if character.isalnum())
    return all(
        "".join(character.lower() for character in value if character.isalnum())
        in normalized
        for value in values
    )


def tab_state(
    tab: dict[str, Any] | None,
    *,
    path: pathlib.Path,
    text: str,
    dirty: bool,
    baseline: bytes,
    markdown: bool,
) -> bool:
    if tab is None:
        return False
    observed_baseline = baseline_bytes(tab)
    return (
        tab_url(tab) == normalized_path(str(path))
        and tab.get("text") == text
        and tab.get("isDirty") is dirty
        and tab.get("isMarkdown") is markdown
        and observed_baseline == (normalized_path(str(path)), baseline)
    )


def build_assertions(
    *,
    stage: str,
    session: dict[str, Any],
    diagnostic: dict[str, Any],
    report: dict[str, Any],
    workspace: pathlib.Path,
    expected_session_path: str,
    ocr: dict[str, Any] | None,
) -> dict[str, bool]:
    readme = workspace / "README.md"
    saved_as = workspace / "saved-as.md"
    symlink = workspace / "README-link.md"
    config = workspace / "docs" / "config.yaml"
    active = active_tab(session)
    common = {
        "foregroundPhaseCompleted": report_complete(report),
        "diagnosticSessionBoundToProfile": normalized_path(
            str(diagnostic.get("sessionPath", ""))
        ) == normalized_path(expected_session_path),
    }

    if stage == "markdown-save":
        expected_text = MARKDOWN_SAVED[len(BOM):].decode()
        return {
            **common,
            "latestMarkdownBytesReachedDisk": read_bytes(readme) == MARKDOWN_SAVED,
            "markdownBOMCRLFFinalNewlinePreserved": (
                read_bytes(readme).startswith(BOM)
                and b"\r\n" in read_bytes(readme)
                and read_bytes(readme).endswith(b"\r\n")
                and b"\n" not in read_bytes(readme).replace(b"\r\n", b"")
            ),
            "activeMarkdownTabCleanWithFreshBaseline": tab_state(
                active,
                path=readme,
                text=expected_text,
                dirty=False,
                baseline=MARKDOWN_SAVED,
                markdown=True,
            ),
            "activeBlockRemainedEditingAfterSave": (
                diagnostics_match(
                    diagnostic,
                    document="README.md",
                    mode="edit",
                    dirty=False,
                    expected_session_path=expected_session_path,
                )
                and markdown_editor_visible(diagnostic, "paragraph")
            ),
        }
    if stage == "table-save":
        expected_text = TABLE_SAVED.decode()
        return {
            **common,
            "latestTableCellReachedDisk": read_bytes(readme) == TABLE_SAVED,
            "tableFinalNewlineAbsencePreserved": not read_bytes(readme).endswith(b"\n"),
            "activeTableTabCleanWithFreshBaseline": tab_state(
                active,
                path=readme,
                text=expected_text,
                dirty=False,
                baseline=TABLE_SAVED,
                markdown=True,
            ),
            "activeTableCellRemainedEditingAfterSave": (
                diagnostics_match(
                    diagnostic,
                    document="README.md",
                    mode="edit",
                    dirty=False,
                    expected_session_path=expected_session_path,
                )
                and markdown_editor_visible(diagnostic, "table")
                and diagnostic.get("activeTableCell") == {"row": 1, "column": 1}
            ),
        }
    if stage == "conflict-open":
        expected_text = CONFLICT_BASELINE.decode()
        return {
            **common,
            "conflictFixtureOpenedClean": tab_state(
                active,
                path=readme,
                text=expected_text,
                dirty=False,
                baseline=CONFLICT_BASELINE,
                markdown=True,
            ),
            "diskStillMatchesOpenBaseline": read_bytes(readme) == CONFLICT_BASELINE,
            "openDiagnosticIsCurrentMarkdown": diagnostics_match(
                diagnostic,
                document="README.md",
                mode="edit",
                dirty=False,
                expected_session_path=expected_session_path,
            ),
        }
    if stage == "conflict-save":
        return {
            **common,
            "externalBytesNotOverwritten": read_bytes(readme) == CONFLICT_EXTERNAL,
            "draftAndOriginalBaselineRetained": tab_state(
                active,
                path=readme,
                text=CONFLICT_DRAFT_TEXT,
                dirty=True,
                baseline=CONFLICT_BASELINE,
                markdown=True,
            ),
            "activeEditorAndDirtySurvivedConflict": (
                diagnostics_match(
                    diagnostic,
                    document="README.md",
                    mode="edit",
                    dirty=True,
                    expected_session_path=expected_session_path,
                )
                and markdown_editor_visible(diagnostic, "paragraph")
            ),
            "visibleConflictFeedbackRecorded": ocr_contains(ocr, ("磁盘上", "未覆盖")),
        }
    if stage == "save-as-new":
        return {
            **common,
            "originalExternalFileUnchanged": read_bytes(readme) == CONFLICT_EXTERNAL,
            "saveAsWroteLatestDraft": read_bytes(saved_as) == CONFLICT_DRAFT_TEXT.encode(),
            "saveAsTabCleanWithNewBaseline": tab_state(
                active,
                path=saved_as,
                text=CONFLICT_DRAFT_TEXT,
                dirty=False,
                baseline=CONFLICT_DRAFT_TEXT.encode(),
                markdown=True,
            ),
            "saveAsDiagnosticMovedToNewDocument": diagnostics_match(
                diagnostic,
                document="saved-as.md",
                mode="edit",
                dirty=False,
                expected_session_path=expected_session_path,
            ),
        }
    if stage in {"conflict-save-as-current", "conflict-save-as-symlink"}:
        return {
            **common,
            "canonicalConflictTargetNotOverwritten": read_bytes(readme) == CONFLICT_EXTERNAL,
            "draftAndOriginalBaselineStillRetained": tab_state(
                active,
                path=readme,
                text=CURRENT_CONFLICT_DRAFT_TEXT,
                dirty=True,
                baseline=CONFLICT_BASELINE,
                markdown=True,
            ),
            "symlinkStillResolvesToOriginal": (
                symlink.is_symlink()
                and normalized_path(str(symlink)) == normalized_path(str(readme))
            ),
            "canonicalConflictDiagnosticStayedDirty": diagnostics_match(
                diagnostic,
                document="README.md",
                mode="edit",
                dirty=True,
                expected_session_path=expected_session_path,
            ),
            "visibleConflictFeedbackRecorded": ocr_contains(ocr, ("磁盘上", "未覆盖")),
        }
    if stage == "session-draft":
        return {
            **common,
            "sessionDraftNotWrittenBeforeTermination": read_bytes(readme) == SESSION_BASELINE,
            "dirtySessionRetainsDraftAndOriginalBaseline": tab_state(
                active,
                path=readme,
                text=SESSION_DRAFT_TEXT,
                dirty=True,
                baseline=SESSION_BASELINE,
                markdown=True,
            ),
            "sessionDraftDiagnosticStayedDirty": diagnostics_match(
                diagnostic,
                document="README.md",
                mode="edit",
                dirty=True,
                expected_session_path=expected_session_path,
            ),
        }
    if stage == "restored-conflict-save":
        return {
            **common,
            "restoredConflictDidNotOverwriteExternalBytes": (
                read_bytes(readme) == SESSION_EXTERNAL
            ),
            "restoredDraftAndOriginalBaselineRetained": tab_state(
                active,
                path=readme,
                text=SESSION_DRAFT_TEXT,
                dirty=True,
                baseline=SESSION_BASELINE,
                markdown=True,
            ),
            "restoredActiveEditorStayedDirty": (
                diagnostics_match(
                    diagnostic,
                    document="README.md",
                    mode="edit",
                    dirty=True,
                    expected_session_path=expected_session_path,
                )
                and markdown_editor_visible(diagnostic, "paragraph")
            ),
            "visibleConflictFeedbackRecorded": ocr_contains(ocr, ("磁盘上", "未覆盖")),
        }
    if stage == "plain-open-diagnostic":
        inactive = tab_for_path(session, readme)
        return {
            **common,
            "plainSourceOpenedWithoutEditing": tab_state(
                active,
                path=config,
                text=PLAIN_BASELINE[len(BOM):].decode(),
                dirty=False,
                baseline=PLAIN_BASELINE,
                markdown=False,
            ),
            "stateJSONImmediatelyNamesPlainSource": diagnostics_match(
                diagnostic,
                document="config.yaml",
                mode="source",
                dirty=False,
                expected_session_path=expected_session_path,
            ),
            "inactiveDirtyMarkdownDraftStillPresent": tab_state(
                inactive,
                path=readme,
                text=SESSION_DRAFT_TEXT,
                dirty=True,
                baseline=SESSION_BASELINE,
                markdown=True,
            ),
            "inactiveMarkdownDidNotOverwriteDiagnostic": diagnostic.get("document") == "config.yaml",
            "visibleHUDImmediatelyNamesPlainSource": ocr_contains(
                ocr,
                ("doc=config.yaml", "mode=source"),
            ),
        }
    if stage == "plain-save":
        return {
            **common,
            "latestPlainSourceReachedDisk": read_bytes(config) == PLAIN_SAVED,
            "plainSourceBOMCRLFFinalNewlinePreserved": (
                read_bytes(config).startswith(BOM)
                and read_bytes(config).endswith(b"\r\n")
                and b"\n" not in read_bytes(config).replace(b"\r\n", b"")
            ),
            "plainSourceTabCleanWithFreshBaseline": tab_state(
                active,
                path=config,
                text=PLAIN_SAVED[len(BOM):].decode(),
                dirty=False,
                baseline=PLAIN_SAVED,
                markdown=False,
            ),
            "plainSourceDiagnosticStayedCurrentAfterSave": diagnostics_match(
                diagnostic,
                document="config.yaml",
                mode="source",
                dirty=False,
                expected_session_path=expected_session_path,
            ),
        }
    raise AssertionError(f"unhandled stage: {stage}")


def main() -> None:
    args = parse_args()
    session_path, session = load_object(args.session, "--session")
    diagnostic_path, diagnostic = load_object(args.diagnostic, "--diagnostic")
    report_path, report = load_object(args.foreground_report, "--foreground-report")
    workspace = require_directory(args.workspace_root, "--workspace-root")
    output_root = require_directory(args.output_root, "--output-root")
    expected_session_path = normalized_path(args.expected_session_path)
    ocr_path: pathlib.Path | None = None
    ocr: dict[str, Any] | None = None
    if args.ocr:
        ocr_path, ocr = load_object(args.ocr, "--ocr")

    assertions = build_assertions(
        stage=args.stage,
        session=session,
        diagnostic=diagnostic,
        report=report,
        workspace=workspace,
        expected_session_path=expected_session_path,
        ocr=ocr,
    )
    failed = [name for name, passed in assertions.items() if passed is not True]
    if failed:
        raise SystemExit(
            f"save lifecycle {args.stage} mismatch: {', '.join(failed)}"
        )
    if args.check_only:
        return

    active = active_tab(session)
    evidence_paths = {
        "session": os.path.relpath(session_path, output_root),
        "diagnostic": os.path.relpath(diagnostic_path, output_root),
        "foregroundReport": os.path.relpath(report_path, output_root),
        "ocr": os.path.relpath(ocr_path, output_root) if ocr_path else None,
    }
    print(json.dumps({
        "label": f"foreground-save-lifecycle-{args.stage}-{args.report_kind}",
        "stage": args.stage,
        "assertions": assertions,
        "activeDocument": {
            "name": active.get("name"),
            "url": active.get("url"),
            "dirty": active.get("isDirty"),
            "isMarkdown": active.get("isMarkdown"),
        },
        "diskSHA256": {
            relative: hashlib.sha256(read_bytes(path)).hexdigest()
            for relative, path in {
                "README.md": workspace / "README.md",
                "docs/config.yaml": workspace / "docs" / "config.yaml",
            }.items()
            if path.exists()
        },
        "evidence": evidence_paths,
    }, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
