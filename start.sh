#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# start.sh — запуск твоего личного агента.
#
# Что делает: загружает настройки из secrets/channel.env и запускает
# Claude Code с подключённым Telegram-мостом (dashi-channel).
# Пока это окно открыто — агент «бодрствует» и отвечает в Telegram.
# Закрыл окно → агент «уснул» (для работы 24/7 см. README, раздел
# «Где держать агента»).
#
# Запуск:  ./start.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# bun ставится в ~/.bun/bin — добавляем его в PATH на случай, если он
# не подхватился в текущей оболочке. Без этого MCP-сервер плагина
# (запускается командой `bun`) не найдётся — и агент не свяжется с Telegram.
export PATH="$HOME/.bun/bin:$PATH"

# 0. Один экземпляр агента на машину.
#    Почему это важно: Telegram отдаёт обновления только одному поллеру. Два
#    запущенных dashi-channel = 409 Conflict, и живая сессия не подключается
#    к каналу. Раньше launchd (KeepAlive) перезапускал start.sh каждые 30
#    секунд, claude падал, а MCP-сервер (bun src/server.ts) оставался жить —
#    за час накапливалось 5+ висящих серверов, каждый жёг CPU и ломал канал.
#    (детект через ps, а не pgrep: pgrep на этой машине видит не все
#    процессы пользователя.)
SELF_PID=$$
RUNNING="$(ps -axo pid=,command= 2>/dev/null \
  | grep 'dangerously-load-development-channels server:dashi-channel' \
  | grep -v grep \
  | awk '{print $1}' \
  | grep -v "^${SELF_PID}$" || true)"
if [ -n "$RUNNING" ]; then
  echo "Агент уже запущен (PID: $(echo "$RUNNING" | tr '\n' ' '))."
  echo "Второй экземпляр не поднимаю: два поллера одного бота — это 409 Conflict в Telegram."
  echo "Если нужен именно перезапуск: pkill -f 'server:dashi-channel' и затем ./start.sh"
  # Пауза, чтобы launchd с KeepAlive не крутил этот путь каждые 30 секунд.
  sleep 300
  exit 0
fi

# 0.1. Когда агент завершается — забираем с собой его MCP-сервер.
#      Без этого сервер остаётся сиротой и продолжает опрашивать бота.
cleanup_mcp() { pkill -f 'src/server.ts' 2>/dev/null || true; }
trap cleanup_mcp EXIT


# Папка, где лежит этот скрипт (корень репозитория).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT/secrets/channel.env"
PLUGIN_DIR="$ROOT/dashi-plugin-claude-code/plugin"

# 1. Проверяем, что файл с настройками создан.
if [ ! -f "$ENV_FILE" ]; then
  echo "ОШИБКА: не найден файл secrets/channel.env"
  echo
  echo "Сделай так:"
  echo "  1. Скопируй secrets/channel.env.example → secrets/channel.env"
  echo "  2. Впиши в него токен бота и свой Telegram ID"
  echo "  3. Запусти ./start.sh снова"
  exit 1
fi

# 2. Проверяем, что bun установлен и найден.
if ! command -v bun >/dev/null 2>&1; then
  echo "ОШИБКА: не найден bun (движок плагина)."
  echo "Установи один раз:  curl -fsSL https://bun.sh/install | bash"
  echo "Потом закрой и открой терминал и запусти ./start.sh снова."
  exit 1
fi

# 3. Проверяем, что зависимости установлены (Шаг 5 в README).
if [ ! -d "$PLUGIN_DIR/node_modules" ]; then
  echo "ОШИБКА: не установлены зависимости плагина."
  echo "Выполни один раз:"
  echo "  cd dashi-plugin-claude-code/plugin && bun install"
  echo "Потом запусти ./start.sh снова."
  exit 1
fi

# 4. Загружаем настройки из channel.env в окружение.
echo "Загружаю настройки из secrets/channel.env ..."
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# 4.5. Выдаём агенту права и hooks (например, Stop-хук на случай пропавшего
#      reply), чтобы он отвечал в Telegram БЕЗ подтверждений. Claude Code
#      читает и то, и другое из ~/.claude/settings.json (а не из settings.json
#      в корне репо), поэтому сливаем туда нужные permissions/hooks. Слияние
#      безопасное: только добавляет права/хуки (union), твои существующие
#      настройки не трогает.
#      Раннер — node, если есть, иначе bun (bun обязателен для остального
#      проекта и уже проверен выше, так что он точно есть на этой машине).
MERGE_RUNNER=""
if command -v node >/dev/null 2>&1; then
  MERGE_RUNNER="node"
elif command -v bun >/dev/null 2>&1; then
  MERGE_RUNNER="bun"
fi

if [ -n "$MERGE_RUNNER" ]; then
  if "$MERGE_RUNNER" "$ROOT/scripts/merge-settings.js" "$ROOT/settings.json" "$HOME/.claude/settings.json" "$ROOT"; then
    :
  else
    echo "Внимание: не удалось настроить права/hooks автоматически."
    echo "Тогда при первом вопросе 'Do you want to proceed?' выбери вариант 2 (don't ask again)."
  fi
