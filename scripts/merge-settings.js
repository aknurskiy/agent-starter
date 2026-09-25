// merge-settings.js
// Сливает permissions И hooks из стартера в ~/.claude/settings.json, чтобы
// агент отвечал в Telegram без подтверждений и чтобы hooks (например,
// Stop-хук require-reply-hook.py) реально исполнялись (Claude Code читает
// и права, и hooks именно оттуда, а не из settings.json в корне репозитория —
// до 2026-08-26 сюда сливались только permissions, из-за чего Stop-хук был
// прописан в repo settings.json, но никогда не запускался).
//
// Слияние безопасное: только ДОБАВЛЯЕТ нужные права/хуки (union по
// command-строке для хуков), ничего из твоих существующих настроек не
// удаляет. Запускается автоматически из start.sh.
//
// Использование: node merge-settings.js <src settings.json> <dst ~/.claude/settings.json> <repo root>

const fs = require('fs');
const path = require('path');

const srcPath = process.argv[2];   // <repo>/settings.json
const dstPath = process.argv[3];   // ~/.claude/settings.json
const repoRoot = process.argv[4];  // абсолютный путь к репозиторию

function readJson(p, fallback) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    return fallback;
  }
}

const union = (a, b) => Array.from(new Set([...(a || []), ...(b || [])]));

const src = readJson(srcPath, {});
const dst = readJson(dstPath, {});

dst.permissions = dst.permissions || {};
const P = dst.permissions;
const S = src.permissions || {};

P.allow = union(P.allow, S.allow);
P.deny = union(P.deny, S.deny);
// Доступ к файлам репозитория — абсолютным путём (вместо относительного ".").
P.additionalDirectories = union(P.additionalDirectories, repoRoot ? [repoRoot] : []);
// Режим по умолчанию (acceptEdits) — авто-подтверждение правок файлов; работает и под root
// (в отличие от bypassPermissions, который Claude Code запрещает под root).
if (S.permissions && S.permissions.defaultMode) P.defaultMode = S.permissions.defaultMode;

// Hooks — union per event, deduped by each entry's hook command string(s) so
// re-running start.sh (or editing the repo hook later) never piles up
// duplicate entries that would fire the same script twice per event.
dst.hooks = dst.hooks || {};
const H = dst.hooks;
const srcHooks = src.hooks || {};

function commandsOf(entry) {
  return Array.isArray(entry && entry.hooks)
    ? entry.hooks.map(h => h && h.command).filter(Boolean)
    : [];
}

for (const event of Object.keys(srcHooks)) {
  const existing = Array.isArray(H[event]) ? H[event] : [];
  const existingCommands = new Set(existing.flatMap(commandsOf));
  const toAdd = (srcHooks[event] || []).filter(
    entry => !commandsOf(entry).some(cmd => existingCommands.has(cmd)),
  );
  H[event] = [...existing, ...toAdd];
}

fs.mkdirSync(path.dirname(dstPath), { recursive: true });
fs.writeFileSync(dstPath, JSON.stringify(dst, null, 2) + '\n');

console.log('Права агента настроены: ' + dstPath);
