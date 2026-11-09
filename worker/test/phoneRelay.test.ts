import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/index";
import { makePairingCode } from "../src/phoneRelay";
import { fakeFetch, jsonAnswer, makeEnv, type RecordedCall } from "./helpers";

const BOT_TOKEN = "123456:test-bot-token";
let installKeyCounter = 0;

/** A fresh Mac for each test, so tests never share a mailbox. */
function newInstallKey(): string {
  installKeyCounter += 1;
  return `install-key-${installKeyCounter}-${crypto.randomUUID()}`;
}

async function webhookSecret(botToken = BOT_TOKEN): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`dottie-webhook:${botToken}`));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("").slice(0, 48);
}

const phoneEnv = (overrides: Partial<Env> = {}) => makeEnv({ TELEGRAM_BOT_TOKEN: BOT_TOKEN, ...overrides });

function fromMac(path: string, installKey: string | undefined, body?: unknown, options: { method?: string; env?: Env; contentType?: string } = {}) {
  const headers: Record<string, string> = {};
  if (installKey !== undefined) headers["x-dottie-phone-key"] = installKey;
  if (options.contentType) headers["content-type"] = options.contentType;
  const method = options.method ?? "POST";
  const request = new Request(`https://worker.test${path}`, {
    method,
    headers,
    body: method === "GET" ? undefined : typeof body === "string" ? body : JSON.stringify(body ?? {}),
  });
  return worker.fetch(request, options.env ?? phoneEnv());
}

async function fromTelegram(update: unknown, options: { secret?: string; env?: Env } = {}) {
  const request = new Request("https://worker.test/telegram/webhook", {
    method: "POST",
    headers: { "X-Telegram-Bot-Api-Secret-Token": options.secret ?? (await webhookSecret()) },
    body: typeof update === "string" ? update : JSON.stringify(update),
  });
  return worker.fetch(request, options.env ?? phoneEnv());
}

const privateMessage = (chatID: number, text: string) => ({ update_id: 900, message: { text, chat: { id: chatID, type: "private" } } });

/** Telegram, faked: getMe names the bot, everything else says ok. */
function fakeTelegram(extraRules: Parameters<typeof fakeFetch>[0] = []): RecordedCall[] {
  return fakeFetch([
    ...extraRules,
    ["/getMe", jsonAnswer({ ok: true, result: { username: "dottie_test_bot" } })],
    ["api.telegram.org", jsonAnswer({ ok: true, result: {} })],
  ]);
}

const telegramCalls = (calls: RecordedCall[], method: string) => calls.filter((call) => call.url.endsWith(`/${method}`) || call.url.includes(`/${method}?`));

/** Pairs a new Mac with a chat and returns its install key. */
async function pairedMac(chatID: number): Promise<string> {
  const installKey = newInstallKey();
  const pairing = (await (await fromMac("/phone/pair", installKey)).json()) as { pairingCode: string };
  await fromTelegram(privateMessage(chatID, `/start ${pairing.pairingCode}`));
  return installKey;
}

async function updatesFor(installKey: string, offset = 0): Promise<any[]> {
  const response = await fromMac("/phone/telegram/getUpdates", installKey, { offset });
  return ((await response.json()) as { result: any[] }).result;
}

/** One Mac's mailbox object, asked directly with a short wait instead of the real 25 seconds. */
async function quickUpdatesFor(installKey: string, offset: number, longPollMilliseconds: number): Promise<any[]> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(installKey));
  const mailboxName = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  const env = phoneEnv();
  const stub = env.PHONE_RELAY.get(env.PHONE_RELAY.idFromName(`mailbox:${mailboxName}`));
  const response = await stub.fetch("https://phone-relay/updates", { method: "POST", body: JSON.stringify({ offset, longPollMilliseconds }) });
  return ((await response.json()) as { result: any[] }).result;
}

let nextChatID = 5000;
const newChatID = () => (nextChatID += 1);

