#!/usr/bin/env python3
"""Stop hook: in dashi-channel sessions, block ending a turn unless the
turn included a call to mcp__dashi-channel__reply / react / edit_message.

Root cause this guards against: the assistant repeatedly ended a Telegram
turn with plain text instead of the reply tool, so the message never
reached the user (see feedback_reply_tool_only.md in Saule's memory).
A memory note alone did not stop the recurrence, so this hook enforces
it mechanically instead.

Claude Code sets stop_hook_active=true on the input when this hook has
already fired once for the current stop; we must allow the stop then,
otherwise this could block forever.

Fallback (added after the block-only version proved insufficient): when
stop_hook_active is true and the turn STILL has no reply/react/edit_message
call, that means our one nudge (the block below) did not work. Rather than
silently let the turn end with nothing delivered, we pull the chat_id out
of the inbound <channel ...> tag and the assistant's last text output out
of the transcript, and send it to Telegram directly via the Bot API —
bypassing the reply tool entirely. This is a last-resort safety net, not a
replacement for the tool call.

Every branch logs to logs/require-reply-hook.jsonl under the channel state
dir so a silent drop is never actually silent again.
"""
import json
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.request

REQUIRED_TOOLS = {
    "mcp__dashi-channel__reply",
    "mcp__dashi-channel__react",
    "mcp__dashi-channel__edit_message",
}

# Matches the chat_id attribute on the inbound <channel ...> tag built by
# src/prompt/build.ts / src/telegram/handlers.ts (buildMeta). Attribute order
# isn't fixed, so we search the whole tag rather than anchoring on position.
CHANNEL_CHAT_ID_RE = re.compile(r'<channel\b[^>]*\bchat_id="([^"]+)"')

# Fallback sends as plain text (no parse_mode), so we don't need Telegram's
# 4096 hard cap headroom for entity overhead — 3900 matches the budget
# agreed for the reply tool's own chunker (src/format/chunk.ts).
FALLBACK_CHUNK_MAX = 3900


def _state_dir():
    # Mirrors server.ts's prebootStateDir() default so the hook finds the
    # same .env (bot token) and can share the same logs/ directory.
    env_dir = os.environ.get("TELEGRAM_STATE_DIR")
    if env_dir:
        return env_dir
    return os.path.join(os.path.expanduser("~"), ".claude", "channels", "dashi-telegram-canary")


def _log_path():
    return os.path.join(_state_dir(), "logs", "require-reply-hook.jsonl")


def log_event(event):
    record = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    record.update(event)
    try:
        path = _log_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        # Logging must never be the reason this hook crashes.
        pass


def load_bot_token():
    env_file = os.path.join(_state_dir(), ".env")
    try:
        with open(env_file, "r") as f:
            for line in f:
                m = re.match(r"^TELEGRAM_BOT_TOKEN=(.*)$", line.strip())
                if m:
                    return m.group(1).strip()
    except Exception:
        pass
    return os.environ.get("TELEGRAM_BOT_TOKEN")


def extract_text_blocks(content):
    """Plain-text strings out of an assistant message's content, in order.
    Skips tool_use/tool_result/thinking blocks — only what the user would
    have read as prose."""
    out = []
    if isinstance(content, str):
        if content.strip():
            out.append(content)
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text", "")
                if t.strip():
                    out.append(t)
    return out


def extract_chat_id(content):
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        text = "\n".join(parts)
    else:
        text = ""
    m = CHANNEL_CHAT_ID_RE.search(text)
    return m.group(1) if m else None


def split_message(text, max_len=FALLBACK_CHUNK_MAX):
    """Paragraph > line > hard-cut boundary preference — mirrors the
    behaviour of splitMessage in src/format/chunk.ts (minus the HTML
    tag-balancing, which doesn't apply to plain-text fallback sends)."""
    chunks = []
    remaining = text
    while remaining:
        if len(remaining) <= max_len:
            chunks.append(remaining)
            break
        window = remaining[:max_len]
        cut = window.rfind("\n\n")
        if cut >= 0:
            cut += 2
        else:
            cut = window.rfind("\n")
            cut = cut + 1 if cut >= 0 else max_len
        chunk = remaining[:cut]
        remaining = remaining[cut:].lstrip("\n")
        if chunk:
            chunks.append(chunk)
    return chunks


