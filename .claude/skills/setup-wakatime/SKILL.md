---
name: setup-wakatime
description: Set up WakaTime time-tracking for Claude Code and VS Code.
user_invocable: true
browser_safe: false
routing:
  executor: sonnet
  deterministic: false
---

# Setup WakaTime Time Tracking

Автоматическая настройка WakaTime для отслеживания рабочего времени.

## Что устанавливается

1. **wakatime-cli** — CLI для отправки heartbeat'ов
2. **Две авторизации** — API-ключ на отправку активности, личный OAuth-токен на чтение статистики (с 01.11.2026 ключ статистику не отдаёт)
3. **Хук Claude Code** — автоматический трекинг при работе с Claude (категория "AI Coding")
4. **WakaTime Desktop App** (опционально) — трекинг фокуса окна (чтение, браузер)

## Инструкция для Claude

Выполни шаги последовательно. На каждом шаге проверяй, не сделано ли уже.

### Шаг 1: wakatime-cli

```bash
# Проверить наличие (маска, не точное имя — issue #1151: расширение VS Code
# на Windows скачивает бинарь как wakatime-cli-windows-amd64.exe)
ls ~/.wakatime/wakatime-cli* 2>/dev/null || wakatime-cli --version 2>/dev/null
```

Если не установлен — путь зависит от ОС:

**macOS:**
```bash
brew install wakatime-cli
mkdir -p ~/.wakatime
ln -sf $(which wakatime-cli) ~/.wakatime/wakatime-cli
```

**Windows (issue #1151):** нет пакетного менеджера для прямой установки CLI.
Поставь расширение WakaTime для VS Code (Extensions → WakaTime) — оно само
скачивает бинарь в `~/.wakatime/wakatime-cli-windows-amd64.exe` при первом
запуске. Дальше шаги 2-4 работают как есть: скрипты шаблона ищут файл по
маске `wakatime-cli*`, не по точному имени. Альтернатива без WakaTime вообще:
ActivityWatch через `extensions/day-close.before.*.md` (см. README расширения).

**Linux:** см. https://wakatime.com/plugins — пакет под дистрибутив или
скачать бинарь вручную в `~/.wakatime/wakatime-cli`.

### Шаг 2: Две авторизации — ключ на запись, токен на чтение

С 01.11.2026 WakaTime развёл две роли, и они не взаимозаменяемы:

| Роль | Чем | Где |
|---|---|---|
| Отправка heartbeat'ов | API-ключ `waka_...` | `~/.wakatime.cfg` → `[settings] api_key` |
| Чтение статистики (summaries, «сколько сегодня») | личный OAuth-токен | `~/.wakatime/oauth_token`, chmod 600 |

Ключ стал write-only: на любой запрос статистики сервер отвечает
`403 {"error": "API Keys are only for plugins, use your personal oauth token"}`.
Отсюда типичный симптом — отправка работает, а `wakatime-cli --today` отдаёт пустой
stdout с exit=0 и счётчики времени показывают «0 min» / `WAKATIME_UNAVAILABLE`.
Поэтому `--today` больше не годится ни как тест, ни как источник цифры.

**2a. API-ключ (нужен только для отправки).** Если файла нет или в нём нет `api_key`:
1. Скажи пользователю: «Нужен WakaTime API-ключ. Получи его на https://wakatime.com/settings/api-key (нужна регистрация). **Не присылай ключ мне в чат** — платформа всё равно блокирует печать секретов в сессии (`secret-leak-block.sh`), а ключ лишний раз попадёт в историю разговора. Вместо этого выполни сам в терминале (замени `<ключ>` на свой):»
```bash
mkdir -p ~/.wakatime 2>/dev/null; cat > ~/.wakatime.cfg <<'EOF'
[settings]
api_key = <ключ>
EOF
```
2. Дождись, когда пользователь скажет, что выполнил
3. Проверь наличие ключа без вывода самого значения: `test -s ~/.wakatime.cfg && grep -q '^api_key' ~/.wakatime.cfg && echo "ключ на месте"`

**2b. OAuth-токен (нужен для чтения статистики).** Проверь: `test -s ~/.wakatime/oauth_token && echo "токен на месте"`.
Если токена нет:
1. Скажи пользователю: «Открой https://wakatime.com/oauth, войди в свой аккаунт и скопируй личный токен — приложение регистрировать не нужно. В чат его не присылай. В своём терминале выполни:»
```bash
read -rsp "Token: " T && printf '%s\n' "$T" > ~/.wakatime/oauth_token && chmod 600 ~/.wakatime/oauth_token
```
2. Проверь токен сам, без вывода значения:
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(cat ~/.wakatime/oauth_token)" \
  https://api.wakatime.com/api/v1/users/current   # ожидается 200
```
3. Токен отзывается и перевыпускается на той же странице; замена файла не влияет на отправку heartbeat'ов.

### Шаг 3: Хук-скрипт

Этот хук не входит в поставку шаблона (снят с платформы в v0.34 — user-installed hook only, issue #215): создай файл напрямую с этим содержимым, не копируй из репозитория.
```bash
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/wakatime-heartbeat.sh << 'EOF'
#!/bin/bash
# Claude Code → WakaTime heartbeat hook
# Sends heartbeats to track AI coding time per project.
# Events: UserPromptSubmit, PostToolUse, Stop

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Detect project from git or folder name
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PROJECT=$(cd "$CWD" && git config --local remote.origin.url 2>/dev/null | sed 's#.*/\([^.]*\)#\1#;s#\.git$##')
  PROJECT=${PROJECT:-$(basename "$CWD")}
else
  PROJECT="Unknown"
fi

# Category based on event/tool
CATEGORY="ai coding"
if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL" in
    WebSearch|WebFetch) CATEGORY="researching" ;;
    Read|Grep|Glob)    CATEGORY="code reviewing" ;;
    Edit|Write)        CATEGORY="coding" ;;
  esac
