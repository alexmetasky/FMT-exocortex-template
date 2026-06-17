#!/bin/bash
# Генерирует update-manifest.json из текущего содержимого репо.
# Запускать перед релизом: bash generate-manifest.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/update-manifest.json"

# Версия из CHANGELOG.md (первый ## [X.Y.Z])
VERSION=$(grep -m1 '^\#\# \[' "$SCRIPT_DIR/CHANGELOG.md" | sed 's/.*\[\(.*\)\].*/\1/')

if [ -z "$VERSION" ]; then
    echo "ERROR: Не удалось извлечь версию из CHANGELOG.md"
    exit 1
fi

echo "Генерация манифеста v$VERSION..."

# Файлы/директории, которые НЕ включаются в манифест обновлений
# seed/ — только при setup, README.md — пользователь кастомизирует,
# settings.local.json — персональный, .gitkeep — маркеры,
# extensions/*.after.md, extensions/*.before.md, extensions/*.checks.md, extensions/mcp-user.json —
# пользовательское пространство (update.sh явно не трогает, см. update.sh §"Не затрагивается")
EXCLUDE_PATTERNS=(
    "seed/"
    ".claude/settings.local.json"
    "generate-manifest.sh"
    "update-manifest.json"
    ".git/"
    ".DS_Store"
)

# Точные пути, которые НЕ обновляются через update.sh:
# README.md, README.en.md — витрина форка, пользователь кастомизирует под себя
# CONTRIBUTING.md — для контрибьюторов апстрима, не для пользователей
# LICENSE — юридический документ, форк может иметь свою лицензию
# params.yaml — пользовательские флаги протоколов (update.sh явно не трогает)
# extensions/day-close.after.md, extensions/mcp-user.json — пример/конфиг в пользовательском
#   пространстве extensions/; update.sh обещает «не трогать extensions/» (см. extensions/README.md)
EXCLUDE_EXACT=(
    "README.md"
    "README.en.md"
    "CONTRIBUTING.md"
    "LICENSE"
    "params.yaml"
    "extensions/day-close.after.md"
    "extensions/mcp-user.json"
)

# Собираем файлы.
# Источник: `git ls-files` — гарантирует, что в манифест попадут ТОЛЬКО tracked-файлы.
# .gitignore-файлы (.exocortex.env, .claude.md.base, .claude/logs/, settings.local.json)
# автоматически исключаются git'ом, что закрывает класс «runtime в манифесте» (WP-273 R4.1).
FILES=()
while IFS= read -r rel; do
    # Проверяем исключения
    skip=false
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*|*/$pattern*) skip=true; break ;;
        esac
    done

    # Пропускаем .gitkeep
    [[ "$(basename "$rel")" == ".gitkeep" ]] && skip=true

    # Точные совпадения (корневой README.md)
    for exact in "${EXCLUDE_EXACT[@]}"; do
        [ "$rel" = "$exact" ] && { skip=true; break; }
    done

    $skip && continue
    FILES+=("$rel")
done < <(git -C "$SCRIPT_DIR" ls-files | sort)

# Генерируем JSON
{
    echo '{'
    echo "  \"version\": \"$VERSION\","
    echo '  "description": "Манифест платформенных файлов FMT-exocortex-template. Используется update.sh для доставки обновлений.",'
    echo '  "files": ['

    last_idx=$(( ${#FILES[@]} - 1 ))
    for i in "${!FILES[@]}"; do
        f="${FILES[$i]}"
        comma=","
        [ "$i" -eq "$last_idx" ] && comma=""
        printf '    {"path": "%s"}%s\n' "$f" "$comma"
    done

    echo '  ]'
    echo '}'
} > "$MANIFEST"

# === Deprecated files (исторический список — поддерживается вручную) ===
# Каждая запись: path|reason
# Только L1-платформенные файлы, которые update.sh когда-то ставил, а потом удалил.
# update.sh удаляет их из установок пользователей при следующем обновлении.
DEPRECATED_LIST=(
    "LEARNING-PATH.md|moved to docs/LEARNING-PATH.md"
    "memory/claude-md-maintenance.md|consolidated, removed in v0.27"
    "memory/wp-gate-lesson.md|consolidated into protocol-work.md, removed in v0.27"
    "roles/strategist/scripts/cleanup-processed-notes.sh|strategist role removed"
    "strategist-agent/README.md|strategist-agent directory removed in v0.24"
    "strategist-agent/REPO-TYPE.md|strategist-agent directory removed"
    "strategist-agent/prompts/day-close.md|strategist-agent directory removed"
    "strategist-agent/prompts/day-plan.md|strategist-agent directory removed"
    "strategist-agent/prompts/note-review.md|strategist-agent directory removed"
    "strategist-agent/prompts/session-prep.md|strategist-agent directory removed"
    "strategist-agent/prompts/strategy-cascade.md|strategist-agent directory removed"
    "strategist-agent/prompts/strategy-session.md|strategist-agent directory removed"
    "strategist-agent/prompts/strategy.md|strategist-agent directory removed"
    "strategist-agent/prompts/week-review.md|strategist-agent directory removed"
    "strategist-agent/scripts/strategist.sh|strategist-agent directory removed"
)

# Добавляем deprecated_files в JSON через Python
DEPRECATED_JSON=""
last_dep=$(( ${#DEPRECATED_LIST[@]} - 1 ))
for i in "${!DEPRECATED_LIST[@]}"; do
    entry="${DEPRECATED_LIST[$i]}"
    dpath="${entry%%|*}"
    dreason="${entry#*|}"
    comma=","
    [ "$i" -eq "$last_dep" ] && comma=""
    DEPRECATED_JSON="${DEPRECATED_JSON}    {\"path\": \"${dpath}\", \"reason\": \"${dreason}\"}${comma}
"
done

python3 -c "
import json, sys

with open('$MANIFEST') as f:
    data = json.load(f)

deprecated = []
lines = '''$DEPRECATED_JSON'''.strip().splitlines()
for line in lines:
    line = line.strip().rstrip(',').strip()
    if line:
        try:
            deprecated.append(json.loads(line))
        except:
            pass

data['deprecated_files'] = deprecated

with open('$MANIFEST', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

echo "Готово: $MANIFEST"
echo "  Версия: $VERSION"
echo "  Файлов: ${#FILES[@]}"
echo "  Устаревших: ${#DEPRECATED_LIST[@]}"
echo ""
echo "Проверьте diff и закоммитьте:"
echo "  git diff update-manifest.json"
