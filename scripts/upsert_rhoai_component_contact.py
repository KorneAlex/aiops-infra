#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Insert a component Slack routing entry into rhoai-component-data.yaml.

Preserves comments and grouping from the merge-request-18 layout:
  - `default` first
  - remaining entries grouped by slack_team_handle
  - within each group, components sorted alphabetically
  - `openshift-ai-devtestops-ic` last

Exit codes:
  0  entry added (file rewritten)
  2  entry already present with the same handle/channel
  1  error
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CATCH_ALL_HANDLE = "openshift-ai-devtestops-ic"
HANDLE_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
COMPONENT_KEY_RE = re.compile(r"^  ([A-Za-z0-9][A-Za-z0-9._-]*):\s*$")
GROUP_TITLE_RE = re.compile(r"^  # ([a-z0-9-]+)  \((\d+) components?\)\s*$")
RULE_LINE_RE = re.compile(r"^  # -{10,}\s*$")
HANDLE_FIELD_RE = re.compile(r"^    slack_team_handle:\s*(\S+)\s*$", re.MULTILINE)
CHANNEL_FIELD_RE = re.compile(r"^    slack_team_channel:\s*(\S+)\s*$", re.MULTILINE)


def normalize_handle(raw: str) -> str:
    value = (raw or "").strip()
    value = value.lstrip("@")
    if value.startswith("https://") and "/archives/" not in value:
        pass
    return value.lower()


def extract_known_handles(yaml_text: str) -> set[str]:
    handles: set[str] = set()
    for match in HANDLE_FIELD_RE.finditer(yaml_text):
        handles.add(match.group(1).strip())
    return handles


def _format_group_header(handle: str, count: int) -> str:
    noun = "component" if count == 1 else "components"
    return (
        "  # ---------------------------------------------------------------------------\n"
        f"  # {handle}  ({count} {noun})\n"
        "  # ---------------------------------------------------------------------------\n"
    )


def _format_entry(component_name: str, handle: str, channel: str | None) -> str:
    lines = [
        f"  {component_name}:\n",
        f"    slack_team_handle: {handle}\n",
    ]
    if channel:
        lines.append(f"    slack_team_channel: {channel}\n")
    return "".join(lines)


def _existing_entry(yaml_text: str, component_name: str) -> dict | None:
    pattern = re.compile(
        rf"^  {re.escape(component_name)}:\n"
        r"(    slack_team_handle: (\S+)\n)?"
        r"(    slack_team_channel: (\S+)\n)?",
        re.MULTILINE,
    )
    match = pattern.search(yaml_text)
    if not match:
        return None
    return {
        "handle": match.group(2) or "",
        "channel": match.group(4) or "",
    }


def _iter_group_titles(yaml_text: str) -> list[tuple[int, str, int]]:
    """Return (title_line_start, handle, count) for each standard group header."""
    lines = yaml_text.splitlines(keepends=True)
    offset = 0
    found: list[tuple[int, str, int]] = []
    for idx, line in enumerate(lines):
        title = GROUP_TITLE_RE.match(line.rstrip("\n"))
        if title and idx > 0 and RULE_LINE_RE.match(lines[idx - 1].rstrip("\n")):
            found.append((offset - len(lines[idx - 1]), title.group(1), int(title.group(2))))
        offset += len(line)
    return found


def _group_block_range(yaml_text: str, handle: str) -> tuple[int, int] | None:
    """Return (start, end) character offsets of a group's header+entries."""
    titles = _iter_group_titles(yaml_text)
    for index, (start, group_handle, _count) in enumerate(titles):
        if group_handle != handle:
            continue
        end = titles[index + 1][0] if index + 1 < len(titles) else len(yaml_text)
        return start, end
    return None


def _component_offsets_in_block(block: str) -> list[tuple[str, int]]:
    """Component name and offset within the group block (start of the key line)."""
    found: list[tuple[str, int]] = []
    offset = 0
    for line in block.splitlines(keepends=True):
        match = COMPONENT_KEY_RE.match(line.rstrip("\n"))
        if match and match.group(1) not in {"slack_team_handle", "slack_team_channel"}:
            found.append((match.group(1), offset))
        offset += len(line)
    return found


