#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ADAPTER="$ROOT/FMT-exocortex-template/scripts/codex-peer-adapter.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/iwe/scripts" "$TMP/source" "$TMP/locks"
cp "$ROOT/scripts/codex-provider-switch.py" "$TMP/iwe/scripts/"
cat > "$TMP/source/config.toml" <<'EOF'
model = "gpt-6.1-sol"

[mcp_servers.iwe]
command = "false"

[mcp_servers.side_effect]
command = "false"
EOF
cp "$TMP/source/config.toml" "$TMP/source-config.expected"
printf 'test-auth' > "$TMP/source/auth.json"
cat > "$TMP/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$CODEX_HOME/config.toml" "$EXPECTED_PROVIDER" "$*" <<'PY'
import os, sys, tomllib
with open(sys.argv[1], 'rb') as stream:
    config = tomllib.load(stream)
provider = config.get('model_provider', 'openai')
assert provider == sys.argv[2], (provider, sys.argv[2])
if provider == 'deepseek':
    assert config['model'] == 'deepseek-flash'
else:
    assert config['model'] == 'gpt-6.1-sol'
expected_cli = os.environ.get('EXPECTED_CLI_MODEL', '')
if expected_cli:
    assert f' -m {expected_cli} ' in f' {sys.argv[3]} ', (sys.argv[3], expected_cli)
expected_mcp = {part for part in os.environ.get('EXPECTED_MCP', '').split(',') if part}
actual_mcp = set(config.get('mcp_servers', {}))
assert actual_mcp == expected_mcp, (actual_mcp, expected_mcp)
PY
[[ " $* " == *" -s read-only "* ]]
while (($#)); do
  if [[ "$1" == -o ]]; then printf 'Проверено\n' > "$2"; exit 0; fi
  shift
done
echo 'ERROR: -o flag not found' >&2
exit 1
EOF
chmod +x "$TMP/codex"
for provider in openai deepseek; do
  if [ "$provider" = openai ]; then
    expected_cli_model=gpt-6.1-terra
  else
    expected_cli_model=
  fi
  output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
    CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER="$provider" EXPECTED_PROVIDER="$provider" \
    EXPECTED_CLI_MODEL="$expected_cli_model" EXPECTED_MCP=iwe,side_effect \
    IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER")
  [[ "$output" == 'Проверено' ]]
done
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" EXPECTED_PROVIDER=openai EXPECTED_MCP=iwe,side_effect \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER")
[[ "$output" == 'Проверено' ]]
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" EXPECTED_PROVIDER=openai EXPECTED_MCP=iwe \
  CODEX_PEER_MCP_DENY=side_effect \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER")
[[ "$output" == 'Проверено' ]]
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=deepseek EXPECTED_PROVIDER=deepseek \
  EXPECTED_CLI_MODEL=deepseek-v4-pro EXPECTED_MCP=iwe,side_effect \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER" --model deepseek-v4-pro)
[[ "$output" == 'Проверено' ]]
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=openai EXPECTED_PROVIDER=openai \
  CODEX_PEER_MODEL=gpt-6.1-sol EXPECTED_CLI_MODEL=gpt-6.1-sol EXPECTED_MCP=iwe,side_effect \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER")
[[ "$output" == 'Проверено' ]]
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=openai EXPECTED_PROVIDER=openai \
  CODEX_PEER_MODEL=gpt-6.1-sol EXPECTED_CLI_MODEL=gpt-6.1-terra EXPECTED_MCP=iwe,side_effect \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER" --model gpt-6.1-terra)
[[ "$output" == 'Проверено' ]]
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=deepseek EXPECTED_PROVIDER=deepseek \
  EXPECTED_MCP=iwe CODEX_PEER_MCP_DENY=side_effect \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER")
[[ "$output" == 'Проверено' ]]
output=$(printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=deepseek EXPECTED_PROVIDER=deepseek \
  EXPECTED_MCP= CODEX_PEER_MCP_DENY='*' \
  IWE_PEER_LOCK_DIR="$TMP/locks" IWE_PEER_PLAIN=1 bash "$ADAPTER")
[[ "$output" == 'Проверено' ]]
cmp -s "$TMP/source/config.toml" "$TMP/source-config.expected"
if printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=unknown IWE_PEER_LOCK_DIR="$TMP/locks" \
  IWE_PEER_PLAIN=1 bash "$ADAPTER" >/dev/null 2>&1; then
  echo 'Unknown provider was accepted' >&2
  exit 1
fi
if printf 'Проверь образец' | CODEX_HOME="$TMP/source" IWE_ROOT="$TMP/iwe" \
  CODEX_BIN="$TMP/codex" CODEX_PEER_PROVIDER=openai IWE_PEER_LOCK_DIR="$TMP/locks" \
  IWE_PEER_PLAIN=1 bash "$ADAPTER" --model sonnet >/dev/null 2>&1; then
  echo 'Claude model was accepted by the codex adapter' >&2
  exit 1
fi
printf 'Проверка выбора поставщика завершена\n'
