#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# doctor.sh — агент проверяет сам себя и говорит, что сломано.
#
# Зачем: почти все поломки агента тихие. Он не падает с ошибкой, он просто
# перестаёт отвечать или начинает «забывать». Владелец узнаёт об этом по
# тишине, через день или через неделю. Доктор превращает тишину в сообщение.
#
# Запуск:
#   ./scripts/doctor.sh              показать отчёт
#   ./scripts/doctor.sh --short      только проблемы
#   ./scripts/doctor.sh --telegram   прислать отчёт в телеграм, если есть проблемы
#   ./scripts/doctor.sh --alert      режим расписания: писать про каждую
#                                    проблему один раз, и ещё раз когда прошла
#
# Код выхода: 0 всё здорово, 1 есть предупреждения, 2 есть поломки.
# ─────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

ENV_FILE="$ROOT/secrets/channel.env"
STATE_DIR="$ROOT/state"
ALERT_STATE="$STATE_DIR/doctor-alerts.txt"
MEMORY_DIR="$ROOT/core/memory"
MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"
MEMORY_LIMIT_KB=24
mkdir -p "$STATE_DIR"

SHORT=0; TELEGRAM=0; ALERT=0
for a in "$@"; do
  case "$a" in
    --short) SHORT=1 ;;
    --telegram) TELEGRAM=1 ;;
    --alert) ALERT=1 ;;
  esac
done

REPORT=""
PROBLEMS=""          # строки вида "уровень|проверка|подробности|лечение"
FAILS=0; WARNS=0

add() { # уровень проверка подробности [лечение]
  local lvl="$1" name="$2" detail="$3" fix="${4:-}"
  local mark
  case "$lvl" in
    ok)   mark="ок  " ;;
    warn) mark="вним"; WARNS=$((WARNS+1)) ;;
    fail) mark="СБОЙ"; FAILS=$((FAILS+1)) ;;
  esac
  if [ "$lvl" != "ok" ] || [ "$SHORT" = "0" ]; then
    REPORT="${REPORT}${mark}  ${name}: ${detail}"$'\n'
    [ -n "$fix" ] && REPORT="${REPORT}      лечится: ${fix}"$'\n'
  fi
  [ "$lvl" != "ok" ] && PROBLEMS="${PROBLEMS}${lvl}|${name}|${detail}|${fix}"$'\n'
  return 0
}

envval() { grep -o "^$1=.*" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' '; }

# ── 1. Файл с ключами и его права ────────────────────────────
TOKEN=""
if [ -r "$ENV_FILE" ]; then
  TOKEN="$(envval TELEGRAM_BOT_TOKEN)"
  if [ -z "$TOKEN" ]; then
    add fail "Ключи" "в secrets/channel.env нет TELEGRAM_BOT_TOKEN"
  else
    add ok "Ключи" "channel.env на месте, токен бота есть"
  fi
  PERM="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  if [ "$PERM" != "600" ]; then
    add warn "Права на ключи" "channel.env открыт для чтения другим (права $PERM)" "chmod 600 secrets/channel.env"
  else
    add ok "Права на ключи" "читает только владелец"
  fi
else
  add fail "Ключи" "нет файла secrets/channel.env" "скопируй secrets/channel.env.example и впиши свои ключи"
fi

# ── 2. Бот отвечает ──────────────────────────────────────────
if [ -n "$TOKEN" ]; then
  ME="$(curl -s -m 15 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null)"
  if printf '%s' "$ME" | grep -q '"ok":true'; then
    UNAME="$(printf '%s' "$ME" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')"
    add ok "Бот Telegram" "@${UNAME} отвечает"
  else
    add fail "Бот Telegram" "не отвечает: $(printf '%s' "$ME" | head -c 120)" "проверь TELEGRAM_BOT_TOKEN, его могли отозвать в BotFather"
  fi
fi

# ── 3. Хуки реально подключены ───────────────────────────────
# Самая коварная поломка этой сборки: сторож ответа прописан в настройках
# проекта, но Claude Code читает хуки из ~/.claude/settings.json. Если
# merge-settings не сработал, сторож лежит мёртвым кодом, и ответы теряются
# молча. Снаружи выглядит как «агент иногда не отвечает».
HOOK="$ROOT/dashi-plugin-claude-code/plugin/scripts/require-reply-hook.py"
HOME_SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$HOOK" ]; then
  add warn "Сторож ответа" "файла require-reply-hook.py нет в сборке"
