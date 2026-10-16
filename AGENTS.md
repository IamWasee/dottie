# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app, a clone of HeyClicky built on Farza's open-source Clicky v0 (MIT) with every AI call moved to Google Gemini's free tier. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Push-to-talk (ctrl+option) streams the user's voice and one frame of their screen(s) to Gemini Live, which answers in streamed audio. A blue cursor overlay can fly to and point at UI elements Gemini picks via a tool call, on any connected monitor.

The only key is a Gemini API key, and it lives on a Cloudflare Worker proxy — nothing sensitive ships in the app. See ROADMAP.md for which shipped-Clicky features exist so far.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Voice companion (live mode, default)**: Gemini Live (`gemini-3.8-live`) over a WebSocket opened with a single-use ephemeral token from the Worker. Manual activity detection: hotkey press sends `activityStart` + a JPEG frame, release sends `activityEnd`. Output is 24kHz PCM played as it streams. Pointing is the `point_at_element` tool (0–1000 coordinates on the frame).
- **Classic mode (`CompanionVoiceMode=classic`)**: Apple Speech → Gemini Flash vision (SSE via Worker `/chat`) → Gemini TTS (Worker `/tts`), with v0's `[POINT:]` tags
- **Background agents ("Clickys")**: each agent turn runs Google's Gemini CLI headless (`gemini -p … -o stream-json --approval-mode yolo`, `--session-id` then `--resume`) in the agent's folder under `~/Library/Application Support/ClickyClone/Clickys/<slug>/`. `GOOGLE_GEMINI_BASE_URL` points it at the Worker's `/gemini` passthrough and `GEMINI_CLI_HOME` at a clone-owned `.cli-home`, so the user's own `~/.gemini` is untouched. Live hands work over with the `start_clicky_task` tool; results show as a notch card.
- **Skills**: a library of Gemini CLI skills (`SKILL.md` folders) in `~/Library/Application Support/ClickyClone/Skills/`. Each agent's enabled skills are symlinked into its workspace's `.gemini/skills/` before each turn, and the library is passed with `--include-directories` so agents can save new skills there (the app turns a skill an agent saved on for that agent).
- **Routines**: agents set up repeats by ending a reply with `<ROUTINE>{"action":"create","every_minutes":60,"title":…,"task":…}</ROUTINE>` (also update, delete, pause, resume), as shipped Clicky does. `ClickyRoutineStore` keeps them in `Clickys/routines.json`; a 30-second timer in `ClickyRoster` runs due ones while the Mac is awake and online. Every user turn starts with the agent's current routine list; run turns get shipped Clicky's "report what's new" brief. Three failed runs in a row pause a routine.
- **Computer use**: when `cua-driver` is installed, it's registered in Gemini CLI's settings as the `computer-use` MCP server (`cua-driver mcp --direct --embedded`, so it inherits the app's permissions). Each turn sets `CLICKY_CUA_POLICY_FILE` to a look-only or look-and-act policy; act is used only for turns the user allowed or with "Always allow". Agents ask with a `<COMPUTER_USE_REQUEST>` block, which becomes an Allow / Always / Not now card.
- **Model names**: set on the Worker in `wrangler.toml` `[vars]`, not in the app
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: In live mode, all displays are drawn side by side into one frame (`captureCompositeFrameForLive`); Gemini's `point_at_element(x, y, label)` is resolved back to a display and converted to AppKit coordinates. In classic mode the model embeds `[POINT:x,y:label:screenN]` tags. Either way the blue cursor animates along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`, off unless `PostHogAPIKey` is set in Info.plist

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /live-token` | `generativelanguage.googleapis.com/v1beta/auth_tokens` | Single-use Gemini Live ephemeral token (session must start within 2 min) |
| `POST /chat` | `…/models/{model}:streamGenerateContent?alt=sse` | Gemini vision + streaming chat (onboarding demo, classic mode) |
| `POST /dictate` | `…/models/{dictation model}:generateContent` | Hold-to-dictate: a WAV recording in, cleaned-up text out, in one call |
| `POST /tts` | `…/models/{tts model}:generateContent` | Gemini TTS, returned as raw 24kHz PCM (classic mode) |
| `* /gemini/*` | `generativelanguage.googleapis.com/*` | Passthrough for Gemini CLI (agents). The CLI sends the shared secret as its API key; the Worker swaps in the real one |
| `GET /config` | none | Echoes the configured model names |

Worker secrets: `GEMINI_API_KEY`, optional `APP_SHARED_SECRET` (checked against the `x-clicky-secret` header)
Worker vars: `GEMINI_LIVE_MODEL`, `GEMINI_CHAT_MODEL`, `GEMINI_TTS_MODEL`, `GEMINI_TTS_VOICE`, `GEMINI_DICTATION_MODEL`

App Info.plist keys: `ClickyWorkerBaseURL`, `ClickyAppSharedSecret`, `CompanionVoiceMode`, `OnboardingVideoURL`, `PostHogAPIKey`, optional `GeminiCLIPath`, `GeminiAgentModel` and `CuaDriverPath`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Live audio through the dictation pipeline**: `BuddyDictationManager` already owns the mic, permissions, waveform and press/release lifecycle. In live mode it is constructed with `GeminiLiveCompanionTranscriptionProvider`, which forwards mic buffers (batched to ~100ms of 16kHz PCM16) to the Live session instead of a speech-to-text service. The spoken answer comes back through `GeminiLiveVoiceClient`'s callbacks, not the dictation callbacks.

**Live session lifecycle**: Sessions with video input are capped at about two minutes, so the socket opens on the first press, closes after 45 idle seconds or on `goAway`, and the last ten exchanges (from Live's input/output transcriptions) are appended to the next session's system instruction. Messages sent before `setupComplete` are queued so the user can talk immediately. A 20s watchdog drops a silent connection.

**Shared URLSession**: Long-lived `URLSession`s are owned by the clients, not per request. Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1270 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the Gemini Live client (live mode) or Gemini chat + TTS (classic mode), and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, voice selection, and cursor visibility. |
| `GeminiLiveVoiceClient.swift` | ~640 | Gemini Live WebSocket client: ephemeral-token connect, setup (voice, tools, manual activity detection, transcription, context compression), queued sends, turn API (`beginUserTurn`/`sendMicrophoneAudio`/`endUserTurn`), tool calls, idle close, watchdog. Also `GeminiLivePCMPlayer` for streamed 24kHz playback. |
| `GeminiLiveCompanionTranscriptionProvider.swift` | ~150 | Bridges `BuddyDictationManager`'s mic pipeline into the Live session. |
| `GeminiAPI.swift` | ~210 | Gemini vision chat with SSE streaming via Worker `/chat`. Same call shape as v0's ClaudeAPI. |
| `GeminiTTSClient.swift` | ~75 | Gemini TTS via Worker `/tts` (classic mode). |
| `NotchPresenter.swift` | ~165 | State of the notch surface (compact, listening, thinking, speaking, text input, text response) and the answer card's auto-dismiss. |
| `NotchWindowManager.swift` | ~210 | Borderless panel pinned over the notch (or a top-center pill), resized per surface so it never blocks more of the menu bar than needed. |
| `NotchRootView.swift` | ~390 | SwiftUI for every notch surface, plus `NotchEyeView` (Clicky's eyes). |
| `HomeSpaceRootView.swift` | ~370 | Home window (conversation transcript, typed composer, settings) and `HomeWindowManager`. |
| `GeminiCLIAgentRuntime.swift` | ~330 | Finds and runs Gemini CLI for one agent turn, parses its stream-json events, stops turns. |
| `ClickyRoster.swift` | ~620 | The agents: roster, workspaces (`AGENTS.md`, `output/`, `tmp/`), transcripts, sending messages, finish callbacks, per-agent skills and the routine scheduler. |
| `ClickyDictationController.swift` | ~380 | Hold-to-dictate: focus capture through Accessibility, 16kHz recording, Worker `/dictate`, and pasting with a clipboard swap (or clipboard fallback). |
| `ClickyComputerUse.swift` | ~220 | Computer use: finds cua-driver, writes its look-only and look-and-act policies, the MCP server entry, the shared agent instructions, and parses permission requests. |
| `HomeClickysView.swift` | ~560 | Home → Clickys: agent list, new Clicky form, chat with tool activity, routines strip and skills menu. |
| `ClickySkillLibrary.swift` | ~250 | The skills library: reading `SKILL.md` front matter, creating and importing skills, linking enabled skills into agent workspaces. |
| `ClickyRoutines.swift` | ~330 | Routines: the model, `<ROUTINE>` block parsing, the store (create/update/pause/delete, run bookkeeping) and run prompts. |
| `HomeSkillsView.swift` | ~370 | Home → Skills: library list, new skill form, skill detail with per-Clicky toggles. |
| `ConversationStore.swift` | ~85 | Persists the conversation shown on Home as JSON in Application Support. |
| `ClickyWorkerConfiguration.swift` | ~45 | Reads the Worker URL and shared secret from Info.plist; adds the auth header. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~720 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, Gemini voice picker, permissions UI, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~310 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled JPEGs per display (classic mode) or one side-by-side composite frame with region mapping (live mode). |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~45 | Protocol surface for voice transcription backends. The factory returns Apple Speech (classic mode); live mode injects the Gemini Live bridge instead. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device transcription backed by Apple's Speech framework (classic mode). |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~230 | Cloudflare Worker proxy for Gemini: `/live-token`, `/chat`, `/tts`, `/dictate`, `/gemini/*`, `/config`. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put APP_SHARED_SECRET   # optional

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
