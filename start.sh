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
echo "Запускаю агента... (для остановки нажми Ctrl+C)"
echo "Теперь напиши своему боту в Telegram — он ответит."
cd "$PLUGIN_DIR"
exec claude --dangerously-skip-permissions --dangerously-load-development-channels server:dashi-channel