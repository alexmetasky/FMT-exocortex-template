#!/usr/bin/env python3
"""Remove denied MCP server sections from a Codex config.toml.

The peer adapter copies the writer's config into a private Codex home. By
default every MCP server stays available; a caller can disable selected servers
with --deny, or all servers with --deny "*".

Usage:
  peer-mcp-deny.py --config PATH [--deny "iwe,tilda"]
  peer-mcp-deny.py --config PATH --deny "*"   # disable every server

Exit codes:
  0 — OK
  2 — invalid config or denylist (config is left untouched)
"""

import argparse
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


class DenyError(Exception):
    """Raised when the config cannot be filtered safely."""


HEADER_RE = re.compile(r"^\s*\[\[?\s*mcp_servers\s*(?P<rest>\.[^\]\n]*)?\s*\]")
TOP_LEVEL_MCP_RE = re.compile(r"^\s*mcp_servers\s*(?:=|\.)")


def parse_server_name(rest: str) -> str:
    """Extract the server name from the part after ``mcp_servers``."""
    if not rest.startswith("."):
        raise DenyError(f"unsupported mcp_servers section header: {rest!r}")
    value = rest[1:].lstrip()
    if not value:
        raise DenyError("empty MCP server name in section header")
    if value.startswith('"'):
        end = value.find('"', 1)
        if end < 0:
            raise DenyError("unterminated quoted MCP server name")
        return value[1:end]
    return value.split(".", 1)[0].strip()


def parse_denylist(raw: str) -> set[str]:
    return {part.strip() for part in raw.split(",") if part.strip()}


def filter_config(text: str, denied: set[str], deny_all: bool):
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    defined: set[str] = set()
    current_server: str | None = None
    keep_current = True
    seen_section = False
    bare_section_has_content = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            seen_section = True
            match = HEADER_RE.match(line)
            if match:
                rest = match.group("rest") or ""
                if not rest:
                    current_server = None
                    keep_current = False
                    continue
                current_server = parse_server_name(rest)
                defined.add(current_server)
                keep_current = not (deny_all or current_server in denied)
                if keep_current:
                    output.append(line)
                continue

            current_server = None
            keep_current = True
            output.append(line)
            continue

        if not seen_section and TOP_LEVEL_MCP_RE.match(line):
            raise DenyError(
                "inline mcp_servers table is not supported; "
                "define servers as [mcp_servers.<name>] sections"
            )

        if current_server is None and keep_current is False:
            if stripped and not stripped.startswith("#"):
                bare_section_has_content = True
            continue

        if keep_current:
            output.append(line)

    if bare_section_has_content:
        raise DenyError(
            "bare [mcp_servers] table is not supported; "
            "define servers as [mcp_servers.<name>] sections"
        )

    if not deny_all:
        unknown = denied - defined
        if unknown:
            raise DenyError(
                "unknown MCP server(s) in denylist: "
                + ", ".join(sorted(unknown))
            )

    return "".join(output), defined


def write_atomic(path: Path, text: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, tmp_name = tempfile.mkstemp(
        dir=path.parent, prefix=path.name + ".", text=True
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Remove denied MCP server sections from a Codex config."
    )
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument(
        "--deny",
        default="",
        help='comma-separated server names; "*" disables all; empty keeps all',
    )
    args = parser.parse_args()

    try:
        text = args.config.read_text(encoding="utf-8")
        denied = parse_denylist(args.deny)
        deny_all = "*" in denied
        if deny_all:
            denied.discard("*")
        filtered, defined = filter_config(text, denied, deny_all)
        write_atomic(args.config, filtered)
    except (OSError, UnicodeError, DenyError) as exc:
        print(f"ERROR: MCP denylist failed: {exc}", file=sys.stderr)
        return 2

    if not defined:
        print("MCP denylist: no MCP servers found", file=sys.stderr)
    elif deny_all:
        print(
            f"MCP denylist: disabled all {len(defined)} MCP server(s)",
            file=sys.stderr,
        )
    else:
        kept = sorted(defined - denied)
        print(
            f"MCP denylist: kept {len(kept)} of {len(defined)} "
            f"server(s): {', '.join(kept) or 'none'}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
