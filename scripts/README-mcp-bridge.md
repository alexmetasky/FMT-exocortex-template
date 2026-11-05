# MCP-мост без зависимости от Codex

Набор скриптов для прямого вызова MCP-серверов из shell. Нужен, потому что
в текущих сборках Codex инструменты MCP не доходят до модели при работе на
стороннем провайдере (DeepSeek): Codex заворачивает их в namespace-контейнер,
который такой провайдер не раскрывает (openai/codex issue #26234). Прямой
вызов обходит это ограничение и работает при любом провайдере модели.

## Файлы

- `mcp-call.py` — единый мост для всех серверов.
- `mcp-bridge-servers.json` — реестр серверов (новый MCP = одна запись).
- `iwe-mcp-call.py` — совместимая обёртка для IWE.

## Использование

```bash
python3 scripts/mcp-call.py servers
python3 scripts/mcp-call.py tools <server>
python3 scripts/mcp-call.py call <server> <tool> '<json-args>'
```

Примеры:

```bash
python3 scripts/mcp-call.py call iwe get_instructions '{"level":"experienced"}'
python3 scripts/mcp-call.py call iwe agent_status_update '{"agent":"codex","status":"working","task":"..."}'
python3 scripts/mcp-call.py call gdrive listSharedDrives '{}'
python3 scripts/mcp-call.py call google-calendar list-calendars '{}'
```

## Как добавить новый MCP

1. Зарегистрировать сервер в `~/.codex/config.toml` в `[mcp_servers.<name>]`,
   как обычно.
2. Добавить запись в `mcp-bridge-servers.json`:
   - локальный процесс — `{"kind": "stdio", "cmd": [...], "env": {...}}`;
   - удалённый HTTP — `{"kind": "http", "url": "...", "protocol": "...", "auth": "file", "token_file": "..."}`.
3. Токены держать только в `.secrets/`, в реестре указывать путь `token_file`,
   не сам токен.
4. Обновить таблицу статусов ниже.
5. Проверить: `mcp-call.py tools <name>` и один реальный вызов
   `mcp-call.py call <name> <tool> '{}'`.
6. Помнить: под OpenAI нативный `mcp__<name>__*` работает сам, под DeepSeek —
   только через этот мост.

## Статус серверов (проверено 2026-11-05)

| Сервер | Транспорт | Инструменты | Прямой вызов |
|---|---|---|---|
| iwe | http + OAuth | get_instructions, agent_status_*, knowledge_* | ✅ работает |
| tilda | http + токен | 278 | ✅ работает |
| gdrive | stdio | 120 | ✅ работает |
| google-calendar | stdio | 13 | ✅ работает |
| deepseek_search | stdio | search_web, fetch_page | ✅ работает |
| iwe-local-gateway | stdio | 5 (локи, статусы peer-агентов) | ✅ работает |

Локальные stdio-серверы и HTTP-серверы требуют сетевого доступа при самом
вызове (Google API, Aisystant, Tilda) — в песочнице это запрашивается
отдельно, как и любой другой сетевой запрос.

## Токены

- IWE: OAuth-токен берётся из `~/.codex/.credentials.json` и обновляется
  автоматически при близком истечении.
- Tilda: токен из `.secrets/tilda-mcp2.token`.
- Google: серверы сами управляют своим OAuth-токеном (кэш в
  `~/.config/google-drive-mcp/` и учётка `personal` у календаря).