fi

# Resolve the CLI binary by mask, not exact name — issue #1151: the VS Code
# WakaTime extension on Windows downloads it as wakatime-cli-windows-amd64.exe.
WAKATIME_CLI=$(ls -d "$HOME"/.wakatime/wakatime-cli* 2>/dev/null | head -1)
[ -z "$WAKATIME_CLI" ] && exit 0

# Send heartbeat in background (non-blocking, silent)
("$WAKATIME_CLI" \
  --entity-type app \
  --entity "Claude Code" \
  --category "$CATEGORY" \
  --project "$PROJECT" \
  --plugin "claude-code-wakatime/0.1.0" \
  --write \
  >/dev/null 2>&1 &)

exit 0
EOF
chmod +x ~/.claude/hooks/wakatime-heartbeat.sh
```

### Шаг 4: Настройка хуков в settings.json

Прочитай `~/.claude/settings.json`. Добавь в секцию `hooks` (не затирая существующие хуки):

- **UserPromptSubmit** — добавь hook group:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh"}]}
  ```
- **PostToolUse** — добавь:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```
- **Stop** — добавь:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```

### Шаг 5: WakaTime Desktop App (только macOS — спроси пользователя)

На Windows/Linux нет `brew`-эквивалента в этом шаге — пропусти его молча
(ActivityWatch из шага 1 уже закрывает трекинг фокуса окна там, где нужен).

Спроси: «Установить WakaTime Desktop App? Он трекает время фокуса окна (когда читаешь ответы, работаешь в браузере). Требует Accessibility-разрешение в macOS.»

Если да:
```bash
brew install --cask wakatime
open -a WakaTime
```
Скажи: «Разреши Accessibility доступ в System Settings → Privacy & Security → Accessibility.»

### Шаг 6: Тест

```bash
echo '{"cwd": "'$(pwd)'", "hook_event_name": "UserPromptSubmit", "prompt": "test"}' | ~/.claude/hooks/wakatime-heartbeat.sh
sleep 3
# Отправка: heartbeat принят (ошибок в ~/.wakatime/wakatime.log нет)
# Чтение: только по OAuth-токену — wakatime-cli --today по ключу отдаёт 403 и пустой stdout
WAKA_TZ='Europe/Moscow'   # таймзона аккаунта WakaTime: по ней сервис нарезает сутки
D=$(TZ="$WAKA_TZ" date +%Y-%m-%d)
curl -s -H "Authorization: Bearer $(cat ~/.wakatime/oauth_token)" \
  "https://api.wakatime.com/api/v1/users/current/summaries?start=$D&end=$D" \
  | python3 -c "import sys,json; g=json.load(sys.stdin)['data'][0]['grand_total']; print(g['text'] if g['total_seconds'] else '0 min')"
```

Если строка времени пустая или `0 min` — это может быть честный ноль (свежий heartbeat
появляется в статистике с задержкой 5-15 минут), а не обязательно поломка. Признак
поломки — HTTP 403 или `WAKATIME_UNAVAILABLE` в выводе.

Покажи результат пользователю. Скажи: «Хуки подхватятся при следующем запуске Claude Code (хуки загружаются при старте сессии).»

### Шаг 7: Итог

Покажи таблицу:

| Компонент | Статус |
|-----------|--------|
| wakatime-cli | ✅/❌ |
| API key (только отправка) | ✅/❌ |
| OAuth-токен (чтение статистики) | ✅/❌ |
| Хук-скрипт | ✅/❌ |
| Хуки в settings.json | ✅/❌ |
| Desktop App | ✅/❌/пропущен |
| Тест heartbeat | ✅/❌ |

Скажи: «Дашборд: https://wakatime.com/dashboard. Данные появятся через 5-15 минут.»