def upsert_component_contact(
    yaml_text: str,
    component_name: str,
    slack_team_handle: str,
    slack_team_channel: str | None = None,
) -> dict:
    if "\ncomponents:" not in yaml_text and not yaml_text.startswith("components:"):
        raise ValueError(
            "YAML does not contain a top-level 'components:' mapping "
            "(Merge Request 18 format is required)."
        )
    handle = normalize_handle(slack_team_handle)
    if not HANDLE_RE.match(handle):
        raise ValueError(
            f"Invalid slack_team_handle '{slack_team_handle}'. "
            "Use a lowercase Slack user-group handle such as ai-core-platform."
        )
    channel = (slack_team_channel or "").strip().lstrip("#") or None

    existing = _existing_entry(yaml_text, component_name)
    if existing is not None:
        same_handle = existing["handle"] == handle
        same_channel = (existing["channel"] or None) == channel
        if same_handle and same_channel:
            return {"status": "already_present", "text": yaml_text}
        raise ValueError(
            f"Component '{component_name}' already exists with "
            f"slack_team_handle={existing['handle']}"
            + (f", slack_team_channel={existing['channel']}" if existing["channel"] else "")
            + f" (requested handle={handle}"
            + (f", channel={channel}" if channel else "")
            + ")."
        )

    entry = _format_entry(component_name, handle, channel)
    group_range = _group_block_range(yaml_text, handle)
    if group_range is not None:
        start, end = group_range
        block = yaml_text[start:end]
        components = _component_offsets_in_block(block)
        insert_at = None
        for name, rel_offset in components:
            if name > component_name:
                insert_at = start + rel_offset
                break
        if insert_at is None:
            insert_at = end
            if not block.endswith("\n"):
                entry = "\n" + entry
        new_count = len(components) + 1
        header = _format_group_header(handle, new_count)
        # Replace the existing three-line header at the start of the block.
        header_end = block.find(components[0][0]) if components else len(block)
        # Find first component key line in the original text.
        if components:
            first_comp_abs = start + components[0][1]
            updated = yaml_text[:start] + header + yaml_text[first_comp_abs:insert_at] + entry + yaml_text[insert_at:]
        else:
            updated = yaml_text[:start] + header + entry + yaml_text[end:]
        return {"status": "added", "text": updated}

    # New group: insert alphabetically before catch-all (or before the first later group).
    titles = _iter_group_titles(yaml_text)
    insert_before = None
    catchall_start = None
    for start, group_handle, _count in titles:
        if group_handle == CATCH_ALL_HANDLE:
            catchall_start = start
            continue
        if group_handle != "default" and group_handle > handle and insert_before is None:
            insert_before = start
    if insert_before is None:
        insert_before = catchall_start if catchall_start is not None else len(yaml_text)
    if yaml_text and not yaml_text.endswith("\n"):
        yaml_text += "\n"
        if insert_before == len(yaml_text) - 1:
            insert_before = len(yaml_text)

    block = _format_group_header(handle, 1) + entry
    if insert_before < len(yaml_text) and yaml_text[:insert_before] and not yaml_text[:insert_before].endswith("\n\n"):
        if not yaml_text[:insert_before].endswith("\n"):
            block = "\n" + block
        elif not yaml_text[:insert_before].endswith("\n\n"):
            block = "\n" + block
    updated = yaml_text[:insert_before] + block + yaml_text[insert_before:]
    return {"status": "added", "text": updated}


def main() -> int:
    parser = argparse.ArgumentParser(description="Upsert a component Slack routing entry")
    parser.add_argument("file", help="Path to rhoai-component-data.yaml")
    parser.add_argument("--component-name", required=True)
    parser.add_argument("--slack-team-handle", required=True)
    parser.add_argument("--slack-team-channel", default="")
    args = parser.parse_args()

    path = Path(args.file)
    if not path.is_file():
        print(json.dumps({"error": f"File not found: {path}"}), file=sys.stderr)
        return 1

    try:
        result = upsert_component_contact(
            path.read_text(encoding="utf-8"),
            args.component_name,
            args.slack_team_handle,
            args.slack_team_channel or None,
        )
    except ValueError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1

    if result["status"] == "already_present":
        print(json.dumps({"status": "already_present"}))
        return 2

    path.write_text(result["text"], encoding="utf-8")
    print(json.dumps({"status": "added"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