beforeEach(() => {
  fakeTelegram();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("makePairingCode", () => {
  it("is 12 characters from the alphabet, with no look-alikes", () => {
    for (let attempt = 0; attempt < 200; attempt += 1) {
      expect(makePairingCode()).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
    }
  });

  it("is different every time", () => {
    const codes = new Set(Array.from({ length: 500 }, () => makePairingCode()));
    expect(codes.size).toBe(500);
  });

  it("throws away bytes that would make some characters likelier", () => {
    // 255 is past the last whole run of the 57-character alphabet (228), so it's skipped; 0 gives "A".
    let callCount = 0;
    vi.spyOn(crypto, "getRandomValues").mockImplementation(((bytes: Uint8Array) => {
      callCount += 1;
      bytes.fill(callCount === 1 ? 255 : 0);
      return bytes;
    }) as typeof crypto.getRandomValues);
    expect(makePairingCode()).toBe("A".repeat(12));
    expect(callCount).toBe(2);
  });
});

describe("requests from the Mac", () => {
  it("answers 503 when the server has no bot", async () => {
    const response = await fromMac("/phone/pair", newInstallKey(), {}, { env: makeEnv() });
    expect(response.status).toBe(503);
    expect(((await response.json()) as any).ok).toBe(false);
  });

  it("answers 405 for a GET", async () => {
    expect((await fromMac("/phone/pair", newInstallKey(), undefined, { method: "GET" })).status).toBe(405);
  });

  it("answers 401 without an install key, or with one that's too short", async () => {
    expect((await fromMac("/phone/pair", undefined)).status).toBe(401);
    expect((await fromMac("/phone/pair", "short")).status).toBe(401);
  });

  it("answers 404 for an unknown phone path", async () => {
    expect((await fromMac("/phone/nothing", newInstallKey())).status).toBe(404);
  });

  it("is still behind the shared secret", async () => {
    const response = await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ APP_SHARED_SECRET: "s" }) });
    expect(response.status).toBe(401);
  });
});

describe("POST /phone/pair", () => {
  it("gives a code and a link, and sets the webhook the first time", async () => {
    const env = phoneEnv({ TELEGRAM_BOT_TOKEN: "first-time:token" });
    const calls = fakeTelegram();
    const response = await fromMac("/phone/pair", newInstallKey(), {}, { env });
    const pairing = (await response.json()) as any;
    expect(pairing.ok).toBe(true);
    expect(pairing.botUsername).toBe("dottie_test_bot");
    expect(pairing.link).toBe(`https://t.me/dottie_test_bot?start=${pairing.pairingCode}`);
    const setWebhook = telegramCalls(calls, "setWebhook")[0];
    expect(setWebhook.url).toBe("https://api.telegram.org/botfirst-time:token/setWebhook");
    expect(setWebhook.json).toEqual({
      url: "https://worker.test/telegram/webhook",
      secret_token: await webhookSecret("first-time:token"),
      allowed_updates: ["message", "callback_query"],
    });

    // The second pairing reuses what was saved.
    const laterCalls = fakeTelegram();
    await fromMac("/phone/pair", newInstallKey(), {}, { env });
    expect(laterCalls).toHaveLength(0);
  });

  it("sets the webhook again when the bot token changes", async () => {
    await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "old:token" }) });
    const calls = fakeTelegram();
    await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "new:token" }) });
    expect(telegramCalls(calls, "setWebhook")).toHaveLength(1);
  });

  it("answers 502 when Telegram turns the token down", async () => {
    fakeFetch([["/getMe", jsonAnswer({ ok: false, description: "Unauthorized" })]]);
    const response = await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "bad:token" }) });
    expect(response.status).toBe(502);
    expect(((await response.json()) as any).description).toContain("didn't accept the bot token");
  });

  it("answers 502 when Telegram's answer isn't JSON, or has no username", async () => {
    fakeFetch([["/getMe", new Response("<html>bad gateway</html>")]]);
    expect((await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "html:token" }) })).status).toBe(502);
    fakeFetch([["/getMe", jsonAnswer({ ok: true, result: {} })]]);
    expect((await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "nameless:token" }) })).status).toBe(502);
  });

  it("answers 502 when Telegram won't take the webhook", async () => {
    fakeTelegram([["/setWebhook", jsonAnswer({ ok: false, description: "bad webhook: HTTPS required" })]]);
    const response = await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "webhook:token" }) });
    expect(response.status).toBe(502);
    expect(((await response.json()) as any).description).toContain("HTTPS required");
    fakeTelegram([["/setWebhook", jsonAnswer({ ok: false })]]);
    expect((await fromMac("/phone/pair", newInstallKey(), {}, { env: phoneEnv({ TELEGRAM_BOT_TOKEN: "webhook2:token" }) })).status).toBe(502);
  });
});

