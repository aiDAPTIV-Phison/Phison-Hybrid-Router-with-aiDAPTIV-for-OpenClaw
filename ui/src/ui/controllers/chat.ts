import { extractText } from "../chat/message-extract";
import type { GatewayBrowserClient } from "../gateway";
import { generateUUID } from "../uuid";
import type { ChatAttachment } from "../ui-types";

/** Kept when we append a final message from an event so loadChatHistory doesn't overwrite it. */
export type LastAppendedFinalMessage = {
  runId: string;
  message: unknown;
  at: number;
};

export type ChatRoutingInfo = {
  tier: string;
  model: string;
};

export type ChatState = {
  client: GatewayBrowserClient | null;
  connected: boolean;
  sessionKey: string;
  chatLoading: boolean;
  chatMessages: unknown[];
  chatThinkingLevel: string | null;
  chatSending: boolean;
  chatMessage: string;
  chatAttachments: ChatAttachment[];
  chatRunId: string | null;
  chatStream: string | null;
  chatReasoningStream: string | null;
  chatRoutingInfo: ChatRoutingInfo | null;
  chatStreamStartedAt: number | null;
  lastError: string | null;
  /** If set, loadChatHistory will merge this into the loaded list so compaction/API doesn't drop it. */
  lastAppendedFinalMessage: LastAppendedFinalMessage | null;
};

export type ChatEventPayload = {
  runId: string;
  sessionKey: string;
  state: "delta" | "final" | "aborted" | "error" | "reasoning" | "routing";
  message?: unknown;
  errorMessage?: string;
  reasoningText?: string;
  routingTier?: string;
  routingModel?: string;
};

const LAST_APPENDED_FINAL_TTL_MS = 15_000;

function lastMessageText(messages: unknown[]): string | null {
  if (!Array.isArray(messages) || messages.length === 0) return null;
  const last = messages[messages.length - 1] as Record<string, unknown> | undefined;
  return last ? extractText(last) : null;
}

export async function loadChatHistory(state: ChatState) {
  if (!state.client || !state.connected) return;
  state.chatLoading = true;
  state.lastError = null;
  try {
    const res = (await state.client.request("chat.history", {
      sessionKey: state.sessionKey,
      limit: 200,
    })) as { messages?: unknown[]; thinkingLevel?: string | null };
    let messages = Array.isArray(res.messages) ? res.messages : [];
    const pending = state.lastAppendedFinalMessage;
    if (pending && Date.now() - pending.at < LAST_APPENDED_FINAL_TTL_MS) {
      const appendedText = extractText(pending.message);
      const lastInLoaded = lastMessageText(messages);
      if (
        typeof appendedText === "string" &&
        appendedText.trim() !== "" &&
        appendedText.trim() !== lastInLoaded?.trim()
      ) {
        messages = [...messages, pending.message];
      }
      state.lastAppendedFinalMessage = null;
    }
    state.chatMessages = messages;
    state.chatThinkingLevel = res.thinkingLevel ?? null;
  } catch (err) {
    state.lastError = String(err);
  } finally {
    state.chatLoading = false;
  }
}

function dataUrlToBase64(dataUrl: string): { content: string; mimeType: string } | null {
  const match = /^data:([^;]+);base64,(.+)$/.exec(dataUrl);
  if (!match) return null;
  return { mimeType: match[1], content: match[2] };
}

export async function sendChatMessage(
  state: ChatState,
  message: string,
  attachments?: ChatAttachment[],
): Promise<string | null> {
  if (!state.client || !state.connected) return null;
  const msg = message.trim();
  const hasAttachments = attachments && attachments.length > 0;
  if (!msg && !hasAttachments) return null;

  const now = Date.now();

  // Build user message content blocks
  const contentBlocks: Array<{ type: string; text?: string; source?: unknown }> = [];
  if (msg) {
    contentBlocks.push({ type: "text", text: msg });
  }
  // Add image previews to the message for display
  if (hasAttachments) {
    for (const att of attachments) {
      contentBlocks.push({
        type: "image",
        source: { type: "base64", media_type: att.mimeType, data: att.dataUrl },
      });
    }
  }

  state.chatMessages = [
    ...state.chatMessages,
    {
      role: "user",
      content: contentBlocks,
      timestamp: now,
    },
  ];

  state.chatSending = true;
  state.lastError = null;
  const runId = generateUUID();
  state.chatRunId = runId;
  state.chatStream = "";
  state.chatReasoningStream = null;
  state.chatRoutingInfo = null;
  state.chatStreamStartedAt = now;

  // Convert attachments to API format
  const apiAttachments = hasAttachments
    ? attachments
        .map((att) => {
          const parsed = dataUrlToBase64(att.dataUrl);
          if (!parsed) return null;
          return {
            type: "image",
            mimeType: parsed.mimeType,
            content: parsed.content,
          };
        })
        .filter((a): a is NonNullable<typeof a> => a !== null)
    : undefined;

  try {
    await state.client.request("chat.send", {
      sessionKey: state.sessionKey,
      message: msg,
      deliver: false,
      idempotencyKey: runId,
      attachments: apiAttachments,
    });
    return runId;
  } catch (err) {
    const error = String(err);
    state.chatRunId = null;
    state.chatStream = null;
    state.chatReasoningStream = null;
    state.chatRoutingInfo = null;
    state.chatStreamStartedAt = null;
    state.lastError = error;
    state.chatMessages = [
      ...state.chatMessages,
      {
        role: "assistant",
        content: [{ type: "text", text: "Error: " + error }],
        timestamp: Date.now(),
      },
    ];
    return null;
  } finally {
    state.chatSending = false;
  }
}

