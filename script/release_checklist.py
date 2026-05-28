#!/usr/bin/env python3
"""Generate AutoComp's per-build release checklist."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import re
import sys
from pathlib import Path
from xml.etree import ElementTree


SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate AutoComp release checklist Markdown.")
    parser.add_argument("--output", required=True, help="Path for release-checklist.md")
    parser.add_argument("--output-dir", required=True, help="Release artifact directory")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--mode", choices=["dry-run", "release"], required=True)
    parser.add_argument("--beta-gate-results", required=True)
    parser.add_argument("--app-bundle", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--release-notes-url", required=True)
    parser.add_argument("--sparkle-feed-url", default="")
    parser.add_argument("--sparkle-public-key", default="")
    parser.add_argument("--include-llama-runtime", action="store_true")
    parser.add_argument("--skip-notarize", action="store_true")
    parser.add_argument("--skip-appcast", action="store_true")
    parser.add_argument("--frameworks-dir", required=True)
    parser.add_argument("--enforce-blockers", action="store_true")
    return parser.parse_args()


def read_beta_gate(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []

    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def beta_status(rows: list[dict[str, str]]) -> tuple[str, str]:
    if not rows:
        return "NOT_AVAILABLE", "No beta-gate-results.tsv found for this output directory."
    if any(row.get("status") == "FAILED" for row in rows):
        failed = sum(1 for row in rows if row.get("status") == "FAILED")
        return "FAILED", f"{failed} beta gate row(s) failed."
    if any(row.get("status") == "SKIPPED" for row in rows):
        skipped = sum(1 for row in rows if row.get("status") == "SKIPPED")
        return "PASSED_WITH_SKIPS", f"{skipped} conditional beta gate row(s) skipped with structured reasons."
    return "PASSED", f"{len(rows)} beta gate row(s) passed."


def find_row(rows: list[dict[str, str]], row_id: str) -> dict[str, str] | None:
    return next((row for row in rows if row.get("id") == row_id), None)


def row_status(rows: list[dict[str, str]], row_id: str, missing_note: str) -> tuple[str, str, str]:
    row = find_row(rows, row_id)
    if row is None:
        return "NOT_AVAILABLE", "n/a", missing_note
    return row.get("status", "UNKNOWN"), row.get("evidence", "n/a"), row.get("note", "")


def qa_report_from_evidence(evidence: str) -> str:
    if not evidence or evidence == "n/a":
        return "n/a"
    path = Path(evidence)
    if not path.is_file():
        return "n/a"
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"(?:QA report|UI optional report):\s*(.+\.md)", text)
    if match:
        return match.group(1).strip()
    return "n/a"


def parse_appcast(path: Path, skip_appcast: bool) -> dict[str, str]:
    if skip_appcast:
        return {
            "status": "SKIPPED",
            "signature": "n/a",
            "length": "n/a",
            "url": "n/a",
            "note": "Appcast generation was skipped by release_build.sh.",
        }
    if not path.is_file():
        return {
            "status": "FAILED",
            "signature": "missing",
            "length": "missing",
            "url": "missing",
            "note": "appcast.xml was not generated.",
        }

    root = ElementTree.parse(path).getroot()
    enclosure = root.find(".//enclosure")
    if enclosure is None:
        return {
            "status": "FAILED",
            "signature": "missing",
            "length": "missing",
            "url": "missing",
            "note": "appcast.xml has no enclosure.",
        }

    signature = enclosure.attrib.get(f"{SPARKLE_NS}edSignature", "")
    length = enclosure.attrib.get("length", "")
    url = enclosure.attrib.get("url", "")
    if not signature or not length or not url:
        return {
            "status": "FAILED",
            "signature": signature or "missing",
            "length": length or "missing",
            "url": url or "missing",
            "note": "appcast.xml is missing Sparkle signature metadata.",
        }

    return {
        "status": "PASSED",
        "signature": signature,
        "length": length,
        "url": url,
        "note": "Appcast includes archive length, URL, and Ed25519 signature metadata.",
    }


def llama_status(frameworks_dir: Path, include_runtime: bool, mode: str) -> tuple[str, str, str]:
    if not include_runtime:
        return "NOT_APPLICABLE", "n/a", "Local llama runtime was not requested for this release build."
    if mode == "dry-run":
        return "PLANNED", str(frameworks_dir), "Dry run plans bundled libllama/libggml validation."

    dylibs = sorted(path.name for path in frameworks_dir.glob("lib*.dylib") if path.name.startswith(("libllama", "libggml")))
    if not dylibs:
        return "FAILED", str(frameworks_dir), "No bundled libllama/libggml dylibs were found."
    return "PASSED", str(frameworks_dir), ", ".join(dylibs)


def release_step_status(mode: str, skipped: bool = False) -> str:
    if skipped:
        return "SKIPPED"
    if mode == "dry-run":
        return "PLANNED"
    return "PASSED"


def multi_suggestion_status() -> tuple[str, str, str]:
    enabled_values = {"1", "true", "yes", "on"}
    legacy_value = os.environ.get("AUTOCOMP_MULTI_SUGGESTION_ENABLED", "")
    debug_value = os.environ.get("AUTOCOMP_DEBUG_MULTI_SUGGESTION_ENABLED", "")
    enabled = debug_value.lower() in enabled_values or legacy_value.lower() in enabled_values
    if enabled:
        return (
            "ENABLED_FOR_TESTING",
            "AUTOCOMP_DEBUG_MULTI_SUGGESTION_ENABLED",
            "Multi-suggestion popup was explicitly enabled for this checklist environment.",
        )
    return (
        "DISABLED_BY_DEFAULT",
        "CompletionBackendSettings.defaultMultiSuggestionEnabled",
        "Multi-suggestion popup remains off for beta QA unless a debug/internal flag enables it.",
    )


def markdown_row(area: str, status: str, evidence: str, note: str) -> str:
    safe_note = note.replace("\n", " ")
    return f"| {area} | {status} | `{evidence}` | {safe_note} |"


def build_checklist(args: argparse.Namespace) -> tuple[str, list[str]]:
    output = Path(args.output)
    output_dir = Path(args.output_dir)
    beta_gate_results = Path(args.beta_gate_results)
    app_bundle = Path(args.app_bundle)
    dmg = Path(args.dmg)
    appcast = Path(args.appcast)
    frameworks_dir = Path(args.frameworks_dir)

    rows = read_beta_gate(beta_gate_results)
    beta_gate_status, beta_gate_note = beta_status(rows)
    headless_status, headless_evidence, headless_note = row_status(
        rows,
        "P0-#99-headless-ci",
        "No #106 beta gate headless row is available.",
    )
    ui_status, ui_evidence, ui_note = row_status(
        rows,
        "P0-#106-ui-smoke",
        "No #106 beta gate UI smoke row is available.",
    )
    qa_report = qa_report_from_evidence(ui_evidence)
    appcast_metadata = parse_appcast(appcast, args.skip_appcast)
    llama_runtime_status, llama_runtime_evidence, llama_runtime_note = llama_status(
        frameworks_dir,
        args.include_llama_runtime,
        args.mode,
    )
    multi_suggestion_check = multi_suggestion_status()

    notarization_status = release_step_status(args.mode, args.skip_notarize)
    appcast_status = appcast_metadata["status"] if args.mode == "release" else release_step_status(args.mode, args.skip_appcast)
    if args.mode == "dry-run" and args.skip_appcast:
        appcast_status = "SKIPPED"

    checklist_rows = [
        (
            "#106 beta gate",
            beta_gate_status,
            str(beta_gate_results) if beta_gate_results.exists() else "n/a",
            beta_gate_note,
        ),
        ("Swift test/headless gate", headless_status, headless_evidence, headless_note),
        ("UI smoke", ui_status, ui_evidence, ui_note),
        (
            "QA matrix/report",
            "AVAILABLE" if qa_report != "n/a" else "DOCUMENTED",
            f"Docs/AppQAMatrix.md; {qa_report}",
            "Real-app QA matrix plus latest beta-gate report path when available.",
        ),
        ("Multi-suggestion popup", *multi_suggestion_check),
        ("Local llama runtime bundling", llama_runtime_status, llama_runtime_evidence, llama_runtime_note),
        ("Codesign", release_step_status(args.mode), str(app_bundle), "codesign --verify --deep --strict is required before checklist generation."),
        ("Notarization", notarization_status, str(dmg), "Skipped only when --skip-notarize is explicit."),
        ("Stapling", notarization_status, str(dmg), "Stapled after successful notarization when notarization is enabled."),
        ("spctl", notarization_status, str(app_bundle), "Assesses the stapled app bundle when notarization is enabled."),
        ("Appcast", appcast_status, str(appcast), appcast_metadata["note"]),
    ]

    critical_failures = []
    for row in rows:
        if row.get("status") == "FAILED":
            critical_failures.append(f"Beta gate {row.get('id', 'unknown')} failed: {row.get('note', '')}")
    for area, status, _evidence, note in checklist_rows:
        if status == "FAILED":
            critical_failures.append(f"{area} failed: {note}")

    generated_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S %Z")
    llama_requested = "yes" if args.include_llama_runtime else "no"
    sparkle_public_key = args.sparkle_public_key or "not set"
    sparkle_feed_url = args.sparkle_feed_url or "not set"

    lines = [
        "# AutoComp Release Checklist",
        "",
        f"- Version: {args.version}",
        f"- Build: {args.build}",
        f"- Mode: {args.mode}",
        f"- Generated: {generated_at}",
        f"- Output directory: `{output_dir}`",
        f"- App bundle: `{app_bundle}`",
        f"- DMG: `{dmg}`",
        f"- Download URL: {args.download_url}",
        f"- Release notes URL: {args.release_notes_url}",
        f"- Local llama runtime bundled: {llama_requested}",
        "",
        "## Sparkle Metadata",
        "",
        f"- Feed URL: {sparkle_feed_url}",
        f"- Public key: `{sparkle_public_key}`",
        "- Private key: not recorded in checklist artifacts.",
        f"- Appcast path: `{appcast}`",
        f"- Appcast URL: {appcast_metadata['url']}",
        f"- Appcast archive length: {appcast_metadata['length']}",
        f"- Appcast Ed25519 signature: `{appcast_metadata['signature']}`",
        "",
        "## Checks",
        "",
        "| Area | Status | Evidence | Notes |",
        "| --- | --- | --- | --- |",
    ]
    lines.extend(markdown_row(*row) for row in checklist_rows)
    lines.extend(
        [
            "",
            "## Release Blockers",
            "",
        ]
    )
    if critical_failures:
        lines.extend(f"- {failure}" for failure in critical_failures)
    else:
        lines.append("- None recorded. Critical gate, signing, notarization, appcast, or bundling failures block a real release.")
    lines.append("")

    output.parent.mkdir(parents=True, exist_ok=True)
    rendered = "\n".join(lines)
    return rendered, critical_failures


def main() -> int:
    args = parse_args()
    rendered, critical_failures = build_checklist(args)
    Path(args.output).write_text(rendered, encoding="utf-8")

    if args.enforce_blockers and critical_failures:
        print("Release checklist blockers:", file=sys.stderr)
        for failure in critical_failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Generated release checklist: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
