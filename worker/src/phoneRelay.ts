/**
 * Dottie's own Telegram bot, so pairing a phone is one tap: no BotFather,
 * no token to copy. One bot (TELEGRAM_BOT_TOKEN) serves every Mac.
 *
 * - Each Mac makes a random install key once and sends it as
 *   x-dottie-phone-key. Its mailbox is the Durable Object named by the
 *   key's SHA-256, so only that Mac can read it.
 * - POST /phone/pair gives the Mac a one-time code and a t.me link
 *   (https://t.me/<bot>?start=<code>). Opening it in Telegram sends
 *   "/start <code>", which the webhook matches to that Mac and from then
 *   on routes that chat's messages and button taps into its mailbox.
 * - POST /phone/telegram/<method> is the Bot API for the Mac: getUpdates
 *   long-polls its mailbox (same answer shape as Telegram's), getMe answers
 *   from Telegram, and the send methods go to Telegram with chat_id forced
 *   to the Mac's own paired chat, so a Mac can only ever text its owner.
 * - POST /phone/unpair forgets the chat.
 * - POST /telegram/webhook is Telegram's, checked with a secret token
 *   derived from the bot token. The webhook is set by the first /phone/pair.
 */

export interface PhoneRelayEnv {
  TELEGRAM_BOT_TOKEN?: string;
  PHONE_RELAY: DurableObjectNamespace;
}

const SEND_METHODS = new Set([
  "sendMessage",
  "sendPhoto",
  "sendDocument",
  "editMessageReplyMarkup",
  "answerCallbackQuery",
  "sendChatAction",
]);

/** How long a pairing code works. */
const PAIRING_CODE_LIFETIME_MS = 15 * 60 * 1000;
/** Most messages kept for a Mac that's asleep. */
const MAXIMUM_QUEUED_UPDATES = 200;
/** How long getUpdates waits for something new before answering empty. */
const LONG_POLL_MS = 25_000;

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function telegramURL(env: PhoneRelayEnv, method: string): string {
  return `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`;
}

async function callTelegram(env: PhoneRelayEnv, method: string, parameters: Record<string, unknown>): Promise<any> {
  const response = await fetch(telegramURL(env, method), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(parameters),
  });
  return response.json().catch(() => ({ ok: false }));
}

/** Telegram sends this back on every webhook call, so strangers can't post fake updates. */
async function webhookSecret(env: PhoneRelayEnv): Promise<string> {
  return (await sha256Hex(`dottie-webhook:${env.TELEGRAM_BOT_TOKEN}`)).slice(0, 48);
}

function directory(env: PhoneRelayEnv): DurableObjectStub {
  return env.PHONE_RELAY.get(env.PHONE_RELAY.idFromName("directory"));
}

function mailbox(env: PhoneRelayEnv, mailboxName: string): DurableObjectStub {
  return env.PHONE_RELAY.get(env.PHONE_RELAY.idFromName(`mailbox:${mailboxName}`));
}

async function askObject(stub: DurableObjectStub, action: string, body: unknown = {}): Promise<any> {
  const response = await stub.fetch(`https://phone-relay/${action}`, { method: "POST", body: JSON.stringify(body) });
  return response.json();
}

/** Routes under /phone/ (the Mac) and /telegram/webhook (Telegram). Returns null for other paths. */
export async function handlePhoneRelay(request: Request, url: URL, env: PhoneRelayEnv): Promise<Response | null> {
  if (url.pathname === "/telegram/webhook") {
    if (!env.TELEGRAM_BOT_TOKEN) return new Response("Not found", { status: 404 });
    if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== (await webhookSecret(env))) {
      return new Response("Unauthorized", { status: 401 });
    }
    const update = await request.json().catch(() => null);
    if (update) await routeTelegramUpdate(update, env);
    return json({ ok: true });
  }

  if (!url.pathname.startsWith("/phone/")) return null;
  if (!env.TELEGRAM_BOT_TOKEN) {
    return json({ ok: false, description: "This Dottie server has no phone bot yet (TELEGRAM_BOT_TOKEN)." }, 503);
  }
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const installKey = request.headers.get("x-dottie-phone-key") ?? "";
  if (installKey.length < 32) return json({ ok: false, description: "Missing install key." }, 401);
  const mailboxName = await sha256Hex(installKey);

  if (url.pathname === "/phone/pair") {
    return await startPairing(url, env, mailboxName);
  }
  if (url.pathname === "/phone/unpair") {
    const forgotten = await askObject(mailbox(env, mailboxName), "unpair");
    if (forgotten.chatID) await askObject(directory(env), "forgetChat", { chatID: forgotten.chatID });
    return json({ ok: true });
  }
  if (url.pathname.startsWith("/phone/telegram/")) {
    const method = url.pathname.slice("/phone/telegram/".length);
    return await relayBotMethod(request, method, env, mailboxName);
  }
  return new Response("Not found", { status: 404 });
}