describe("POST /telegram/webhook", () => {
  it("turns away a call without Telegram's secret", async () => {
    expect((await fromTelegram(privateMessage(1, "hi"), { secret: "wrong" })).status).toBe(401);
    const noHeader = new Request("https://worker.test/telegram/webhook", { method: "POST", body: "{}" });
    expect((await worker.fetch(noHeader, phoneEnv())).status).toBe(401);
  });

  it("isn't behind the app's shared secret, since Telegram can't send it", async () => {
    const response = await fromTelegram(privateMessage(newChatID(), "hi"), { env: phoneEnv({ APP_SHARED_SECRET: "s" }) });
    expect(response.status).toBe(200);
  });

  it("answers ok for a body that isn't JSON or isn't an update", async () => {
    const calls = fakeTelegram();
    expect(await (await fromTelegram("not json")).json()).toEqual({ ok: true });
    expect(await (await fromTelegram("5")).json()).toEqual({ ok: true });
    expect(calls).toHaveLength(0);
  });

  it("ignores updates with no chat, and group chats", async () => {
    const calls = fakeTelegram();
    await fromTelegram({ update_id: 1 });
    await fromTelegram({ update_id: 2, message: { text: "hi", chat: { id: -100, type: "group" } } });
    expect(calls).toHaveLength(0);
  });

  it("tells a chat nobody paired how to connect", async () => {
    const calls = fakeTelegram();
    const chatID = newChatID();
    await fromTelegram(privateMessage(chatID, "hello?"));
    const sent = telegramCalls(calls, "sendMessage");
    expect(sent).toHaveLength(1);
    expect(sent[0].json.chat_id).toBe(chatID);
    expect(sent[0].json.text).toContain("Home → Phone");
    expect(telegramCalls(calls, "answerCallbackQuery")).toHaveLength(0);
  });

  it("answers an unpaired chat's button tap so it stops spinning", async () => {
    const calls = fakeTelegram();
    await fromTelegram({ update_id: 3, callback_query: { id: "tap-1", message: { chat: { id: newChatID(), type: "private" } } } });
    expect(telegramCalls(calls, "answerCallbackQuery")[0].json).toEqual({ callback_query_id: "tap-1" });
  });

  it("says the link expired for a code nobody made", async () => {
    const calls = fakeTelegram();
    await fromTelegram(privateMessage(newChatID(), "/start NotARealCode123"));
    expect(telegramCalls(calls, "sendMessage")[0].json.text).toContain("expired");
  });

  it("says the link expired for a code older than 15 minutes", async () => {
    const installKey = newInstallKey();
    const pairing = (await (await fromMac("/phone/pair", installKey)).json()) as { pairingCode: string };
    const realNow = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(realNow + 16 * 60 * 1000);
    const calls = fakeTelegram();
    await fromTelegram(privateMessage(newChatID(), `/start ${pairing.pairingCode}`));
    expect(telegramCalls(calls, "sendMessage")[0].json.text).toContain("expired");
  });

  it("doesn't take text that only looks like a pairing command", async () => {
    const installKey = newInstallKey();
    const pairing = (await (await fromMac("/phone/pair", installKey)).json()) as { pairingCode: string };
    const calls = fakeTelegram();
    const chatID = newChatID();
    await fromTelegram(privateMessage(chatID, `please /start ${pairing.pairingCode}`));
    await fromTelegram(privateMessage(chatID, "/start short"));
    await fromTelegram(privateMessage(chatID, "/start"));
    expect(telegramCalls(calls, "sendMessage").every((sent) => sent.json.text.includes("Home → Phone"))).toBe(true);
  });
});

