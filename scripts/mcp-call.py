#!/usr/bin/env python3
"""Единый мост к MCP-серверам без зависимости от встроенного моста Codex.

Обходит известное ограничение Codex: для сторонних провайдеров (DeepSeek)
инструменты MCP не доходят до модели (openai/codex #26234). Этот скрипт
вызывает серверы напрямую: локальные (stdio) и удалённые (HTTP), поэтому
работает из обычного shell при любом провайдере модели.

Список серверов хранится отдельно в mcp-bridge-servers.json: новый MCP —
это одна запись в реестре, без правок кода.

Использование:
  mcp-call.py servers                             # список известных серверов
  mcp-call.py tools <server>                      # список инструментов
  mcp-call.py call <server> <tool> '<json-args>'  # вызов инструмента
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REGISTRY_PATH = SCRIPT_DIR / "mcp-bridge-servers.json"
CRED_PATH = Path("/root/.codex/.credentials.json")
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Codex/1.0 Chrome/120.0 Safari/537.36"
)


def load_servers() -> dict:
    return json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))


# --- OAuth (iwe) ---------------------------------------------------------

def _iwe_cred() -> dict:
    data = json.loads(CRED_PATH.read_text(encoding="utf-8"))
    for key, value in data.items():
        if key.startswith("iwe|") and isinstance(value, dict):
            return value
    raise SystemExit("Не найден OAuth-креденшл iwe в .credentials.json")


def _persist_iwe(cred: dict) -> None:
    data = json.loads(CRED_PATH.read_text(encoding="utf-8"))
    for key, value in data.items():
        if key.startswith("iwe|") and isinstance(value, dict):
            data[key] = cred
            break
    else:
        raise SystemExit("Не найден ключ iwe для сохранения токена")
    fd, tmp = tempfile.mkstemp(prefix=".credentials-", dir=CRED_PATH.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, ensure_ascii=False, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, CRED_PATH)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _refresh_iwe(cred: dict) -> dict:
    payload = {
        "grant_type": "refresh_token",
        "refresh_token": cred["refresh_token"],
        "client_id": cred["client_id"],
        "scope": " ".join(cred.get("scopes", ["openid", "offline_access"])),
    }
    req = urllib.request.Request(
        "https://mcp.aisystant.com/token",
        data=urllib.parse.urlencode(payload).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            tokens = json.loads(resp.read().decode())
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Обновление токена iwe: HTTP {error.code}") from None
    cred["access_token"] = tokens["access_token"]
    cred["refresh_token"] = tokens.get("refresh_token", cred["refresh_token"])
    cred["expires_at"] = int(time.time() * 1000) + int(tokens.get("expires_in", 3600)) * 1000
    return cred


def _iwe_token() -> str:
    cred = _iwe_cred()
    if cred.get("expires_at", 0) <= int(time.time() * 1000) + 60_000:
        cred = _refresh_iwe(cred)
        _persist_iwe(cred)
    return cred["access_token"]


def _file_token(path: str) -> str:
    token = Path(path).read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit(f"Токен пуст: {path}")
    return token


# --- HTTP transport ------------------------------------------------------

def _http_request(payload: dict, cfg: dict, token: str, session: str | None = None) -> tuple[str, str | None]:
    headers = ["-H", f"Authorization: Bearer {token}",
               "-H", "Content-Type: application/json",
               "-H", "Accept: application/json, text/event-stream",
               "-H", f"User-Agent: {USER_AGENT}"]
    for name, value in cfg.get("extra_headers", {}).items():
        headers += ["-H", f"{name}: {value}"]
    if session:
        headers += ["-H", f"Mcp-Session-Id: {session}"]
    with tempfile.TemporaryDirectory() as tmp:
        hdr_path = os.path.join(tmp, "headers.txt")
        proc = subprocess.run(
            ["curl", "-sS", "-m", "60", "-D", hdr_path, *headers,
             "-d", json.dumps(payload), cfg["url"]],
            capture_output=True, text=True, timeout=90,
        )
        if proc.returncode != 0:
            raise SystemExit(proc.stderr.strip() or "curl вернул ошибку")
        sid = None
        if os.path.exists(hdr_path):
            for line in Path(hdr_path).read_text(encoding="utf-8").splitlines():
                if line.lower().startswith("mcp-session-id:"):
                    sid = line.split(":", 1)[1].strip()
        return proc.stdout, sid


def _http_token(cfg: dict) -> str:
    if cfg.get("auth") == "iwe-oauth":
        return _iwe_token()
    if cfg.get("auth") == "file":
        return _file_token(cfg["token_file"])
    raise SystemExit("Неизвестный тип авторизации")


def _http_call(cfg: dict, tool: str, args: dict) -> dict:
    token = _http_token(cfg)
    init = {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": cfg["protocol"], "capabilities": {},
                   "clientInfo": {"name": "codex", "version": "0.1.0"}},
    }
    body, sid = _http_request(init, cfg, token)
    payload = {
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": tool, "arguments": args},
    }
    body, _ = _http_request(payload, cfg, token, sid)
    return json.loads(body)


def _http_tools(cfg: dict) -> list[str]:
    token = _http_token(cfg)
    init = {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": cfg["protocol"], "capabilities": {},
                   "clientInfo": {"name": "codex", "version": "0.1.0"}},
    }
    body, sid = _http_request(init, cfg, token)
    payload = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
    body, _ = _http_request(payload, cfg, token, sid)
    data = json.loads(body)
    return [t.get("name") for t in data.get("result", {}).get("tools", [])]


# --- stdio transport -----------------------------------------------------

def _stdio(cfg: dict, method: str, params: dict | None, request_id: int) -> dict:
    env = dict(os.environ)
    env.update(cfg.get("env", {}))
    try:
        proc = subprocess.Popen(
            cfg["cmd"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=env,
        )
    except FileNotFoundError as error:
        raise SystemExit(f"Нет исполняемого файла: {error}") from None
    init = {
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "codex", "version": "0.1.0"}},
    }
    notif = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    req = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}
    try:
        out, err = proc.communicate(
            "\n".join(json.dumps(m) for m in (init, notif, req)) + "\n",
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        raise SystemExit(f"stdio таймаут: {err[:300]}") from None
    result = None
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if data.get("id") == request_id:
            result = data
    if result is None:
        raise SystemExit(f"Нет ответа от stdio-сервера; stderr: {err[:300]}")
    if "error" in result:
        raise SystemExit(json.dumps(result["error"], ensure_ascii=False))
    return result


def _stdio_tools(cfg: dict) -> list[str]:
    data = _stdio(cfg, "tools/list", None, 2)
    return [t.get("name") for t in data.get("result", {}).get("tools", [])]


def _stdio_call(cfg: dict, tool: str, args: dict) -> dict:
    return _stdio(cfg, "tools/call", {"name": tool, "arguments": args}, 2)


def _print_result(data: dict) -> None:
    content = data.get("result", {}).get("content", [])
    text = "\n".join(item.get("text", "") for item in content if item.get("type") == "text")
    if text:
        print(text)
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="Мост к MCP-серверам")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("servers")
    tools_p = sub.add_parser("tools")
    tools_p.add_argument("server")
    call_p = sub.add_parser("call")
    call_p.add_argument("server")
    call_p.add_argument("tool")
    call_p.add_argument("args")
    ns = parser.parse_args()

    servers = load_servers()
    if ns.command == "servers":
        for name, cfg in servers.items():
            print(f"{name}\t{cfg['kind']}")
        return

    cfg = servers.get(ns.server)
    if cfg is None:
        raise SystemExit(f"Неизвестный сервер: {ns.server}")
    if ns.command == "tools":
        names = _http_tools(cfg) if cfg["kind"] == "http" else _stdio_tools(cfg)
        print("\n".join(names))
    elif ns.command == "call":
        args = json.loads(ns.args) if ns.args else {}
        if not isinstance(args, dict):
            raise SystemExit("Аргументы должны быть JSON-объектом")
        data = _http_call(cfg, ns.tool, args) if cfg["kind"] == "http" else _stdio_call(cfg, ns.tool, args)
        _print_result(data)


if __name__ == "__main__":
    main()
