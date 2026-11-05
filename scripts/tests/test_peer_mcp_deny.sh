#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER="$ROOT/FMT-exocortex-template/scripts/lib/peer-mcp-deny.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/config.toml" <<'EOF'
model = "gpt-6.1-terra"

[tui]
screen_reader_detection_done = true

[mcp_servers.iwe]
url = "https://example.invalid"

[mcp_servers.iwe.tools.agent_status_list]
approval_mode = "approve"

[mcp_servers.tilda]
url = "https://example.invalid"

[mcp_servers.tilda.env]
TOKEN = "x"

[mcp_servers_extra]
value = 1

[model_providers.deepseek]
name = "DeepSeek"
EOF
cp "$TMP/config.toml" "$TMP/original.toml"

python3 "$HELPER" --config "$TMP/config.toml" --deny tilda >/dev/null
python3 - "$TMP/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
assert set(config["mcp_servers"]) == {"iwe"}, config.get("mcp_servers")
assert config["tui"]["screen_reader_detection_done"] is True
assert config["mcp_servers_extra"]["value"] == 1
assert config["model_providers"]["deepseek"]["name"] == "DeepSeek"
PY

cp "$TMP/original.toml" "$TMP/config.toml"
python3 "$HELPER" --config "$TMP/config.toml" >/dev/null
python3 - "$TMP/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
assert set(config["mcp_servers"]) == {"iwe", "tilda"}, config.get("mcp_servers")
PY

cp "$TMP/original.toml" "$TMP/config.toml"
python3 "$HELPER" --config "$TMP/config.toml" --deny '*' >/dev/null
python3 - "$TMP/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
assert "mcp_servers" not in config, config.get("mcp_servers")
assert config["mcp_servers_extra"]["value"] == 1
PY

cp "$TMP/original.toml" "$TMP/config.toml"
cp "$TMP/config.toml" "$TMP/before.toml"
if python3 "$HELPER" --config "$TMP/config.toml" --deny missing >/dev/null 2>&1; then
  echo 'Unknown MCP server was accepted' >&2
  exit 1
fi
cmp -s "$TMP/config.toml" "$TMP/before.toml" || {
  echo 'Config changed after rejected denylist' >&2
  exit 1
}

cat > "$TMP/bare.toml" <<'EOF'
[mcp_servers]
foo = { command = "false" }
EOF
if python3 "$HELPER" --config "$TMP/bare.toml" >/dev/null 2>&1; then
  echo 'Inline mcp_servers table was accepted' >&2
  exit 1
fi

cat > "$TMP/bare-twice.toml" <<'EOF'
[mcp_servers]
foo = 1
[mcp_servers]
bar = 2
EOF
if python3 "$HELPER" --config "$TMP/bare-twice.toml" >/dev/null 2>&1; then
  echo 'Inline mcp_servers table was accepted after a second header' >&2
  exit 1
fi

cat > "$TMP/dotted.toml" <<'EOF'
mcp_servers.foo.command = "false"
EOF
if python3 "$HELPER" --config "$TMP/dotted.toml" >/dev/null 2>&1; then
  echo 'Dotted mcp_servers key was accepted' >&2
  exit 1
fi

cat > "$TMP/spaced.toml" <<'EOF'
[ mcp_servers . iwe ]
command = "false"

[ mcp_servers . side_effect ]
command = "false"
EOF
python3 "$HELPER" --config "$TMP/spaced.toml" --deny side_effect >/dev/null
python3 - "$TMP/spaced.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
assert set(config["mcp_servers"]) == {"iwe"}, config.get("mcp_servers")
PY

printf 'Проверка MCP denylist завершена\n'