async function startPairing(url: URL, env: PhoneRelayEnv, mailboxName: string): Promise<Response> {
  const directoryStub = directory(env);
  // The bot's username and the webhook, set up once per bot token.
  const tokenFingerprint = (await sha256Hex(env.TELEGRAM_BOT_TOKEN!)).slice(0, 16);
  const webhookURL = `${url.origin}/telegram/webhook`;
  let botInfo = await askObject(directoryStub, "getBotInfo", { tokenFingerprint, webhookURL });
  if (!botInfo.username) {
    const me = await callTelegram(env, "getMe", {});
    if (!me.ok) return json({ ok: false, description: "Telegram didn't accept the bot token." }, 502);
    const webhook = await callTelegram(env, "setWebhook", {
      url: webhookURL,
      secret_token: await webhookSecret(env),
      allowed_updates: ["message", "callback_query"],
    });
    if (!webhook.ok) return json({ ok: false, description: `Telegram didn't take the webhook: ${webhook.description ?? ""}` }, 502);
    botInfo = { username: me.result.username };
    await askObject(directoryStub, "setBotInfo", { tokenFingerprint, webhookURL, username: me.result.username });
  }

  // 12 random letters and digits: unguessable, and fits Telegram's start
  // parameter (A-Z, a-z, 0-9, _ and -).
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const randomBytes = crypto.getRandomValues(new Uint8Array(12));
  const pairingCode = [...randomBytes].map((byte) => alphabet[byte % alphabet.length]).join("");
  await askObject(directoryStub, "addCode", { pairingCode, mailboxName });
  return json({
    ok: true,
    pairingCode,
    botUsername: botInfo.username,
    link: `https://t.me/${botInfo.username}?start=${pairingCode}`,
  });
}

/** A Telegram update from the webhook: pairing, or into the paired Mac's mailbox. */
async function routeTelegramUpdate(update: any, env: PhoneRelayEnv): Promise<void> {
  const message = update.message;
  const callbackQuery = update.callback_query;
  const chat = message?.chat ?? callbackQuery?.message?.chat;
  if (!chat || chat.type !== "private") return;
  const chatID: number = chat.id;
  const directoryStub = directory(env);
  const text: string = (message?.text ?? "").trim();

  const startMatch = /^\/start(?:@\w+)?\s+([A-Za-z0-9_-]{8,64})$/.exec(text);
  if (startMatch) {
    const claimed = await askObject(directoryStub, "claimCode", { pairingCode: startMatch[1], chatID });
    if (!claimed.mailboxName) {
      await callTelegram(env, "sendMessage", {
        chat_id: chatID,
        text: "That link has expired. In Dottie on your Mac, open Home → Phone and tap Connect again.",
      });
      return;
    }
    await askObject(mailbox(env, claimed.mailboxName), "pair", { chatID });
    if (claimed.previousMailboxName && claimed.previousMailboxName !== claimed.mailboxName) {
      await askObject(mailbox(env, claimed.previousMailboxName), "unpair");
    }
    // The /start message itself goes to the Mac, which finishes pairing.
    await askObject(mailbox(env, claimed.mailboxName), "push", { update });
    return;
  }

  const routed = await askObject(directoryStub, "mailboxForChat", { chatID });
  if (!routed.mailboxName) {
    await callTelegram(env, "sendMessage", {
      chat_id: chatID,
      text: "Hi! I'm Dottie. To text your Mac, open Dottie → Home → Phone and tap Connect (or scan the code there).",
    });
    if (callbackQuery?.id) await callTelegram(env, "answerCallbackQuery", { callback_query_id: callbackQuery.id });
    return;
  }
  await askObject(mailbox(env, routed.mailboxName), "push", { update });
}

