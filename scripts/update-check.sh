#!/usr/bin/env bash
# update-check.sh — обновления агента по принципу iOS: проверить, рассказать, применить.
#
# Раз в сутки смотрит, не вышла ли новая версия набора в GitHub. Если вышла,
# присылает владельцу в телеграм список изменений человеческим языком и
# применяет обновление, когда это безопасно.
#
# Безопасно значит: свои файлы владельца не тронуты обновлением. Если владелец
# правил те же файлы, что и обновление, мы ничего не перезаписываем молча,
# а спрашиваем. Потерять чужие правила монтажа или настройки хуже,
# чем остаться на старой версии.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
BRANCH="${UPDATE_BRANCH:-main}"
STATE="$ROOT/state/update-check.json"
mkdir -p "$ROOT/state"

ENV_FILE="$ROOT/secrets/channel.env"
TOKEN=$(grep -o '^TELEGRAM_BOT_TOKEN=.*' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
CHAT=$(grep -o '^TELEGRAM_ALLOWED_USER=.*' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)

say() {
  [ -z "${TOKEN:-}" ] || [ -z "${CHAT:-}" ] && return 0
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --form-string "chat_id=${CHAT}" \
    --form-string "parse_mode=HTML" \
    --form-string "disable_web_page_preview=true" \
    --form-string "text=$1" >/dev/null || true
}

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || exit 0

git -C "$ROOT" fetch --quiet origin "$BRANCH" 2>/dev/null || exit 0

LOCAL=$(git -C "$ROOT" rev-parse HEAD)
REMOTE=$(git -C "$ROOT" rev-parse "origin/$BRANCH" 2>/dev/null) || exit 0
[ "$LOCAL" = "$REMOTE" ] && exit 0

# Уже рассказывали про эту версию? Тогда молчим: уведомление приходит один раз.
SEEN=$(grep -o '"announced":"[^"]*"' "$STATE" 2>/dev/null | cut -d'"' -f4)
FIRST_TIME=1
[ "$SEEN" = "$REMOTE" ] && FIRST_TIME=0

# Что изменилось: берём заголовки коммитов, они пишутся человеческим языком.
CHANGES=$(git -C "$ROOT" log --no-merges --pretty=format:'• %s' "$LOCAL..$REMOTE" | head -12)
COUNT=$(git -C "$ROOT" rev-list --count "$LOCAL..$REMOTE")

# Какие файлы трогает обновление и какие из них владелец правил сам.
INCOMING=$(git -C "$ROOT" diff --name-only "$LOCAL" "$REMOTE")
DIRTY=$(git -C "$ROOT" status --porcelain | awk '{print $2}')
CONFLICT=$(comm -12 <(echo "$INCOMING" | sort -u) <(echo "$DIRTY" | sort -u))

if [ -z "$CONFLICT" ]; then
  if git -C "$ROOT" merge --ff-only "origin/$BRANCH" --quiet 2>/dev/null; then
    say "<b>Агент обновился</b>
Версий подтянуто: ${COUNT}

${CHANGES}

Обновление уже применено. Перезапусти агента, чтобы оно заработало: Ctrl+C в его окне и ./start.sh"
    printf '{"announced":"%s","applied":"%s"}\n' "$REMOTE" "$REMOTE" > "$STATE"
    exit 0
  fi
fi

[ "$FIRST_TIME" = "0" ] && exit 0

say "<b>Есть обновление агента</b>
Версий доступно: ${COUNT}

${CHANGES}

Автоматически не применяю: ты правил файлы, которых касается обновление:
${CONFLICT:-рабочая папка не чистая}

Скажи мне «обнови агента», и я разведу твои правки с новой версией вручную, ничего не потеряв."
printf '{"announced":"%s","applied":"%s"}\n' "$REMOTE" "$LOCAL" > "$STATE"