else
  echo "Внимание: не найден ни node, ни bun — права/hooks не настроены автоматически."
  echo "При первом вопросе 'Do you want to proceed?' выбери вариант 2 (don't ask again)."
fi

# 5. Запускаем агента из папки plugin (чтобы Claude Code нашёл CLAUDE.md
#    в корне репозитория, поднявшись вверх по дереву).
# 5.1. По умолчанию продолжаем прошлый разговор (флаг -c). Без него каждый
#      запуск начинается с чистого листа, и агент не помнит, на чём вы
#      остановились: историю чата Telegram ботам не отдаёт.
#      Разговор со временем растёт и запускается всё медленнее, поэтому раз
#      в неделю полезно начать новый:  ./start.sh fresh
#      Факты и правила при этом не теряются — они лежат в core/memory.
CONTINUE_FLAG="-c"
if [ "${1:-}" = "fresh" ]; then
  CONTINUE_FLAG=""
  echo "Чистый запуск: начинаю новый разговор (память в core/memory остаётся)."
fi

echo "Запускаю агента... (для остановки нажми Ctrl+C)"
echo "Теперь напиши своему боту в Telegram — он ответит."
cd "$PLUGIN_DIR"

# 5.2. Находим сам бинарник claude. Под launchd оболочка `bash -lc` прогоняет
#      /etc/profile и path_helper, который перестраивает PATH с нуля — путь к
#      nvm при этом теряется, и запуск падал с `exec: claude: not found`.
#      Поэтому ищем claude явно, а не надеемся на PATH.
CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  for cand in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
              "$HOME"/.nvm/versions/node/*/bin/claude \
              /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [ -x "$cand" ]; then CLAUDE_BIN="$cand"; break; fi
  done
fi
if [ -z "$CLAUDE_BIN" ]; then
  echo "ОШИБКА: не найден claude (Claude Code CLI)."
  echo "Проверь установку:  npm i -g @anthropic-ai/claude-code"
  exit 1
fi

# 5.1.1. Мост с Телеграмом читает настройки из папки состояния канала, а не из
#        secrets/channel.env. Раньше этот файл приходилось копировать туда
#        руками, и забытый шаг был главной причиной, по которой бот молчал
#        после установки. Теперь копируем сами при каждом запуске.
STATE_DIR="${TELEGRAM_STATE_DIR:-$HOME/.claude/channels/dashi-telegram-canary}"
mkdir -p "$STATE_DIR"
cp "$ENV_FILE" "$STATE_DIR/.env"

# 5.1.2. Фоном проверяем, не вышла ли новая версия набора. Запуск не задерживаем.
if [ -x "$ROOT/scripts/update-check.sh" ]; then
  ( "$ROOT/scripts/update-check.sh" >/dev/null 2>&1 & ) || true
fi

ARGS=(--dangerously-skip-permissions --dangerously-load-development-channels server:dashi-channel)

# 5.2.1. Под launchd нет TTY: claude в этом случае уходит в режим --print и
#        падает с "Input must be provided either through stdin or as a prompt
#        argument". Поэтому для headless-запуска выделяем псевдотерминал
#        через script(1) — интерактивный запуск из терминала это не трогает.
#        Плюс claude спрашивает подтверждение на --dangerously-load-
#        development-channels ("1. I am using this for local development").
#        В headless-режиме отвечать некому, поэтому через 4 секунды сами
#        отправляем Enter в pty, а stdin держим открытым (tail -f /dev/null),
#        иначе claude увидит EOF и закроется.
HEADLESS=0
if [ ! -t 0 ] && command -v script >/dev/null 2>&1; then
  HEADLESS=1
  echo "Нет TTY (запуск из launchd) — поднимаю агента через pty."
fi

run_claude() {
  if [ "$HEADLESS" = "1" ]; then
    { sleep 4; printf '\r'; exec tail -f /dev/null; } \
      | script -q /dev/null "$CLAUDE_BIN" "$@"
  else
    "$CLAUDE_BIN" "$@"
  fi
}

# 5.3. Пробуем продолжить прошлый разговор (-c). Если продолжить не вышло
#      (например, прошлая сессия оборвалась на середине вызова инструмента —
#      claude тогда падает с "No deferred tool marker found in the resumed
#      session"), запускаемся с чистого листа, а не висим в цикле перезапуска.
#      Память при этом не теряется: факты лежат в core/memory.md.
if [ -n "$CONTINUE_FLAG" ]; then
  START_TS=$(date +%s)
  run_claude "$CONTINUE_FLAG" "${ARGS[@]}" && exit 0
  RC=$?
  # Запустился и проработал дольше 20 секунд — значит продолжение удалось, а
  # вышли уже по другой причине (Ctrl+C, ошибка в работе). Новую сессию в
  # этом случае не поднимаем: иначе Ctrl+C не завершал бы агента.
  if [ $(( $(date +%s) - START_TS )) -gt 20 ]; then
    exit $RC
  fi
  echo "Не удалось продолжить прошлый разговор — начинаю новый (память в core/memory.md на месте)."
fi

run_claude "${ARGS[@]}"