/** The Bot API, as one Mac may use it. */
async function relayBotMethod(request: Request, method: string, env: PhoneRelayEnv, mailboxName: string): Promise<Response> {
  const mailboxStub = mailbox(env, mailboxName);
  if (method === "getUpdates") {
    const parameters = await request.json<any>().catch(() => ({}));
    const answer = await mailboxStub.fetch("https://phone-relay/updates", {
      method: "POST",
      body: JSON.stringify({ offset: Number(parameters.offset ?? 0) }),
    });
    return new Response(answer.body, { headers: { "Content-Type": "application/json" } });
  }
  if (method === "getMe") {
    return json(await callTelegram(env, "getMe", {}));
  }
  if (!SEND_METHODS.has(method)) return json({ ok: false, description: "Not allowed." }, 403);

  const paired = await askObject(mailboxStub, "pairedChat");
  if (!paired.chatID) return json({ ok: false, description: "No phone is paired." }, 409);

  const contentType = request.headers.get("Content-Type") ?? "";
  let upstream: Response;
  if (contentType.startsWith("multipart/form-data")) {
    // Photos and files (up to 50 MB) stream straight through instead of
    // being parsed here; the chat goes in the address, and the Mac leaves
    // it out of the form.
    const target = new URL(telegramURL(env, method));
    target.searchParams.set("chat_id", String(paired.chatID));
    upstream = await fetch(target.toString(), {
      method: "POST",
      headers: { "Content-Type": contentType },
      body: request.body,
    });
  } else {
    const parameters = await request.json<Record<string, unknown>>().catch(() => ({}));
    if (method !== "answerCallbackQuery") parameters.chat_id = paired.chatID;
    upstream = await fetch(telegramURL(env, method), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(parameters),
    });
  }
  return new Response(upstream.body, { status: upstream.status, headers: { "Content-Type": "application/json" } });
}

/**
 * One class, two kinds of instance: "directory" (pairing codes, which chat
 * belongs to which Mac, the bot's username) and "mailbox:<hash>" (one Mac's
 * paired chat and its waiting updates).
 */
export class PhoneRelay {
  private waiters: Array<() => void> = [];

  constructor(private state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const action = new URL(request.url).pathname.slice(1);
    const body = await request.json<any>().catch(() => ({}));
    const storage = this.state.storage;

    switch (action) {
      // Directory
      case "getBotInfo": {
        const saved = await storage.get<any>("botInfo");
        const isCurrent = saved && saved.tokenFingerprint === body.tokenFingerprint && saved.webhookURL === body.webhookURL;
        return json(isCurrent ? { username: saved.username } : {});
      }
      case "setBotInfo":
        await storage.put("botInfo", body);
        return json({ ok: true });
      case "addCode":
        await storage.put(`code:${body.pairingCode}`, { mailboxName: body.mailboxName, expiresAt: Date.now() + PAIRING_CODE_LIFETIME_MS });
        return json({ ok: true });
      case "claimCode": {
        const codeKey = `code:${body.pairingCode}`;
        const saved = await storage.get<any>(codeKey);
        await storage.delete(codeKey);
        if (!saved || saved.expiresAt < Date.now()) return json({});
        const chatKey = `chat:${body.chatID}`;
        const previousMailboxName = await storage.get<string>(chatKey);
        await storage.put(chatKey, saved.mailboxName);
        return json({ mailboxName: saved.mailboxName, previousMailboxName });
      }
      case "mailboxForChat":
        return json({ mailboxName: (await storage.get<string>(`chat:${body.chatID}`)) ?? null });
      case "forgetChat":
        await storage.delete(`chat:${body.chatID}`);
        return json({ ok: true });

      // Mailbox
      case "pair":
        await storage.put("chatID", body.chatID);
        return json({ ok: true });
      case "unpair": {
        const chatID = await storage.get<number>("chatID");
        await storage.delete("chatID");
        return json({ chatID: chatID ?? null });
      }
      case "pairedChat":
        return json({ chatID: (await storage.get<number>("chatID")) ?? null });
      case "push": {
        const nextUpdateID = ((await storage.get<number>("nextUpdateID")) ?? 1);
        const queue = (await storage.get<any[]>("queue")) ?? [];
        // Each Mac gets its own numbering, so its getUpdates offset works
        // the way Telegram's does.
        queue.push({ ...body.update, update_id: nextUpdateID });
        while (queue.length > MAXIMUM_QUEUED_UPDATES) queue.shift();
        await storage.put({ queue, nextUpdateID: nextUpdateID + 1 });
        const waiting = this.waiters;
        this.waiters = [];
        waiting.forEach((wake) => wake());
        return json({ ok: true });
      }
      case "updates": {
        const offset = Number(body.offset ?? 0);
        const pending = async () => {
          let queue = (await storage.get<any[]>("queue")) ?? [];
          const remaining = queue.filter((update) => update.update_id >= offset);
          if (remaining.length !== queue.length) await storage.put("queue", remaining);
          queue = remaining;
          return queue.slice(0, 50);
        };
        let result = await pending();
        if (result.length === 0) {
          await new Promise<void>((resolve) => {
            const timer = setTimeout(resolve, LONG_POLL_MS);
            this.waiters.push(() => {
              clearTimeout(timer);
              resolve();
            });
          });
          result = await pending();
        }
        return json({ ok: true, result });
      }
    }
    return json({ ok: false }, 404);
  }
}
