#!/bin/bash
# Шаблон уведомлений: Стратег (R1)
# Вызывается из notify.sh через source

STRATEGY_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/current"
STRATEGY_REPO_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
DATE=$(date +%Y-%m-%d)

find_strategy_file() {
    case "$1" in
        "day-plan"|"evening"|"day-close"|"note-review")
            echo "$STRATEGY_DIR/DayPlan $DATE.md"
            ;;
        "session-prep")
            ls -t "$STRATEGY_DIR"/WeekPlan\ W*.md 2>/dev/null | head -1
            ;;
        "week-review")
            ls -t "$STRATEGY_DIR"/WeekPlan\ W*.md 2>/dev/null | head -1
            ;;
        *)
            echo ""
            ;;
    esac
}

# HTML-escape для контента из markdown-источника (parse_mode=HTML).
# Применять к переменным, которые приходят из DayPlan/WeekPlan текста, ДО подстановки в printf.
# Не применять к статическим <b>/<a> тегам из printf — они должны остаться буквальными.
# Причина: фразы вида "<4/5", "a < b" в markdown ломают Telegram parser (Bad Request: Unsupported start tag).
escape_html() {
    python3 -c 'import sys, html; sys.stdout.write(html.escape(sys.stdin.read()))'
}

table_to_list() {
    local file="$1"
    local section="$2"

    # Columns are located by header name, not position: DayPlan
    # (🚦 | ТВС | # | РП | h | Статус) and WeekPlan (🚦 | # | РП | h | Статус | …)
    # order them differently, and fixed positions shifted every field.
    # Output: priority \t num \t rp \t hours \t status, one line per row.
    sed -n -E "/^## ${section}|<summary>.*${section}/,/^---|^<\/details>/p" "$file" \
        | grep '^|' \
        | awk -F'|' '
            function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
            NR == 1 {
                for (i = 2; i < NF; i++) {
                    h = trim($i)
                    if (h == "🚦") c_pri = i
                    else if (h == "#") c_num = i
                    else if (h == "РП" || h == "Работа" || h == "Задача") c_rp = i
                    else if (h == "h" || h == "Бюджет" || h == "Оценка") c_h = i
                    else if (h == "Статус") c_st = i
                }
                next
            }
            NR == 2 || !c_rp { next }
            {
                printf "%s\t%s\t%s\t%s\t%s\n", c_pri ? trim($c_pri) : "", c_num ? trim($c_num) : "",
                    trim($c_rp), c_h ? trim($c_h) : "", c_st ? trim($c_st) : ""
            }' \
        | while IFS=$'\t' read -r priority num rp hours status; do
            rp=$(printf '%s' "$rp" | sed 's/\*\*//g')
            hours=$(printf '%s' "$hours" | sed 's/\*\*//g')

            # Not-started rows reuse the DayPlan traffic light (🔴🟡🟢⚫):
            # a bare ⬜ renders as an empty grey box in Telegram.
            local icon="${priority:-⬜}"
            case "$status" in
                *done*|*"✅"*) icon="✅" ;;
                *in_progress*|*in.progress*) icon="🔄" ;;
            esac

            # No "#" prefix: IDs are now "WP-17" (Telegram turns "#WP" into a
            # hashtag) or "—" for rows without a work product.
            local label="$rp"
            case "$num" in
                ""|"—"|"-") ;;
                *) label="$num $rp" ;;
            esac

            printf "%s %s (%s)\n" "$icon" "$label" "$hours"
        done
}

get_github_link() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local repo_url
    repo_url=$(cd "$STRATEGY_REPO_DIR" && git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')
    if [ -n "$repo_url" ]; then
        local branch
        branch=$(cd "$STRATEGY_REPO_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ -z "$branch" ]; then
            echo "ERROR: unable to determine git branch for $STRATEGY_REPO_DIR" >&2
            return 1
        fi
        local encoded_name
        encoded_name=$(printf '%s' "$filename" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')
        printf '\n\n<a href="%s/blob/%s/current/%s">📄 Открыть в GitHub</a>' "$repo_url" "$branch" "$encoded_name"
    fi
}

build_message() {
    local scenario="$1"
    local file

    # WP-561 Ф25: a failed week-review must alarm even when no WeekPlan file is found or the
    # model wrote nothing, so this message is static and skips the file lookup below.
    if [ "$scenario" = "week-review-failed" ]; then
        printf "<b>🔴 Week-Review не доведён до сервера</b>\n\nОтчёт недели не подтверждён на origin/main (запуск не начался, модель упала или отчёт не доставлен), последующие сценарии могут остаться без итогов недели. Причина - в логе стратега за сегодня, строки POSTCONDITION или FAILED."
        return
    fi

    file=$(find_strategy_file "$scenario")

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo ""
        return
    fi

    case "$scenario" in
        "day-plan")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            local plan_items
            plan_items=$(table_to_list "$file" "План на сегодня" | escape_html)

            printf "<b>📋 %s</b>\n\n" "$title"
            printf "<b>План:</b>\n%s" "$plan_items"
            ;;

        "session-prep")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            local plan_items
            plan_items=$(table_to_list "$file" "Рабочие продукты" | escape_html)
            [ -z "$plan_items" ] && plan_items=$(table_to_list "$file" "План на неделю" | escape_html)

            printf "<b>📅 %s</b>\n\n" "$title"
            printf "<b>Рабочие продукты:</b>\n%s" "$plan_items"
            ;;

        "week-review")
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)

            printf "<b>📊 Week-Review завершён</b>\n\n%s" "$title"
            ;;

        "note-review")
            # The notifier cannot see what the model did, so the text claims nothing about written proposals
            printf "<b>📝 Note-Review завершён</b>\n\nЗаметки остаются в inbox, пока вы не примете по ним решение."
            ;;

        *)
            local title
            title=$(grep '^# ' "$file" | head -1 | sed 's/^# //' | escape_html)
            printf "<b>📋 %s</b>\n\nСценарий <b>%s</b> завершён." "$title" "$scenario"
            ;;
    esac

    get_github_link "$file"
}

build_buttons() {
    local scenario="$1"
    echo '[]'
}