def send_telegram_message(token, chat_id, text):
    for chunk in split_message(text):
        if not chunk:
            continue
        url = "https://api.telegram.org/bot%s/sendMessage" % token
        payload = json.dumps({"chat_id": chat_id, "text": chunk}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            if not body.get("ok"):
                raise RuntimeError("telegram sendMessage failed: %r" % body)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    stop_hook_active = bool(payload.get("stop_hook_active"))
    transcript_path = payload.get("transcript_path")
    if not transcript_path:
        log_event({"event": "no_transcript_path"})
        sys.exit(0)

    try:
        with open(transcript_path, "r") as f:
            lines = f.readlines()
    except Exception as e:
        log_event({"event": "transcript_read_failed", "error": str(e)})
        sys.exit(0)

    # Walk backwards to the most recent user-role entry (start of this
    # turn), collecting any dashi-channel tool_use calls AND assistant text
    # seen along the way. Both lists come out in reverse-chronological
    # order — reversed again before use below.
    found_required_call = False
    assistant_texts_rev = []
    chat_id = None

    for raw in reversed(lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except Exception:
            continue

        entry_type = entry.get("type")
        message = entry.get("message", {})

        if entry_type == "assistant":
            content = message.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        if block.get("name") in REQUIRED_TOOLS:
                            found_required_call = True
                assistant_texts_rev.extend(reversed(extract_text_blocks(content)))

        if entry_type == "user":
            role = message.get("role")
            content = message.get("content", "")
            is_tool_result = isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result"
                for b in content
            )
            if role == "user" and not is_tool_result:
                chat_id = extract_chat_id(content)
                break

    if chat_id is None:
        # This turn's originating user message has no <channel ...> tag —
        # it's a plain terminal/CLI turn (e.g. ordinary coding work in this
        # same session), not a dashi-channel/Telegram turn. The reply-tool
        # requirement only applies to Telegram-sourced turns; enforcing it
        # unconditionally would block normal Claude Code usage in this
        # session entirely. Skip enforcement.
        sys.exit(0)

    if found_required_call:
        log_event({
            "event": "reply_found",
            "stop_hook_active": stop_hook_active,
            "chat_id": chat_id,
        })
        sys.exit(0)

    if not stop_hook_active:
        log_event({"event": "blocking_first_attempt", "chat_id": chat_id})
        print(json.dumps({
            "decision": "block",
            "reason": (
                "This turn is in a dashi-channel/Telegram session and did not "
                "call mcp__dashi-channel__reply (or react/edit_message). Per "
                "the hard rule in CLAUDE.md, the user cannot see plain text - "
                "call mcp__dashi-channel__reply now with the actual response "
                "before ending this turn."
            ),
        }))
        sys.exit(0)

    # Second strike: the block above already fired once this turn and the
    # model still didn't call reply. This is the fallback branch — get the
    # answer to the user some way, then log exactly what happened.
    final_text = "\n\n".join(reversed(assistant_texts_rev)).strip()

    if not chat_id:
        log_event({"event": "fallback_skipped_no_chat_id", "stop_hook_active": True})
        sys.exit(0)

    if not final_text:
        log_event({"event": "fallback_skipped_no_text", "chat_id": chat_id})
        sys.exit(0)

    token = load_bot_token()
    if not token:
        log_event({"event": "fallback_skipped_no_token", "chat_id": chat_id})
        sys.exit(0)

    try:
        send_telegram_message(token, chat_id, final_text)
        log_event({"event": "fallback_sent", "chat_id": chat_id, "chars": len(final_text)})
    except Exception as e:
        log_event({
            "event": "fallback_send_failed",
            "chat_id": chat_id,
            "error": str(e),
            "traceback": traceback.format_exc(),
        })

    sys.exit(0)


if __name__ == "__main__":
    main()