describe("pairing a phone", () => {
  it("pairs with the link's /start message, which also reaches the Mac", async () => {
    const chatID = newChatID();
    const installKey = newInstallKey();
    const pairing = (await (await fromMac("/phone/pair", installKey)).json()) as { pairingCode: string };
    await fromTelegram(privateMessage(chatID, `/start@dottie_test_bot ${pairing.pairingCode}`));
    const updates = await updatesFor(installKey);
    expect(updates).toHaveLength(1);
    expect(updates[0].message.text).toBe(`/start@dottie_test_bot ${pairing.pairingCode}`);
    expect(updates[0].update_id).toBe(1);
  });

  it("uses a code once", async () => {
    const installKey = newInstallKey();
    const pairing = (await (await fromMac("/phone/pair", installKey)).json()) as { pairingCode: string };
    await fromTelegram(privateMessage(newChatID(), `/start ${pairing.pairingCode}`));
    const calls = fakeTelegram();
    await fromTelegram(privateMessage(newChatID(), `/start ${pairing.pairingCode}`));
    expect(telegramCalls(calls, "sendMessage")[0].json.text).toContain("expired");
  });

  it("moves a chat that pairs with a second Mac off the first", async () => {
    const chatID = newChatID();
    const firstMac = await pairedMac(chatID);
    const secondMac = newInstallKey();
    const pairing = (await (await fromMac("/phone/pair", secondMac)).json()) as { pairingCode: string };
    await fromTelegram(privateMessage(chatID, `/start ${pairing.pairingCode}`));

    await fromTelegram(privateMessage(chatID, "who gets this?"));
    const secondMacUpdates = await updatesFor(secondMac);
    expect(secondMacUpdates.map((update) => update.message.text)).toContain("who gets this?");
    expect((await fromMac("/phone/telegram/sendMessage", firstMac, { text: "hi" })).status).toBe(409);
  });

  it("keeps the pairing when the same Mac pairs the same chat again", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    const pairing = (await (await fromMac("/phone/pair", installKey)).json()) as { pairingCode: string };
    await fromTelegram(privateMessage(chatID, `/start ${pairing.pairingCode}`));
    expect((await fromMac("/phone/telegram/sendMessage", installKey, { text: "still here" })).status).toBe(200);
  });

  it("clears out codes nobody used when a new one is made", async () => {
    const env = phoneEnv();
    const staleKey = newInstallKey();
    const stalePairing = (await (await fromMac("/phone/pair", staleKey, {}, { env })).json()) as { pairingCode: string };
    const realNow = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(realNow + 20 * 60 * 1000);
    await fromMac("/phone/pair", newInstallKey(), {}, { env });
    vi.restoreAllMocks();
    // Back at the real time the old code would still be young enough, had it not been cleared.
    const calls = fakeTelegram();
    await fromTelegram(privateMessage(newChatID(), `/start ${stalePairing.pairingCode}`));
    expect(telegramCalls(calls, "sendMessage")[0].json.text).toContain("expired");
  });
});

describe("POST /phone/unpair", () => {
  it("forgets the chat on both sides", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    expect(await (await fromMac("/phone/unpair", installKey)).json()).toEqual({ ok: true });
    expect((await fromMac("/phone/telegram/sendMessage", installKey, { text: "hi" })).status).toBe(409);
    const calls = fakeTelegram();
    await fromTelegram(privateMessage(chatID, "anyone?"));
    expect(telegramCalls(calls, "sendMessage")[0].json.text).toContain("Home → Phone");
  });

  it("is fine for a Mac that was never paired", async () => {
    expect(await (await fromMac("/phone/unpair", newInstallKey())).json()).toEqual({ ok: true });
  });
});