export async function abortChatRun(state: ChatState): Promise<boolean> {
  if (!state.client || !state.connected) return false;
  const runId = state.chatRunId;
  try {
    await state.client.request(
      "chat.abort",
      runId ? { sessionKey: state.sessionKey, runId } : { sessionKey: state.sessionKey },
    );
    return true;
  } catch (err) {
    state.lastError = String(err);
    return false;
  }
}

export function handleChatEvent(state: ChatState, payload?: ChatEventPayload) {
  if (!payload) return null;
  if (payload.sessionKey !== state.sessionKey) return null;

  const isOtherRun =
    payload.runId && state.chatRunId && payload.runId !== state.chatRunId;

  // Final from another run (e.g. cron, sub-agent): show final message immediately and clear stream.
  // See https://github.com/openclaw/openclaw/issues/1909
  if (isOtherRun && payload.state === "final") {
    const finalText = payload.message != null ? extractText(payload.message) : null;
    const hasContent =
      typeof finalText === "string" &&
      finalText.trim() !== "" &&
      finalText.trim() !== "NO_REPLY";
    if (hasContent) {
      state.chatStream = null;
      state.chatReasoningStream = null;
      state.chatRunId = null;
      state.chatStreamStartedAt = null;
      const msg = payload.message as Record<string, unknown> | undefined;
      if (msg && typeof msg.role === "string" && msg.role.toLowerCase() === "assistant") {
        const entry = {
          ...msg,
          timestamp: typeof msg.timestamp === "number" ? msg.timestamp : Date.now(),
        };
        state.chatMessages = [...state.chatMessages, entry];
        state.lastAppendedFinalMessage = {
          runId: payload.runId,
          message: entry,
          at: Date.now(),
        };
      }
    }
    return "final";
  }

  // Delta/reasoning from another run (e.g. cron): show in current session and treat as that run's stream.
  if (isOtherRun && (payload.state === "delta" || payload.state === "reasoning")) {
    state.chatRunId = payload.runId;
    state.chatStreamStartedAt = state.chatStreamStartedAt ?? Date.now();
  }

  if (payload.state === "routing") {
    if (payload.routingTier && payload.routingModel) {
      state.chatRoutingInfo = {
        tier: payload.routingTier,
        model: payload.routingModel,
      };
    }
    return payload.state;
  }

  if (payload.state === "reasoning") {
    if (payload.reasoningText) {
      state.chatReasoningStream = payload.reasoningText;
    }
  } else if (payload.state === "delta") {
    const next = extractText(payload.message);
    if (typeof next === "string") {
      const current = state.chatStream ?? "";
      // From another run (e.g. cron): replace stream so cron output is shown. Same run: append only.
      if (isOtherRun) {
        state.chatStream = next;
      } else if (!current || next.length >= current.length) {
        state.chatStream = next;
      }
    }
  } else if (payload.state === "final") {
    const finalText = payload.message != null ? extractText(payload.message) : null;
    const hasContent =
      typeof finalText === "string" &&
      finalText.trim() !== "" &&
      finalText.trim() !== "NO_REPLY";
    if (hasContent) {
      const msg = payload.message as Record<string, unknown> | undefined;
      if (msg && typeof msg.role === "string" && msg.role.toLowerCase() === "assistant") {
        const entry = {
          ...msg,
          timestamp: typeof msg.timestamp === "number" ? msg.timestamp : Date.now(),
        };
        state.chatMessages = [...state.chatMessages, entry];
        state.lastAppendedFinalMessage = {
          runId: payload.runId,
          message: entry,
          at: Date.now(),
        };
      }
    }
    state.chatStream = null;
    state.chatReasoningStream = null;
    state.chatRunId = null;
    state.chatStreamStartedAt = null;
  } else if (payload.state === "aborted") {
    state.chatStream = null;
    state.chatReasoningStream = null;
    state.chatRunId = null;
    state.chatStreamStartedAt = null;
  } else if (payload.state === "error") {
    state.chatStream = null;
    state.chatReasoningStream = null;
    state.chatRunId = null;
    state.chatStreamStartedAt = null;
    state.lastError = payload.errorMessage ?? "chat error";
  }
  return payload.state;
}
