# Dottie - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Dottie is a macOS menu bar companion app, a clone of HeyClicky built on Farza's open-source Clicky v0 (MIT) with every AI call moved to Google Gemini's free tier. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Push-to-talk (ctrl+option) streams the user's voice and one frame of their screen(s) to Gemini Live, which answers in streamed audio. A blue cursor overlay can fly to and point at UI elements Gemini picks via a tool call, on any connected monitor.

The only key is a Gemini API key, and it lives on a Cloudflare Worker proxy — nothing sensitive ships in the app. See ROADMAP.md for which shipped-Clicky features exist so far.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Voice companion (live mode, default)**: Gemini Live (`gemini-3.8-live`) over a WebSocket opened with a single-use ephemeral token from the Worker. Manual activity detection: hotkey press sends `activityStart` + a JPEG frame, release sends `activityEnd`. Output is 24kHz PCM played as it streams. Pointing is the `point_at_element` tool (0–1000 coordinates on the frame). Only about 20 everyday tools are declared (`GeminiLiveToolCatalog.directFunctionNames`); the rest are found with `find_tool` and run with `use_tool` through the same dispatch, so a rarely used tool's how-and-when belongs in its description, not the voice prompt.
- **Classic mode (`CompanionVoiceMode=classic`)**: Apple Speech → Gemini Flash vision (SSE via Worker `/chat`) → Gemini TTS (Worker `/tts`), with v0's `[POINT:]` tags
- **Background agents ("Dots"; "Clickys" in shipped Clicky and in type names)**: each agent turn runs Google's Gemini CLI headless (`gemini -p … -o stream-json --approval-mode yolo`, `--session-id` then `--resume`) in the agent's folder under `~/Library/Application Support/Dottie/Dots/<slug>/`. `GOOGLE_GEMINI_BASE_URL` points it at the Worker's `/gemini` passthrough and `GEMINI_CLI_HOME` at a clone-owned `.cli-home`, so the user's own `~/.gemini` is untouched. Live hands work over with the `start_clicky_task` tool; results show as a notch card.
- **Skills**: a library of Gemini CLI skills (`SKILL.md` folders) in `~/Library/Application Support/Dottie/Skills/`. Each agent's enabled skills are symlinked into its workspace's `.gemini/skills/` before each turn, and the library is passed with `--include-directories` so agents can save new skills there (the app turns a skill an agent saved on for that agent).
- **Routines**: agents set up repeats by ending a reply with `<ROUTINE>{"action":"create","every_minutes":60,"title":…,"task":…}</ROUTINE>` (also update, delete, pause, resume), as shipped Clicky does. `ClickyRoutineStore` keeps them in `Dots/routines.json`; a 30-second timer in `ClickyRoster` runs due ones while the Mac is awake and online. Every user turn starts with the agent's current routine list; run turns get shipped Clicky's "report what's new" brief. Three failed runs in a row pause a routine. Runs keep their own conversation (fresh every 8 runs, carrying the last report) and run on Gemini, except 24/7 jobs; a reply of exactly `NOTHING NEW` stays quiet and doubles the wait (up to 60 minutes, back to the set pace on a change). An optional `watch_url` is read first and the run skipped while its text is unchanged. A Dot's chat with the user starts a fresh session, with a 6-message handover, after 45 idle minutes or 12 turns.
- **Computer use**: the app target's "Embed cua-driver" build phase runs `scripts/embed-cua-driver.sh`, which puts a pinned, checksum-verified cua-driver release in `Contents/Helpers/cua-driver` (cached in ~/Library/Caches/Dottie-build; offline builds just warn). To update it, bump `CUA_DRIVER_VERSION` in that script. When the driver is found (bundled first, then ~/.local/bin), it's registered in Gemini CLI's settings as two MCP servers, `computer-use` (looking tools only) and `computer-use-act` (looking and input tools), both `cua-driver mcp --direct --embedded` so they inherit the app's permissions; each turn gets only one of them through `--allowed-mcp-server-names`. Each turn sets `CLICKY_CUA_POLICY_FILE` to a look-only or look-and-act policy; act is used only for turns the user allowed or with "Always allow". Agents ask with a `<COMPUTER_USE_REQUEST>` block, which becomes an Allow / Always / Not now card.
- **Model names**: set on the Worker in `wrangler.toml` `[vars]`, not in the app
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcuts (talk and dictation, both recordable in Settings) via a CGEvent tap.
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

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background. The talk and dictation shortcuts are `ClickyHotkey` values (modifiers only, optionally one side's key, or modifiers + a key) saved in UserDefaults and recorded in Settings by `ClickyHotkeyRecorder`. With Accessibility the tap is active so it can swallow a key shortcut's key; without it the tap only listens.

**Live audio through the dictation pipeline**: `BuddyDictationManager` already owns the mic, permissions, waveform and press/release lifecycle. In live mode it is constructed with `GeminiLiveCompanionTranscriptionProvider`, which forwards mic buffers (batched to ~100ms of 16kHz PCM16) to the Live session instead of a speech-to-text service. The spoken answer comes back through `GeminiLiveVoiceClient`'s callbacks, not the dictation callbacks.

**Live session lifecycle**: Sessions with video input are capped at about two minutes, so the socket opens on the first press, closes after 45 idle seconds or on `goAway`, and the last ten exchanges (from Live's input/output transcriptions) are appended to the next session's system instruction. Messages sent before `setupComplete` are queued so the user can talk immediately. A 20s watchdog drops a silent connection.

**Shared URLSession**: Long-lived `URLSession`s are owned by the clients, not per request. Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Native look, light and dark**: Home and the menu bar panel follow the system appearance (native macOS look: system font, sidebar material, accent #0066CC). `DS.Colors` tokens are adaptive `NSColor`s, so surfaces that must stay dark (the notch, cursor overlay, response panel, annotation windows) set `NSAppearance(named: .darkAqua)` on their window. Buttons use `.pointerCursor()` (cursor rects), not `NSCursor` push/pop, which could leave the hand cursor stuck.

**Dynamic Island notch**: The notch panel is one black `DottieIslandShape` that grows out of the hardware notch. Idle it is closed (or shows small wings for unread Dots), listening and thinking open wings beside the notch (eyes + waveform or dots), and everything else (captions, answers, the hover peek, permission and screen-task cards) expands into a card below it with a spring. The window is sized per `IslandPresentation` so it only covers what is drawn.

**Transient Cursor Mode**: When "Show Dottie" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~3620 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the Gemini Live client (live mode) or Gemini chat + TTS (classic mode), and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, voice selection, and cursor visibility. |
| `GeminiLiveVoiceClient.swift` | ~1725 | Gemini Live WebSocket client: ephemeral-token connect, setup (voice, tools, manual activity detection, transcription, context compression), queued sends, turn API (`beginUserTurn`/`sendMicrophoneAudio`/`endUserTurn`), tool calls, idle close, watchdog. Also `GeminiLivePCMPlayer` for streamed 24kHz playback and `GeminiLiveToolCatalog` (which tools are declared directly, `find_tool`/`use_tool` for the rest). |
| `GeminiLiveCompanionTranscriptionProvider.swift` | ~150 | Bridges `BuddyDictationManager`'s mic pipeline into the Live session. |
| `GeminiAPI.swift` | ~210 | Gemini vision chat with SSE streaming via Worker `/chat`. Same call shape as v0's ClaudeAPI. |
| `GeminiTTSClient.swift` | ~75 | Gemini TTS via Worker `/tts` (classic mode). |
| `NotchPresenter.swift` | ~440 | State of the notch surface (compact, listening, thinking, speaking, text input, text response), how open the island is (`IslandPresentation`: closed, wings, expanded), the answer card's auto-dismiss, and the Dot summaries for the badge and hover peek. |
| `NotchWindowManager.swift` | ~360 | Borderless dark-appearance panel pinned over the notch (or a top-center pill), resized per surface (wings beside the notch, or a card below it) so it never blocks more of the menu bar than needed. |
| `NotchRootView.swift` | ~860 | The Dynamic Island: `DottieIslandShape` (notch shoulders and rounded bottom), spring transitions between wings and cards, every notch surface, `NotchEyeView` (Dottie's eyes), `NotchWaveformView` and `NotchThinkingDots`. |
| `HomeSpaceRootView.swift` | ~1060 | Home window with the native sidebar (Talk, Make, You groups), conversation transcript, typed composer, and `HomeWindowManager`. |
| `GeminiCLIAgentRuntime.swift` | ~330 | Finds and runs Gemini CLI for one agent turn, parses its stream-json events, stops turns. |
| `ClickyRoster.swift` | ~620 | The agents: roster, workspaces (`AGENTS.md`, `output/`, `tmp/`), transcripts, sending messages, finish callbacks, per-agent skills and the routine scheduler. |
| `ClickyDictationController.swift` | ~380 | Hold-to-dictate: focus capture through Accessibility, 16kHz recording, Worker `/dictate`, and pasting with a clipboard swap (or clipboard fallback). |
| `ClickyComputerUse.swift` | ~220 | Computer use: finds cua-driver, writes its look-only and look-and-act policies, the MCP server entry, the shared agent instructions, and parses permission requests. |
| `HomeClickysView.swift` | ~560 | Home → Dots: agent list, new Dot form, chat with tool activity, routines strip and skills menu. |
| `ClickySkillLibrary.swift` | ~250 | The skills library: reading `SKILL.md` front matter, creating and importing skills, linking enabled skills into agent workspaces. |
| `ClickyRoutines.swift` | ~330 | Routines: the model, `<ROUTINE>` block parsing, the store (create/update/pause/delete, run bookkeeping) and run prompts. |
| `HomeSkillsView.swift` | ~370 | Home → Skills: library list, new skill form, skill detail with per-Dot toggles. |
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
| `GlobalPushToTalkShortcutMonitor.swift` | ~300 | System-wide shortcut monitor. Owns the `CGEvent` tap, holds the current talk and dictation shortcuts, and publishes press/release transitions. |
| `NotchPeekFiles.swift` | ~180 | The hover peek's file row: finds the newest files in the Dots' `output/` folders, loads Quick Look thumbnails, and shows tiles you can click, drag out, or reveal in Finder. |
| `ScreenAnnotationManager.swift` | ~380 | Circle to ask: samples the cursor while the talk shortcut is held, draws the trail in click-through overlay windows, finds a closed loop on release, and draws it as a ring onto the Live frame or the classic/higher-model screenshots. |
| `ClickyNotifications.swift` | ~170 | macOS notifications for Dots: one per Dot (replaced by its next reply, cleared once read), Allow / Don't Allow buttons for computer-use requests, clicks open the Dot in Home. |
| `ClickyHotkeys.swift` | ~400 | `ClickyHotkey` (a shortcut, its matching and display), `ClickyHotkeyRecorder`, and the Settings recorder field. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~850 | Design system tokens — adaptive light/dark colors (`Color(lightHex:darkHex:)`), corner radii, shared button styles, `DSVisualEffectBackground`. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `DottieUsage.swift` | ~250 | Token counter per area (voice, screen tasks, pointing, memory, helpers) from Gemini's usageMetadata and Gemini CLI stats, Claude helper turns and time, and how fast voice answers start. Settings → Usage. |
| `DottieGamePlayer.swift` | ~1030 | Video games: think, then play. A quick command ("go to the packager", "press E", "jump", "turn around") runs at once with no brain, game lookup or look-around (`DottieGameDirectCommand`); any other task is done exactly, and only "play"/"explore" asks run the new-game routine, guide lookup and mapping sweeps. Directed runs ("for this commercial: …") read a numbered plan back, wait for "go", follow it step by step, and keep "for this run, …" rules until "clear instructions". Each brain decision has a 45 s deadline and one retry. Names the game and looks it up first (DottieGameResearch), "map this game for me" (maps from the user's own keys and mouse while gameplay recording runs, `DottieGameMapInputWatcher`). Asks the game brain on events, runs its steps through the reflexes, keeps the notebook and the 3D map, says whether a game is familiar or new, switches Haiku to Sonnet when stuck, "watch me play" lessons, keys the user teaches by voice ("in this game F opens the shop": pressed once to check, then saved). Stop ends every loop and lets go of all keys. Started by DottieScreenTaskRunner for game jobs. |
| `DottieGameBrain.swift` | ~420 | The slow half: Claude through its own MausBot bots ("Dottie Gamer" on the newest Haiku, "Dottie Gamer (Sonnet)" when a plan is marked `hard` or play keeps failing; medium effort) looking at saved frames, Gemini with inline frames as backup. Returns a JSON plan (goal, 1-3 steps, what it learned). |
| `DottieGameReflexes.swift` | ~820 | The fast half: steering toward the target with Vision tracking while walking, eased camera turns, human pauses, stuck and event detection, learning controls by trying the default controls (WASD, space, shift, C), the right-click and free-mouse camera, the pause menu and other keys, the user's quick co-op calls, `go_to_place` (walking a route from the 3D map blind, with free glances, planned jumps, and replanning around blockers), feeding moves and frames to the map, and the `DottieGameReflexModel` plug-in for a local model (steps and blind walks). |
| `DottieGameWorldMap.swift` | ~1100 | Each game's 3D map: pose by dead reckoning, voxels from per-frame depth, keyframes (never mapped twice: new only beyond 2 units / 35°), relocalizing with feature prints, named places, blockers (fade after 45 s for moving things, kept when hit again), summary for the brain. Saved in `Games/<game>/map/`, loaded into RAM while playing. Also removes the old flat-map files (`GameMaps/`) on launch. |
| `DottieGameResearch.swift` | ~85 | Names the game from the user's request, the window and the screen text (reusing a known game's exact name so it keeps its notebook and map), and writes a short guide from two web searches into the notebook, refreshed every two weeks. |
| `DottieGameMapPicture.swift` | ~300 | Draws each saved map from above as `overview.png`, as colored blocks in `map3d.obj`, plus a plain-English `report.txt` (is the depth model working, what was recognized, learned movement); lists, opens (also in 3D) and deletes maps for the panel's "Game maps" button and the `game_maps` voice tool. |
| `DottieGameSurfaceMap.swift` | ~330 | The map as solid surfaces measured from spawn: each depth ray writes a signed distance and color into 0.2-unit cells around its hit (averaged over looks), and surface nets turn them into a colored mesh written as `map3d-surface.usdz` and `.obj`. |
| `DottieGameDepth.swift` | ~240 | Depth for one frame with Apple's Core ML Depth Anything V2 Small, downloaded from Hugging Face on first use into `Application Support/Dottie/Models/` and compiled once. |
| `DottieGameMovement.swift` | ~220 | Per-game movement model: degrees per mouse point (measured on small turns), field of view, walk speed and sprint factor (corrected on each relocalization), jump height and distance (learned from planned jumps), seconds to cover a distance. |
| `DottieGameNavigator.swift` | ~320 | Routes on the 3D map: floor plan from the voxels (blocked, low enough to jump, drops, blockers), A* path, straightened into legs of "turn, hold W for N seconds" with jump spots. |
| `DottieGameplayRecorder.swift` | ~560 | "Record gameplay" in the menu bar panel: saves every new screen frame (up to 30/s, 640 px JPEG) with the held keys, mouse buttons and mouse movement per frame, plus raw input events, to `Application Support/Dottie/GameData/<session>/` as training data for the reflex model. Stops itself under 2 GB free disk. |
| `DottieGameplayPlayback.swift` | ~290 | "Do what I recorded": plays a gameplay recording back (keys, shift, mouse buttons, mouse moves, same timing) into the recorded game, leaving out the talk shortcut and the "stop recording" at the end. Stopped by Stop or "stop". |
| `DottieSmartReplays.swift` | ~610 | Smart replays: "create a smart (or commercial) replay of me doing this" watches clicks, typing and app switches through Accessibility (no passwords), Gemini turns them into steps by meaning, and a text box asks for an optional line said at the end of every run. Store in `Replays/Smart/`, matched by name, number or shortcut phrase (by meaning, via the voice prompt); runs as a screen job (commercial: exact steps, calm pace, asks instead of improvising). `smart_replays` voice tool. |
| `HomeSmartReplaysView.swift` | ~230 | Home → Smart Replays: edit each replay's name, kind, steps, closing line and phrases; Run and Delete. |
| `DottieGameSenses.swift` | ~240 | On-device text reading, frame change and brightness, motion frames, and game sound (loudness and on-device dialogue transcription). |
| `DottieGameNotebook.swift` | ~450 | Per-game notebook in Application Support/Dottie/Games: controls, the user's own `my-controls.txt` (KEY = what it does, editable, read fresh at every decision), facts, guesses, deaths, lessons, genre starters, places by picture and landmark directions, place recognition with feature prints. |
| `DottieVideoGameTools.swift` | ~130 | Voice tools: `game_command` for co-op calls and taught keys while a game is played, `gameplay_recording` (start with a name, stop, play back, list, status, open by voice), `game_maps`. |
| `DottieGuideBrain.swift` | ~140 | Guides (guide_user) think with Claude Sonnet through the user's Claude plan in MausBot (bot "Dottie Guide", screenshot saved as a file, new conversation per step, 35 s cap), falling back to Gemini Flash when Claude isn't there or is too slow. Before the first step the guide looks up the app's own how-to on the web, and each click target is checked on screen (Accessibility, text, vision) before it's shown. |
| `DottieAppLessons.swift` | ~90 | The user's corrections about how their apps work (`save_app_lesson` voice tool), kept per app in `AppLessons.json` and given to every guide for that app. |
| `DottieSkillFolderTools.swift` | ~210 | `install_skills` voice tool: installs every skill in a folder the user names by path or name, has open in Finder, or picks (a SKILL.md folder, a folder of them, or a downloaded repo with skills one level down), after an on-screen confirm, and turns each new one on for every Dot. Home → Skills → "Add a skill folder…" takes a folder of skills too. |
| `DottieBuiltInSkills.swift` | ~90 | Building, Mac-app and app-operating instructions as skills helpers load only when needed (Gemini CLI user skills; Claude bot skills). |
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
