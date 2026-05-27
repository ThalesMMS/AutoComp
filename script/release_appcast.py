#!/usr/bin/env python3
"""Generate one Sparkle appcast item for an AutoComp DMG."""

from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import re
import subprocess
import sys
from xml.sax.saxutils import escape


ED_SIGNATURE_PATTERN = re.compile(r'sparkle:edSignature="([^"]+)"')
LENGTH_PATTERN = re.compile(r'length="([^"]+)"')


def xml_escape(value: str) -> str:
    return escape(value, {'"': "&quot;"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate AutoComp's Sparkle appcast XML.")
    parser.add_argument("--version", required=True, help="Marketing version, for example 1.0.0")
    parser.add_argument("--build", required=True, help="Build number, for example 100")
    parser.add_argument("--archive", required=True, help="Path to the final notarized AutoComp.dmg")
    parser.add_argument("--download-url", required=True, help="Public URL for the DMG asset")
    parser.add_argument("--release-notes-url", required=True, help="Public URL for release notes")
    parser.add_argument("--output", required=True, help="Path for the generated appcast.xml")
    parser.add_argument("--sign-update-tool", default=None, help="Path to Sparkle's sign_update tool")
    parser.add_argument("--private-key-file", default=None, help="Optional Sparkle Ed25519 private key file")
    parser.add_argument("--dry-run", action="store_true", help="Render with placeholder signature data")
    return parser.parse_args()


def candidate_sign_update_paths(explicit_path: str | None) -> list[Path]:
    candidates: list[Path] = []
    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    env_override = os.environ.get("AUTOCOMP_SPARKLE_SIGN_UPDATE")
    if env_override:
        candidates.append(Path(env_override).expanduser())

    try:
        xcrun_result = subprocess.run(
            ["xcrun", "--find", "sign_update"],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        xcrun_result = None

    if xcrun_result is not None and xcrun_result.returncode == 0:
        candidates.append(Path(xcrun_result.stdout.strip()))

    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived_data.exists():
        candidates.extend(
            derived_data.glob("*/SourcePackages/artifacts/**/Sparkle/bin/sign_update")
        )

    local_cache = Path(".build/sparkle-release")
    if local_cache.exists():
        candidates.extend(local_cache.glob("**/bin/sign_update"))

    return candidates


def resolve_sign_update_tool(explicit_path: str | None) -> Path:
    for candidate in candidate_sign_update_paths(explicit_path):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()

    raise SystemExit(
        "Could not locate Sparkle sign_update. Pass --sign-update-tool or set "
        "AUTOCOMP_SPARKLE_SIGN_UPDATE."
    )


def sparkle_signature(
    archive: Path,
    sign_update_tool: str | None,
    private_key_file: str | None,
) -> tuple[str, str]:
    tool = resolve_sign_update_tool(sign_update_tool)
    command = [str(tool)]
    if private_key_file:
        key_path = Path(private_key_file).expanduser().resolve()
        if not key_path.is_file():
            raise SystemExit(f"Sparkle private key file not found: {key_path}")
        command.extend(["--ed-key-file", str(key_path)])
    command.append(str(archive))

    result = subprocess.run(command, check=True, capture_output=True, text=True)
    output = result.stdout.strip()
    signature_match = ED_SIGNATURE_PATTERN.search(output)
    length_match = LENGTH_PATTERN.search(output)
    if signature_match is None or length_match is None:
        raise SystemExit(f"Unexpected sign_update output:\n{output}")

    return signature_match.group(1), length_match.group(1)


def render_appcast(
    *,
    version: str,
    build: str,
    download_url: str,
    release_notes_url: str,
    archive_length: str,
    ed_signature: str,
) -> str:
    pub_date = dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AutoComp Updates</title>
    <link>{xml_escape(release_notes_url)}</link>
    <description>AutoComp release feed</description>
    <item>
      <title>AutoComp {xml_escape(version)}</title>
      <sparkle:releaseNotesLink>{xml_escape(release_notes_url)}</sparkle:releaseNotesLink>
      <pubDate>{xml_escape(pub_date)}</pubDate>
      <enclosure
        url="{xml_escape(download_url)}"
        sparkle:version="{xml_escape(build)}"
        sparkle:shortVersionString="{xml_escape(version)}"
        length="{xml_escape(archive_length)}"
        type="application/octet-stream"
        sparkle:edSignature="{xml_escape(ed_signature)}" />
    </item>
  </channel>
</rss>
"""


def main() -> int:
    args = parse_args()
    archive = Path(args.archive).expanduser().resolve()

    if args.dry_run:
        ed_signature = "dry-run-ed25519-signature"
        archive_length = "0"
    else:
        if not archive.is_file():
            raise SystemExit(f"Archive not found: {archive}")
        ed_signature, archive_length = sparkle_signature(
            archive,
            args.sign_update_tool,
            args.private_key_file,
        )

    rendered = render_appcast(
        version=args.version,
        build=args.build,
        download_url=args.download_url,
        release_notes_url=args.release_notes_url,
        archive_length=archive_length,
        ed_signature=ed_signature,
    )

    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    mode = "dry-run " if args.dry_run else ""
    print(f"Generated {mode}appcast: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