describe("the mailbox (getUpdates)", () => {
  it("delivers messages in order with the Mac's own numbering, and drops them once acknowledged", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    await fromTelegram(privateMessage(chatID, "first"));
    await fromTelegram({ update_id: 77, callback_query: { id: "tap", data: "allow", message: { chat: { id: chatID, type: "private" } } } });

    const updates = await updatesFor(installKey);
    expect(updates.map((update) => update.update_id)).toEqual([1, 2, 3]);
    expect(updates[1].message.text).toBe("first");
    expect(updates[2].callback_query.data).toBe("allow");

    // Asking from 3 on acknowledges 1 and 2.
    expect((await updatesFor(installKey, 3)).map((update) => update.update_id)).toEqual([3]);
    expect((await updatesFor(installKey, 0)).map((update) => update.update_id)).toEqual([3]);
  });

  it("gives another Mac nothing", async () => {
    const chatID = newChatID();
    await pairedMac(chatID);
    await fromTelegram(privateMessage(chatID, "private to the first Mac"));
    expect(await quickUpdatesFor(newInstallKey(), 0, 30)).toEqual([]);
  });

  it("waits for a message and answers as soon as one arrives", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    const waiting = updatesFor(installKey, 2);
    await new Promise((resolve) => setTimeout(resolve, 20));
    await fromTelegram(privateMessage(chatID, "wake up"));
    const updates = await waiting;
    expect(updates).toHaveLength(1);
    expect(updates[0].message.text).toBe("wake up");
  });

  it("answers empty when the wait runs out with nothing new, and a later message still wakes the next wait", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    expect(await quickUpdatesFor(installKey, 2, 30)).toEqual([]);
    expect(await quickUpdatesFor(installKey, 2, 30)).toEqual([]);

    const secondWait = updatesFor(installKey, 2);
    await new Promise((resolve) => setTimeout(resolve, 20));
    await fromTelegram(privateMessage(chatID, "after the timeout"));
    expect((await secondWait)[0].message.text).toBe("after the timeout");
  });

  it("treats a missing or broken body as offset 0", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    const response = await fromMac("/phone/telegram/getUpdates", installKey, "not json");
    expect(((await response.json()) as { result: unknown[] }).result).toHaveLength(1);
  });

  it("keeps at most 200 waiting messages, dropping the oldest", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    for (let index = 0; index < 205; index += 1) {
      await fromTelegram(privateMessage(chatID, `message ${index}`));
    }
    const firstPage = await updatesFor(installKey);
    // 206 pushed (the /start and 205 messages): the first 6 are gone.
    expect(firstPage).toHaveLength(50);
    expect(firstPage[0].update_id).toBe(7);
    expect(firstPage[0].message.text).toBe("message 5");
  });

  it("drops the oldest messages when the queue is too big to save, keeping the newest", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    const bigText = "x".repeat(300_000);
    for (let index = 0; index < 5; index += 1) {
      await fromTelegram(privateMessage(chatID, `${index}${bigText}`));
    }
    const updates = await updatesFor(installKey);
    expect(updates.length).toBeLessThanOrEqual(3);
    expect(updates.at(-1).message.text.startsWith("4")).toBe(true);
    expect(JSON.stringify(updates).length).toBeLessThanOrEqual(1_000_000);
  });
});