elif [ ! -r "$HOME_SETTINGS" ]; then
  add fail "Сторож ответа" "нет ~/.claude/settings.json, хуки не подключены" "запусти ./start.sh, он переносит настройки на место"
elif grep -q "require-reply-hook" "$HOME_SETTINGS" 2>/dev/null; then
  add ok "Сторож ответа" "подключён в ~/.claude/settings.json"
else
  add fail "Сторож ответа" "хук не прописан в ~/.claude/settings.json, ответы могут теряться молча" "node scripts/merge-settings.js settings.json ~/.claude/settings.json \"$ROOT\""
fi

# ── 4. Канал жив ─────────────────────────────────────────────
CHAN_PID="$(ps -axo pid=,command= 2>/dev/null \
  | grep 'dangerously-load-development-channels server:dashi-channel' \
  | grep -v grep | awk '{print $1}' | head -1)"
if [ -z "$CHAN_PID" ]; then
  add warn "Агент запущен" "сейчас не запущен, в телеграме он не ответит" "./start.sh"
else
  SRV="$(ps -axo ppid=,command= 2>/dev/null | awk -v p="$CHAN_PID" '$1==p && /src\/server\.ts/ {print "да"; exit}')"
  if [ "$SRV" = "да" ]; then
    add ok "Агент запущен" "работает, канал поднят (PID $CHAN_PID)"
  else
    add fail "Агент запущен" "процесс жив, но мост в телеграм умер: агент вас не слышит" "pkill -f 'server:dashi-channel' и затем ./start.sh"
  fi
fi

# ── 5. Память: размер указателя ──────────────────────────────
if [ -f "$MEMORY_INDEX" ]; then
  KB=$(( $(wc -c < "$MEMORY_INDEX") / 1024 ))
  if [ "$KB" -gt "$MEMORY_LIMIT_KB" ]; then
    add fail "Память" "указатель MEMORY.md ${KB} КБ при пределе ${MEMORY_LIMIT_KB}: часть фактов не доезжает в разговор, агент будет «забывать»" "см. docs/obnovlenie-pamyati.md, агент сворачивает указатель сам"
  elif [ "$KB" -gt $((MEMORY_LIMIT_KB * 92 / 100)) ]; then
    add warn "Память" "указатель ${KB} КБ, предел ${MEMORY_LIMIT_KB} рядом"
  else
    add ok "Память" "указатель ${KB} из ${MEMORY_LIMIT_KB} КБ"
  fi
else
  add ok "Память" "указателя пока нет, это нормально для новой установки"
fi

# ── 6. Память: битые ссылки и потерянные файлы ───────────────
if [ -f "$MEMORY_INDEX" ]; then
  MISSING=""; ORPHANS=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$MEMORY_DIR/$f" ] || MISSING="$MISSING $f"
  done <<EOF
