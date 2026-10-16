# Dottie

An AI buddy that lives next to your cursor on macOS. Hold **ctrl + option** (or a shortcut you pick in Settings), talk, and it sees your screen, answers out loud, and can fly a little blue cursor to the thing you're asking about. While you hold it, circle something with the cursor and Dottie knows that's what you mean.

Dottie is a clone of [HeyClicky](https://www.heyclicky.com/), built on top of Farza's open-source [Clicky v0](https://github.com/farzaa/clicky) (MIT). v0 is the April 2026 version he open-sourced; the app he ships today is closed. This repo starts from v0 and rebuilds the newer features, with every AI call moved to **Google Gemini's free tier**, so the only key you need is one from [Google AI Studio](https://aistudio.google.com/apikey).

| | v0 (upstream) | Dottie |
|---|---|---|
| Voice companion | AssemblyAI speech-to-text → Claude → ElevenLabs | **Gemini Live**: voice in, screen frame in, voice out, in one stream |
| Pointing | `[POINT:x,y]` text tags | `point_at_element` tool call (Live), tags still used in classic mode |
| Keys needed | Anthropic, AssemblyAI, ElevenLabs | **one Gemini key** |
| Fallback mode | none | `classic`: Apple Speech → Gemini Flash → Gemini TTS |

See [ROADMAP.md](ROADMAP.md) for which shipped-Clicky features are done and what's next.

## Install

**[Download Dottie.dmg](https://github.com/IamWasee/dottie/releases/latest/download/Dottie.dmg)**. [INSTALL.md](INSTALL.md) walks through installing it on any Mac, and the one-time setup that makes GitHub build the app and its server for you (no Mac tools needed).

## Build from source

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

Wrangler prints a URL like `https://dottie.yourname.workers.dev`. (The Release workflow does all of this for you; see [INSTALL.md](INSTALL.md).) Model names live in `worker/wrangler.toml` under `[vars]`, so you can switch models without rebuilding the app.

For local Worker development, put the same values in `worker/.dev.vars` and run `npx wrangler dev`.

### 2. Point the app at your Worker

Open `leanring-buddy/Info.plist` and set the keys below (or leave the URL empty and paste it into Home → Settings → Connection after launching):

| Key | Value |
|---|---|
| `ClickyWorkerBaseURL` | your Worker URL |
| `ClickyAppSharedSecret` | the same string as `APP_SHARED_SECRET`, or leave empty |
| `CompanionVoiceMode` | `live` (default) or `classic` |
| `OnboardingVideoURL` | optional intro video; empty skips it |
| `PostHogAPIKey` | optional, your own PostHog key; empty disables analytics |
| `GeminiCLIPath` | optional, where `gemini` is installed if the app can't find it |
| `GeminiAgentModel` | optional, the model background Dots use (default `gemini-3.8-flash`) |
| `CuaDriverPath` | optional, where `cua-driver` is installed if the app can't find it |

### Background Dots (optional)

Dots are helpers that work on their own in a folder on your Mac and report back in the notch. They run on Google's open-source [Gemini CLI](https://github.com/google-gemini/gemini-cli). Nothing to install: on first launch Dottie downloads pinned copies of Node.js and Gemini CLI (about 70 MB, checked against hashes in `DotsRuntimeInstaller.swift`) into `~/Library/Application Support/Dottie/Runtime`. A Gemini CLI you installed yourself works too. The app points Gemini CLI at your Worker, so the same Gemini key is used and it never leaves the Worker. Create Dots in Home → Dots, or just ask Dottie out loud to hand a task off.

Dots click and type in your apps through the open-source [cua-driver](https://github.com/trycua/cua/tree/main/libs/cua-driver), which the build puts inside Dottie.app for you (a build phase downloads a pinned release once, checks its checksum and caches it). It runs under Dottie's own Accessibility and Screen Recording permissions, so there's nothing extra to install or allow. If the build was offline, Settings says the driver is missing; rebuild online, or install it yourself with `/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"`.

Dots can always look at your apps, but they ask before they click or type: an Allow / Always / Not now card appears in the notch. You can let them act without asking in Home → Settings.

To have a Dot repeat a task, just say how often ("check my repos for new issues every morning"). It does the task once and sets up a routine; each later run's answer lands in its chat and the notch. Routines run while your Mac is awake and Dottie is open, and you can run, pause or delete them from the Dot's chat.

The notch keeps you posted: a blue light pulses beside it while a Dot works, and a number shows how many have something new. Hover the notch to see each Dot's latest line, and click one to open its chat. The newest files your Dots made show there too: click one to open it, or drag it straight into another app. When you're in another app, a Mac notification also brings each reply (macOS asks once to allow them), and a Dot asking to use your Mac can be answered from the notification. Turn them off in Home → Settings.

Skills are saved instructions a Dot follows when a task calls for them, like your report format or the steps of a chore. Make them in Home → Skills, add a skill folder you downloaded, or tell a Dot "remember how to do this" and it saves one itself. Turn skills on per Dot from the ✨ menu in its chat.

### 3. Build and run

```bash
open leanring-buddy.xcodeproj
```

1. Select the `leanring-buddy` scheme (the typo is inherited from v0 and kept on purpose).
2. Under Signing & Capabilities, pick your own team. Change the bundle identifier if you like.
3. Press **Cmd + R**.

The app appears in the menu bar, not the Dock. Open the panel and grant the permissions it asks for: Microphone, Accessibility (for the hotkey), Screen Recording, and Screen Content.

Don't build with `xcodebuild` from a terminal; it resets the macOS privacy permissions every time.

## Dictation

Hold **right Option**, talk, and let go: Dottie types the cleaned-up text wherever your cursor is, in any app. Fillers and false starts are dropped and punctuation is added. If there's nowhere to type, the text goes to your clipboard. Add names and jargon you want spelled your way in Home → Settings.

Both shortcuts can be changed in Home → Settings → Shortcuts: click one and press the new keys. A shortcut is either modifier keys held on their own (right option, fn, ctrl + option) or modifiers with a key (cmd + shift + space). With Accessibility granted, a key shortcut's key is kept from typing into the app in front.

## How it works

Hold the hotkey and the app captures every display into one frame, opens (or reuses) a Gemini Live WebSocket with an ephemeral token from the Worker, and streams your voice. Let go and Gemini answers in audio, which plays as it arrives. If pointing would help, Gemini calls `point_at_element` with coordinates on the frame, and the blue cursor flies there while it talks. Sessions close after 45 idle seconds, and the last ten exchanges are carried into the next session so it remembers the conversation.

Longer jobs go to background Dots. Each one has its own folder (`~/Library/Application Support/Dottie/Dots/<name>/`) with an `AGENTS.md` it reads and keeps notes in, and an `output/` folder for what it makes. Each turn runs Gemini CLI there with shell, file and web tools, and Home shows what it did.

The full technical breakdown is in [AGENTS.md](AGENTS.md).

## Credits

Built on [farzaa/clicky](https://github.com/farzaa/clicky) by Farza, MIT licensed; see [LICENSE](LICENSE). Bundles [cua-driver](https://github.com/trycua/cua) by Cua, MIT licensed; its license and third-party notices are copied into the app's Resources. Not affiliated with Farza, Human Songs, or HeyClicky.
