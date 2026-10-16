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
- ⬜ Notch hover peek of agents and files (needs phase 4)

## Phase 4: Clicky agents

- ⬜ Agent runtime. Shipped Clicky bundles OpenAI's Codex CLI; the clone needs an agent loop that runs on Gemini (Codex against an OpenAI-compatible Gemini endpoint, or Gemini CLI)
- ⬜ Per-agent workspace (`AGENTS.md`, `output/`, `tmp/`), `ClickyModelInstructions.md` as system prompt, skills
- ⬜ Routines (cron), notifications

## Phase 5: computer use

- ⬜ cua-driver (MIT, trycua/cua) bundled as a helper, with the per-turn consent gate

## Phase 6: dictation

- ⬜ Hold-to-dictate into any text field: Gemini transcription, cleanup pass, text injection, learned dictionary

## Phase 7: accounts and integrations (optional for a personal clone)

- ⬜ Supabase auth, Composio connectors, billing