$(grep -o '([a-z0-9_-]*\.md)' "$MEMORY_INDEX" 2>/dev/null | tr -d '()' | sort -u)
EOF
  for f in "$MEMORY_DIR"/*.md; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [ "$b" = "MEMORY.md" ] && continue
    grep -q "($b)" "$MEMORY_INDEX" 2>/dev/null || ORPHANS="$ORPHANS $b"
  done
  if [ -n "$MISSING" ]; then
    add fail "Целостность памяти" "указатель ссылается на несуществующие файлы:$MISSING"
  elif [ -n "$ORPHANS" ]; then
    add warn "Целостность памяти" "файлы памяти потеряны мимо указателя:$ORPHANS"
  else
    add ok "Целостность памяти" "ссылки и файлы совпадают"
  fi
fi

# ── 7. Обновления ────────────────────────────────────────────
if [ -d "$ROOT/.git" ]; then
  git fetch -q origin main 2>/dev/null
  BEHIND="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  if [ "${BEHIND:-0}" -gt 0 ]; then
    add warn "Версия" "вышло новее на ${BEHIND} обновлений" "./scripts/update.sh"
  else
    add ok "Версия" "самая свежая"
  fi
else
  add warn "Версия" "папка скачана архивом, обновления сами не придут" "./scripts/update.sh заведёт связь с гитхабом"
fi

# ── 8. Место на диске ────────────────────────────────────────
FREE_GB=$(( $(df -k / | tail -1 | awk '{print $4}') / 1024 / 1024 ))
if [ "$FREE_GB" -lt 3 ]; then
  add fail "Диск" "свободно ${FREE_GB} ГБ, агент начнёт падать"
elif [ "$FREE_GB" -lt 10 ]; then
  add warn "Диск" "свободно ${FREE_GB} ГБ"
else
  add ok "Диск" "свободно ${FREE_GB} ГБ"
fi

# ── вывод ────────────────────────────────────────────────────
if [ "$FAILS" -gt 0 ]; then
  HEAD="Проверка агента: поломок ${FAILS}, предупреждений ${WARNS}."
  CODE=2
elif [ "$WARNS" -gt 0 ]; then
  HEAD="Проверка агента: поломок нет, предупреждений ${WARNS}."
  CODE=1
else
  HEAD="Проверка агента: всё здорово."
  CODE=0
fi

FULL="${HEAD}"$'\n\n'"${REPORT}"
printf '%s' "$FULL"

tg() {
  [ -z "${TOKEN:-}" ] && return 0
  local chat; chat="$(envval TELEGRAM_ALLOWED_USER_IDS | cut -d, -f1)"
  [ -z "$chat" ] && chat="$(envval TELEGRAM_ALLOWED_USER)"
  [ -z "$chat" ] && return 0
  curl -s -m 20 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --form-string "chat_id=${chat}" \
    --form-string "disable_web_page_preview=true" \
    --form-string "text=$1" >/dev/null || true
}

if [ "$ALERT" = "1" ]; then
  # Про одну и ту же поломку пишем один раз. Отпечаток это уровень и имя
  # проверки, без изменчивых подробностей (PID, гигабайты), иначе каждое
  # сообщение выглядит новым и превращается в спам.
  NOW_KEYS="$(printf '%s' "$PROBLEMS" | awk -F'|' 'NF{print $1"|"$2}' | sort -u)"
  OLD_KEYS=""
  [ -f "$ALERT_STATE" ] && OLD_KEYS="$(sort -u "$ALERT_STATE")"
  FRESH="$(comm -23 <(printf '%s\n' "$NOW_KEYS") <(printf '%s\n' "$OLD_KEYS") 2>/dev/null)"
  HEALED="$(comm -13 <(printf '%s\n' "$NOW_KEYS") <(printf '%s\n' "$OLD_KEYS") 2>/dev/null)"
  printf '%s\n' "$NOW_KEYS" | grep -v '^$' > "$ALERT_STATE"

  MSG=""
  if [ -n "$(printf '%s' "$FRESH" | tr -d '[:space:]')" ]; then
    MSG="Агент нашёл у себя проблему:"$'\n'
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      line="$(printf '%s' "$PROBLEMS" | grep "^${key}|" | head -1)"
      name="$(printf '%s' "$line" | cut -d'|' -f2)"
      det="$(printf '%s' "$line" | cut -d'|' -f3)"
      fix="$(printf '%s' "$line" | cut -d'|' -f4)"
      MSG="${MSG}"$'\n'"${name}: ${det}"
      [ -n "$fix" ] && MSG="${MSG}"$'\n'"лечится: ${fix}"
    done <<EOF
$FRESH
EOF
  fi
  if [ -n "$(printf '%s' "$HEALED" | tr -d '[:space:]')" ]; then
    names="$(printf '%s' "$HEALED" | awk -F'|' 'NF{print $2}' | paste -sd, -)"
    MSG="${MSG}"$'\n\n'"Прошло само: ${names}."
  fi
  [ -n "$(printf '%s' "$MSG" | tr -d '[:space:]')" ] && tg "$MSG"
elif [ "$TELEGRAM" = "1" ] && [ "$CODE" != "0" ]; then
  tg "$FULL"
fi

exit "$CODE"
