# Roadmap

The app is called Dottie, and its background agents are Dots (shipped Clicky calls them Clickys; the Swift types keep the `Clicky` prefix).

The target is parity with shipped HeyClicky v1.0.53. Its teardown (feature map, prompts, backend routes) lives in the project files at `clicky/FINDINGS.md`. Each phase below maps to a step of that report's clone plan.

Status key: ✅ written, ⏳ in progress, ⬜ not started. "Written" means the code exists. Nothing is marked as tested until it has been built and run on a Mac.

## Phase 1: v0 parity on Gemini ✅

- ✅ Worker rewritten for Gemini: `/live-token` (ephemeral Live tokens), `/chat` (streaming Flash), `/tts`, optional shared secret
- ✅ `GeminiLiveVoiceClient`: Live WebSocket, push-to-talk via manual activity detection, 24kHz streamed playback, transcripts, reconnect and idle close
- ✅ `point_at_element` tool with 0–1000 coordinates on a side-by-side frame of all displays
- ✅ Live audio plugged into v0's existing push-to-talk pipeline (`GeminiLiveCompanionTranscriptionProvider`)
- ✅ Classic fallback mode: Apple Speech → Gemini Flash → Gemini TTS, with v0's `[POINT:]` tags
- ✅ Removed v0's hard-coded third-party values: Farza's PostHog key, FormSpark form, Mux video, Sparkle feed, Apple team IDs
- ⬜ First build and run on a Mac

## Phase 2: hand-off to a stronger model ✅

- ✅ `send_to_higher_model` tool: Live hands harder questions to the Worker's `GEMINI_HIGHER_MODEL` with fresh screenshots, can point the cursor, and Live speaks the answer
- ✅ Escape to interrupt (only while Clicky is busy; the key still reaches the frontmost app)

## Phase 3: notch UI and Home window ⏳

- ✅ Notch surface: black shape around the notch (a pill on Macs without one) with blinking eyes, listening waveform, thinking, live caption while speaking, typed input, and an auto-dismissing answer card with copy and follow-up
- ✅ Typed messages from the notch or Home, answered out loud like spoken ones
- ✅ Home window: saved conversation transcript (persisted to Application Support) and settings (voice, notch, cursor, worker status, clear history)
- ✅ Custom hotkeys (`ClickyHotkeyRecorder`): record your own talk and dictation shortcuts in Settings, modifiers alone or with a key
- ✅ Screen annotation: circle a region with the cursor while holding the talk shortcut and ask about it (`ScreenAnnotationManager`); the ring is drawn onto the screenshot the model sees
- ✅ Notch hover peek of Dots: each Dot's status light (working, something new, idle) and last line; click one to open its chat in Home
- ✅ Notch hover peek of files: the newest files in the Dots' output folders as thumbnails; click to open, drag into any app, or right-click to show in Finder (`NotchPeekFiles`)

## Phase 4: Clicky agents ⏳

