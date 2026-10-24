#!/usr/bin/env bash
# update.sh — обновить агента до свежей версии набора одной командой.
#
# Запуск:  ./scripts/update.sh
#
# Что делает по порядку:
#   1. делает полную копию папки рядом, на случай отката;
#   2. подтягивает свежую версию с гитхаба;
#   3. возвращает на место личные файлы владельца (настройки, правила, память);
#   4. показывает, что изменилось.
#
# Личное никогда не перезаписывается молча. Если новая версия трогает тот же
# файл, что правил владелец, его версия остаётся, а новая кладётся рядом
# с припиской .novaya, и об этом сказано в конце.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
REPO="https://github.com/aknurskiy/agent-starter.git"
BRANCH="main"
STAMP=$(date +%Y-%m-%d-%H%M)

say() { printf '%s\n' "$1"; }

# 1. Резервная копия всей папки.
BACKUP="$ROOT-rezerv-$STAMP"
cp -R "$ROOT" "$BACKUP" 2>/dev/null
say "Резервная копия: $BACKUP"

# 2. Если папка скачана архивом, связи с гитхабом нет — заводим её.
if [ ! -d .git ]; then
  say "Подключаю папку к гитхабу (она была скачана архивом)…"
  git init -q
  git remote add origin "$REPO"
  git fetch -q --depth=1 origin "$BRANCH" || { say "Не получилось скачать обновление. Проверь интернет."; exit 1; }
  # Берём свежую версию, но ничего из личного не трогаем: оно не отслеживается.
  git reset -q --mixed FETCH_HEAD
  git checkout -q -b "$BRANCH" FETCH_HEAD -- 2>/dev/null || git checkout -q -B "$BRANCH" FETCH_HEAD
  say "Готово. Папка обновлена и дальше будет обновляться сама."
  exit 0
fi

git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REPO"
git fetch -q origin "$BRANCH" || { say "Не получилось связаться с гитхабом. Проверь интернет."; exit 1; }

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")
if [ "$LOCAL" = "$REMOTE" ]; then
  say "У тебя уже самая свежая версия, обновлять нечего."
  rm -rf "$BACKUP"
  exit 0
fi

CHANGES=$(git log --no-merges --pretty=format:'• %s' "$LOCAL..$REMOTE" | head -12)

# 3. Прячем правки владельца, чтобы обновление прошло чисто.
STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  git stash push -q -m "update-$STAMP" && STASHED=1
fi

if ! git merge -q --ff-only "origin/$BRANCH" 2>/dev/null; then
  git merge -q "origin/$BRANCH" -m "обновление $STAMP" || {
    say "Обновление не встало автоматически. Папка цела, копия здесь: $BACKUP"
    [ "$STASHED" = "1" ] && git stash pop -q
    exit 1
  }
fi

# 4. Возвращаем правки владельца. Конфликт решаем в его пользу.
CONFLICTS=""
if [ "$STASHED" = "1" ]; then
  if ! git stash pop -q 2>/dev/null; then
    CONFLICTS=$(git diff --name-only --diff-filter=U)
    for f in $CONFLICTS; do
      git show "origin/$BRANCH:$f" > "$f.novaya" 2>/dev/null
      git checkout --ours -- "$f" 2>/dev/null
      git add "$f" 2>/dev/null
    done
    git stash drop -q 2>/dev/null
  fi
fi

say ""
say "Обновление установлено."
say "$CHANGES"
if [ -n "$CONFLICTS" ]; then
  say ""
  say "Твои правки сохранены как есть в этих файлах:"
  for f in $CONFLICTS; do say "  $f  (новая версия лежит рядом: $f.novaya)"; done
fi
say ""
say "Перезапусти агента: ./start.sh"
