# Roadmap

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
- ⬜ Custom hotkeys (`ClickyHotkeyRecorder`)
- ⬜ Screen annotation: circle a region and ask about it (`ScreenAnnotationManager`)
- ⬜ Notch hover peek of agents and files

## Phase 4: Clicky agents ⏳

- ✅ Agent runtime on Gemini CLI (`GeminiCLIAgentRuntime`). Shipped Clicky bundles OpenAI's Codex CLI, but Gemini has no Responses API, so the clone drives Google's open-source Gemini CLI in headless stream-json mode. It reaches Gemini through the Worker's `/gemini` passthrough, so the key stays on the Worker. Tested on Linux against a mock Gemini server: tool calls, AGENTS.md as context and resumed sessions all work
- ✅ Per-agent workspace (`AGENTS.md` with the agent's instructions and notes, `output/`, `tmp/`) and a roster with saved transcripts (`ClickyRoster`)
- ✅ Home → Clickys: list, new Clicky form, chat with tool activity, stop, reveal output in Finder, delete to Trash
- ✅ Voice hand-off: Live's `start_clicky_task` tool starts work on a named Clicky (or a general "Helper"); the result comes back as a card in the notch
- ⬜ Skills (Gemini CLI supports them; needs a skills folder and a Home page)
- ⬜ Routines (cron), notifications

## Phase 5: computer use ⏳

- ✅ Clickys operate apps through [cua-driver](https://github.com/trycua/cua/tree/main/libs/cua-driver) (MIT), the same open-source driver shipped Clicky bundles. Gemini CLI starts `cua-driver mcp --direct` as an MCP server, so the driver runs under the app's own Accessibility and Screen Recording permissions
- ✅ Ask-first gate (`ClickyComputerUse`): agents can always look, but cua-driver's policy file only allows clicking and typing in turns the user approved. Agents ask with a `<COMPUTER_USE_REQUEST>` block, shown as Allow / Always / Not now in the notch and in Home. "Always allow" lives in Settings
- ✅ Shared agent instructions for operating apps (snapshot, act by element, verify), written to Gemini CLI's global `AGENTS.md`. Tested against a fake driver: the per-turn policy reaches the MCP server and a refused click comes back as a tool error
- ⬜ Bundle cua-driver inside the app (`Contents/Helpers/cua-driver`) instead of asking the user to install it
- ⬜ Try it for real on a Mac

## Phase 6: dictation

- ⬜ Hold-to-dictate into any text field: Gemini transcription, cleanup pass, text injection, learned dictionary

## Phase 7: accounts and integrations (optional for a personal clone)

- ⬜ Supabase auth, Composio connectors, billing
