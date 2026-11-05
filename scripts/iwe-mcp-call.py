#!/usr/bin/env python3
"""Совместимая обёртка для IWE поверх mcp-call.py.

Оставлена для прежнего интерфейса:
  iwe-mcp-call.py get_instructions --level experienced
  iwe-mcp-call.py agent_status_update --agent codex --status idle --task "..."
  iwe-mcp-call.py agent_status_list
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MCP_CALL = HERE / "mcp-call.py"


def _run(tool: str, args: dict) -> None:
    proc = subprocess.run(
        [sys.executable, str(MCP_CALL), "call", "iwe", tool, json.dumps(args)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.exit(proc.returncode)
    sys.stdout.write(proc.stdout)


def main() -> None:
    parser = argparse.ArgumentParser(description="Прямой вызов Aisystant MCP (IWE)")
    sub = parser.add_subparsers(dest="command", required=True)
    gi = sub.add_parser("get_instructions")
    gi.add_argument("--level", default="experienced",
                    choices=["full", "compact", "experienced", "services"])
    update = sub.add_parser("agent_status_update")
    update.add_argument("--agent", required=True)
    update.add_argument("--status", required=True)
    update.add_argument("--task", default="")
    sub.add_parser("agent_status_list")
    raw = sub.add_parser("raw")
    raw.add_argument("tool")
    raw.add_argument("args")

    ns = parser.parse_args()
    if ns.command == "get_instructions":
        _run("get_instructions", {"level": ns.level})
    elif ns.command == "agent_status_update":
        _run("agent_status_update", {"agent": ns.agent, "status": ns.status, "task": ns.task})
    elif ns.command == "agent_status_list":
        _run("agent_status_list", {})
    else:
        _run(ns.tool, json.loads(ns.args))


if __name__ == "__main__":
    main()
