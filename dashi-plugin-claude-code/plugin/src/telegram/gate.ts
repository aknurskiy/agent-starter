// Inbound + outbound Telegram allowlist gate.
//
// Scope A: static DM allowlist. We replace the official server's dynamic
// access flow (refs/telegram-official/server.ts:222-298) with a stateless
// check against config.allowed_user_ids / config.allowed_chat_ids. Sender id
// (from.id on Telegram's Message) is the authentication primitive — chat.id
// is only a defensive secondary check, because in DMs Telegram sets
// chat.id == user.id and an allowlisted sender cannot reach us through a
// non-DM chat once not_dm fires.
//
// No side effects. Unknown senders, groups, channels, and missing sender all
// drop silently — the caller logs at debug level so authorized-only inboxes
// don't get spammed.
//
// Matches RESEARCH.md:54-57 (gate on sender id, not chat id).
import type { AppConfig } from '../config.js'

export type GateDropReason =
  | 'not_dm'
  | 'missing_sender'
  | 'sender_not_allowed'
  | 'chat_not_allowed'

export type GateDecision =
  | { kind: 'allow'; senderId: string; chatId: string }
  | { kind: 'drop'; reason: GateDropReason }

export interface GateInput {
  chatType: 'private' | 'group' | 'supergroup' | 'channel' | undefined
  chatId: string | undefined
  senderId: string | undefined
  isBot: boolean | undefined
}

// Coerce config ids (number | string) to string for set membership.
function toStringSet(values: ReadonlyArray<number | string>): Set<string> {
  const out = new Set<string>()
  for (const v of values) out.add(String(v))
  return out
}

export function gateTelegramMessage(input: GateInput, config: AppConfig): GateDecision {
  if (input.chatType !== 'private') {
    return { kind: 'drop', reason: 'not_dm' }
  }
  if (input.senderId === undefined || input.senderId === '') {
    return { kind: 'drop', reason: 'missing_sender' }
  }

  const allowedUsers = toStringSet(config.allowed_user_ids)
  if (!allowedUsers.has(input.senderId)) {
    return { kind: 'drop', reason: 'sender_not_allowed' }
  }

  // Defensive secondary check. In Telegram DMs chat.id == user.id, so an
  // already-allowlisted sender writing from their own DM is implicitly
  // trusted — we don't also require their id in allowed_chat_ids (otherwise
  // every student whose chat is their own id would be dropped as
  // chat_not_allowed, since allowed_chat_ids isn't populated from env).
  // For any other chat id we still require an explicit allowlist entry.
  if (input.chatId !== input.senderId) {
    const allowedChats = toStringSet(config.allowed_chat_ids)
    if (input.chatId === undefined || !allowedChats.has(input.chatId)) {
      return { kind: 'drop', reason: 'chat_not_allowed' }
    }
  }

  return { kind: 'allow', senderId: input.senderId, chatId: input.chatId }
}

// Outbound gate. Mirrors refs/telegram-official/server.ts:194-199 but reads
// from config instead of the on-disk allowlist.json. Used by reply/react/
// edit_message/sendDocument to ensure tool calls cannot leak to chats the
// inbound gate would never deliver from.
//
// In DMs chat.id == user.id, so a chat that equals an allowlisted user id is
// implicitly trusted (that's the user's own DM). Otherwise require an explicit
// allowed_chat_ids entry.
export function assertAllowedChat(chatId: string, config: AppConfig): void {
  const allowedChats = toStringSet(config.allowed_chat_ids)
  const allowedUsers = toStringSet(config.allowed_user_ids)
  if (!allowedChats.has(chatId) && !allowedUsers.has(chatId)) {
    throw new Error(`chat ${chatId} is not allowlisted — add to allowed_chat_ids`)
  }
}
