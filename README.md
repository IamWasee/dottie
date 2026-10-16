# Clicky clone (Gemini edition)

An AI buddy that lives next to your cursor on macOS. Hold **ctrl + option**, talk, and it sees your screen, answers out loud, and can fly a little blue cursor to the thing you're asking about.

This is a clone of [HeyClicky](https://www.heyclicky.com/), built on top of Farza's open-source [Clicky v0](https://github.com/farzaa/clicky) (MIT). v0 is the April 2026 version he open-sourced; the app he ships today is closed. This repo starts from v0 and rebuilds the newer features, with every AI call moved to **Google Gemini's free tier**, so the only key you need is one from [Google AI Studio](https://aistudio.google.com/apikey).

| | v0 (upstream) | this clone |
|---|---|---|
| Voice companion | AssemblyAI speech-to-text → Claude → ElevenLabs | **Gemini Live**: voice in, screen frame in, voice out, in one stream |
| Pointing | `[POINT:x,y]` text tags | `point_at_element` tool call (Live), tags still used in classic mode |
| Keys needed | Anthropic, AssemblyAI, ElevenLabs | **one Gemini key** |
| Fallback mode | none | `classic`: Apple Speech → Gemini Flash → Gemini TTS |

See [ROADMAP.md](ROADMAP.md) for which shipped-Clicky features are done and what's next.

## Setup

You need a Mac with macOS 14.2+, Xcode 16+, Node 18+, a free [Cloudflare](https://cloudflare.com) account, and a Gemini API key.

### 1. Deploy the Worker

The Worker holds your Gemini key so it never ships inside the app. The app gets short-lived tokens from it.

```bash
cd worker
npm install
npx wrangler secret put GEMINI_API_KEY      # paste your AI Studio key
npx wrangler secret put APP_SHARED_SECRET   # optional: any random string
npx wrangler deploy
```

Wrangler prints a URL like `https://clicky-proxy.yourname.workers.dev`. Model names live in `worker/wrangler.toml` under `[vars]`, so you can switch models without rebuilding the app.

For local Worker development, put the same values in `worker/.dev.vars` and run `npx wrangler dev`.

### 2. Point the app at your Worker

Open `leanring-buddy/Info.plist` and set:

| Key | Value |
|---|---|
| `ClickyWorkerBaseURL` | your Worker URL |
| `ClickyAppSharedSecret` | the same string as `APP_SHARED_SECRET`, or leave empty |
| `CompanionVoiceMode` | `live` (default) or `classic` |
| `OnboardingVideoURL` | optional intro video; empty skips it |
| `PostHogAPIKey` | optional, your own PostHog key; empty disables analytics |
| `GeminiCLIPath` | optional, where `gemini` is installed if the app can't find it |
| `GeminiAgentModel` | optional, the model background Clickys use (default `gemini-3.8-flash`) |

### Background Clickys (optional)

Clickys are helpers that work on their own in a folder on your Mac and report back in the notch. They run on Google's open-source [Gemini CLI](https://github.com/google-gemini/gemini-cli), which needs Node.js:

```bash
npm install -g @google/gemini-cli
```

Nothing else to set up: the app points Gemini CLI at your Worker, so the same Gemini key is used and it never leaves the Worker. Create Clickys in Home → Clickys, or just ask Clicky out loud to hand a task off.

### 3. Build and run

```bash
open leanring-buddy.xcodeproj
```

1. Select the `leanring-buddy` scheme (the typo is inherited from v0 and kept on purpose).
2. Under Signing & Capabilities, pick your own team. Change the bundle identifier if you like.
3. Press **Cmd + R**.

The app appears in the menu bar, not the Dock. Open the panel and grant the permissions it asks for: Microphone, Accessibility (for the hotkey), Screen Recording, and Screen Content.

Don't build with `xcodebuild` from a terminal; it resets the macOS privacy permissions every time.

## How it works

Hold the hotkey and the app captures every display into one frame, opens (or reuses) a Gemini Live WebSocket with an ephemeral token from the Worker, and streams your voice. Let go and Gemini answers in audio, which plays as it arrives. If pointing would help, Gemini calls `point_at_element` with coordinates on the frame, and the blue cursor flies there while it talks. Sessions close after 45 idle seconds, and the last ten exchanges are carried into the next session so it remembers the conversation.

Longer jobs go to background Clickys. Each one has its own folder (`~/Library/Application Support/ClickyClone/Clickys/<name>/`) with an `AGENTS.md` it reads and keeps notes in, and an `output/` folder for what it makes. Each turn runs Gemini CLI there with shell, file and web tools, and Home shows what it did.

The full technical breakdown is in [AGENTS.md](AGENTS.md).

## Credits

Built on [farzaa/clicky](https://github.com/farzaa/clicky) by Farza, MIT licensed; see [LICENSE](LICENSE). Not affiliated with Farza, Human Songs, or HeyClicky.