- ✅ Agent runtime on Gemini CLI (`GeminiCLIAgentRuntime`). Shipped Clicky bundles OpenAI's Codex CLI, but Gemini has no Responses API, so the clone drives Google's open-source Gemini CLI in headless stream-json mode. It reaches Gemini through the Worker's `/gemini` passthrough, so the key stays on the Worker. Tested on Linux against a mock Gemini server: tool calls, AGENTS.md as context and resumed sessions all work
- ✅ Per-agent workspace (`AGENTS.md` with the agent's instructions and notes, `output/`, `tmp/`) and a roster with saved transcripts (`ClickyRoster`)
- ✅ Home → Clickys: list, new Clicky form, chat with tool activity, stop, reveal output in Finder, delete to Trash
- ✅ Voice hand-off: Live's `start_clicky_task` tool starts work on a named Clicky (or a general "Helper"); the result comes back as a card in the notch
- ✅ Skills on Gemini CLI's own skills support: a library in Application Support, Home → Skills (new skill, add a skill folder, per-Clicky toggles), a ✨ menu in each chat, and agents can save a skill when asked to remember how to do something. Tested against a mock Gemini server: linked skills are listed to the model and an agent can write a new skill into the library
- ✅ Routines the way shipped Clicky does them: an agent asked for something on a cadence ends its reply with a `<ROUTINE>` block (create, update, delete, pause, resume), the app keeps the schedule, and each run's answer lands in the chat and the notch. Run now / pause / delete in the chat. Runs only while the Mac is awake, online and the app is open; three failed runs in a row pause the routine
- ✅ "Something new" tracking: a finished turn marks a Dot unread until you look at its chat. The closed notch grows a pulsing light while any Dot works and a count of Dots with something new, and Home marks them in the list
- ✅ macOS notifications (`ClickyNotifications`): a Dot's reply while you're in another app, and its requests to use the Mac with Allow / Don't Allow buttons; clicking opens the Dot, reading its chat clears it

## Phase 5: computer use ⏳

- ✅ Clickys operate apps through [cua-driver](https://github.com/trycua/cua/tree/main/libs/cua-driver) (MIT), the same open-source driver shipped Clicky bundles. Gemini CLI starts `cua-driver mcp --direct` as an MCP server, so the driver runs under the app's own Accessibility and Screen Recording permissions
- ✅ Ask-first gate (`ClickyComputerUse`): agents can always look, but cua-driver's policy file only allows clicking and typing in turns the user approved. Agents ask with a `<COMPUTER_USE_REQUEST>` block, shown as Allow / Always / Not now in the notch and in Home. "Always allow" lives in Settings
- ✅ Shared agent instructions for operating apps (snapshot, act by element, verify), written to Gemini CLI's global `AGENTS.md`. Tested against a fake driver: the per-turn policy reaches the MCP server and a refused click comes back as a tool error
- ✅ Downloadable like HeyClicky: the Release workflow deploys the Worker from repo secrets, bakes its address into an ad-hoc-signed universal `Dottie.dmg` and publishes it on GitHub Releases ([INSTALL.md](INSTALL.md)). Dottie downloads Node.js and Gemini CLI for Dots itself (`DotsRuntimeInstaller`), and Settings takes a server address when a build has none. Not notarized (no Apple Developer account), so people click Open Anyway once
- ✅ Bundle cua-driver inside the app (`Contents/Helpers/cua-driver`): an Xcode build phase (`scripts/embed-cua-driver.sh`) downloads a pinned release, verifies it against SHA256SUMS, caches it and signs it with the app's identity; CI checks it landed
- ⬜ Try it for real on a Mac

## Phase 6: dictation ⏳

- ✅ Hold right Option (or your own shortcut), talk, let go: the text is typed wherever the cursor is (`ClickyDictationController`). A key pressed during the hold (an Option special character) or Escape throws the recording away
- ✅ One Gemini call on the Worker (`/dictate`, `GEMINI_DICTATION_MODEL`) hears the recording and tidies it: fillers and false starts out, punctuation in, self-corrections applied, spoken formatting followed. It gets the app name, the text before the cursor and the user's own spellings as context. Shipped Clicky uses Deepgram plus a separate cleanup call; the clone stays on the one free Gemini key
- ✅ Paste with a temporary clipboard swap that puts the user's clipboard back; clipboard fallback (with a notch card) when the field can't take it, the user switched apps, or a password field is focused
- ✅ Settings: on/off and a custom words list
- ✅ Learn corrections automatically (`DictationCorrectionLearner`): after a paste, Dottie reads the field through Accessibility for 45 seconds. When you replace a dictated word with a similar one that isn't an everyday word (a name, a brand, jargon), it goes into a learned dictionary, the notch says "Added to your dictionary" with a Remove button, and later dictation is told the spelling. Settings lists the learned words
- ⬜ Streaming partial text, language picker
- ⬜ Try it for real on a Mac

## Phase 7: accounts and integrations (optional for a personal clone)

- ⬜ Supabase auth, Composio connectors, billing