describe("POST /phone/telegram/<method>", () => {
  it("answers getMe from Telegram", async () => {
    const response = await fromMac("/phone/telegram/getMe", newInstallKey());
    expect(await response.json()).toEqual({ ok: true, result: { username: "dottie_test_bot" } });
  });

  it.each(["deleteWebhook", "getChat", "banChatMember", "setWebhook", ""])("refuses the method %j", async (method) => {
    const installKey = await pairedMac(newChatID());
    const calls = fakeTelegram();
    const response = await fromMac(`/phone/telegram/${method}`, installKey, { chat_id: 1 });
    expect(response.status).toBe(403);
    expect(calls).toHaveLength(0);
  });

  it("answers 409 when no phone is paired", async () => {
    const response = await fromMac("/phone/telegram/sendMessage", newInstallKey(), { text: "hi" });
    expect(response.status).toBe(409);
  });

  it("sends only to the Mac's own chat, whatever chat the Mac names", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    const calls = fakeTelegram();
    const response = await fromMac("/phone/telegram/sendMessage", installKey, { chat_id: 999_999, text: "hello" });
    expect(response.status).toBe(200);
    expect(telegramCalls(calls, "sendMessage")[0].json).toEqual({ chat_id: chatID, text: "hello" });
    expect(telegramCalls(calls, "sendMessage")[0].url).toBe(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`);
  });

  it("adds the chat to every send method except answering a button tap", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    const calls = fakeTelegram();
    await fromMac("/phone/telegram/sendChatAction", installKey, { action: "typing" });
    await fromMac("/phone/telegram/editMessageReplyMarkup", installKey, "not json");
    await fromMac("/phone/telegram/answerCallbackQuery", installKey, { callback_query_id: "tap" });
    expect(telegramCalls(calls, "sendChatAction")[0].json).toEqual({ action: "typing", chat_id: chatID });
    expect(telegramCalls(calls, "editMessageReplyMarkup")[0].json).toEqual({ chat_id: chatID });
    expect(telegramCalls(calls, "answerCallbackQuery")[0].json).toEqual({ callback_query_id: "tap" });
  });

  it("passes Telegram's error status on", async () => {
    const installKey = await pairedMac(newChatID());
    fakeTelegram([["/sendMessage", jsonAnswer({ ok: false, description: "Too Many Requests" }, 429)]]);
    const response = await fromMac("/phone/telegram/sendMessage", installKey, { text: "hi" });
    expect(response.status).toBe(429);
    expect(((await response.json()) as any).description).toBe("Too Many Requests");
  });

  it("sends a file to the Mac's own chat, even when the form names another", async () => {
    const chatID = newChatID();
    const installKey = await pairedMac(chatID);
    let sentForm: FormData | undefined;
    fakeFetch([
      ["/sendDocument", async () => jsonAnswer({ ok: true })],
    ]);
    const realFake = globalThis.fetch;
    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/sendDocument")) sentForm = init?.body as FormData;
      return realFake(input, init);
    });
    const form = new FormData();
    form.set("chat_id", "999999");
    form.set("caption", "the report");
    form.set("document", new File(["file body"], "a.txt", { type: "text/plain" }));
    const request = new Request("https://worker.test/phone/telegram/sendDocument", { method: "POST", headers: { "x-dottie-phone-key": installKey }, body: form });
    const response = await worker.fetch(request, phoneEnv());
    expect(response.status).toBe(200);
    expect(sentForm!.getAll("chat_id")).toEqual([String(chatID)]);
    expect(sentForm!.get("caption")).toBe("the report");
    expect(await (sentForm!.get("document") as File).text()).toBe("file body");
  });

  it("answers 400 for a file form that is cut off", async () => {
    const installKey = await pairedMac(newChatID());
    const calls = fakeTelegram();
    const response = await fromMac("/phone/telegram/sendDocument", installKey, "this is not a form", { contentType: "multipart/form-data; boundary=missing" });
    expect(response.status).toBe(400);
    expect(calls).toHaveLength(0);
  });
});

describe("the Durable Object itself", () => {
  it("answers 404 for an action it doesn't know, and survives a body that isn't JSON", async () => {
    const env = phoneEnv();
    const stub = env.PHONE_RELAY.get(env.PHONE_RELAY.idFromName(`mailbox:${crypto.randomUUID()}`));
    const unknownAction = await stub.fetch("https://phone-relay/selfDestruct", { method: "POST", body: "{}" });
    expect(unknownAction.status).toBe(404);
    const brokenBody = await stub.fetch("https://phone-relay/pairedChat", { method: "POST", body: "not json" });
    expect(await brokenBody.json()).toEqual({ chatID: null });
  });
});
