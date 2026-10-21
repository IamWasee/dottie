# Game 3D map: build checklist

Asked for by celly on 2026-10-21. Dottie builds a 3D map of each game from screenshots as she plays, keeps it on disk per game, loads it into RAM when that game starts, never maps the same place twice, and uses it to move "blind": she plans routes and exact key holds from the map and only glances at the screen to check.

Tick items as they land. Everything here is on the Mac; nothing new goes through the Worker.

## 0. Ground rules

- [x] The old 2D map is erased: `DottieGameMap.swift`, its tools in the screen-job runner (`note_landmarks`, `walk_to_landmark`, `look_around`), the map summary in screen steps, and its saved files in `Application Support/Dottie/GameMaps/` (deleted once on launch).
- [x] Gameplay recordings in `Application Support/Dottie/GameData/` are never touched.
- [x] Memory budget: Dottie stays under 4-5 GB on an 8 GB Mac. The depth model is Depth Anything V2 Small in Core ML (Apple's build, Apache-2.0, about 50 MB). VGGT and Depth Anything 3's large models are out: too big.
- [x] Each game's map is capped: 600,000 voxels in RAM, 1,500 keyframes on disk.

## 1. Movement model (`DottieGameMovement.swift`)

How this game's character moves, learned while playing and saved per game in `Games/<game>/movement.json`.

- [x] Degrees the camera turns per mouse point (measured on small turns by lining up the before and after frames; moved here from the old map).
- [x] Horizontal field of view (starts at 70°).
- [x] Walk speed in map units per second, sprint factor, and a confidence count.
- [x] Learning walk speed: when Dottie walks somewhere she knows and recognizes the place, the gap between where dead reckoning put her and where she really is corrects the speed.
- [x] Seconds needed to cover a distance, with or without sprint.

## 2. Depth (`DottieGameDepth.swift`)

- [x] Downloads Apple's Core ML Depth Anything V2 Small from Hugging Face the first time a game is played, into `Application Support/Dottie/Models/`, and compiles it once.
- [x] Runs it off the main thread on one frame at a time, at most one frame in flight.
- [x] Returns relative depth (near is high); the map turns it into distance with a per-game scale.
- [x] If the model can't be downloaded, mapping still records keyframes and places, just without 3D points.

## 3. The 3D map (`DottieGameWorldMap.swift`)

- [x] Pose: position on the ground (x, y) and camera heading, updated from the keys held and camera turns (dead reckoning).
- [x] Voxels: points from the depth map placed in 3D around the pose (0.5-unit voxels), skipping the HUD strips at the top and bottom and the player's own character in the middle.
- [x] Keyframes: a small picture plus its pose, every time Dottie stands somewhere new.
- [x] No remapping: a frame is only mapped when no keyframe sits within 2 units and 35° of the current pose. Known places are never mapped again.
- [x] Relocalizing: each new view is compared with the keyframes (Vision feature prints). A match snaps the pose to the saved one and teaches the walk speed.
- [x] Places: named spots (the shop, the spawn) with their position, from the brain's `place` and from `go_to` targets.
- [x] Saved per game in `Games/<game>/map/` (`voxels.bin`, `keyframes.json`, `keyframes/*.jpg`, `places.json`), loaded into RAM at the start of play, saved when play stops and every 2 minutes.
- [x] Summary for the brain: how much is mapped, where Dottie is, and each known place with its direction, distance and walking time.

## 4. Familiar or new

- [x] When a game starts, Dottie checks for a saved map. Familiar: the brain is told what's mapped and where things are. New: she says she's mapping as she goes, and mapping runs automatically.

## 5. Routes and blind play (`DottieGameNavigator.swift`)

- [x] Floor plan from the voxels: a cell is blocked when enough points sit at body height above the floor.
- [x] A* path from the pose to a place, through mapped floor (unmapped cells allowed but costlier).
- [x] The path becomes legs: turn so many degrees, hold W (and shift) for so many seconds.
- [x] New brain step `go_to_place` runs those legs without asking a model, glancing about once a second for free (frame change, darkness, loud sound, stuck), and relocalizing at the end.
- [x] Brain step `go_to` (steer toward a target box) stays for things that aren't on the map yet.

## 6. Brain models

- [x] Haiku 5.5 thinks by default.
- [x] Sonnet 5.5 takes over only when needed: the brain marks a plan `"hard": true`, or the same trouble repeats (stuck or failing twice in a row). It hands back to Haiku after a good step.
- [x] Gemini stays the backup when Claude isn't available.

## 7. Jumps, blockers and the reflex model (second build, asked for on 2026-10-21)

- [x] Learned jump height and distance per game (`DottieGameMovement`): start at 1 unit high and 2 units far, raised by planned jumps that clear, lowered by ones that leave her stuck. Old `movement.json` files still load.
- [x] Jumps in routes (`DottieGameNavigator`): something at body height that's lower than the jump is a low thing to jump over (costs more than open floor); the leg gets a jump spot a little before it, and the walk presses jump there.
- [x] Ledges and pits: cells where the ground is only seen far below are drops, and routes go around them when they can.
- [x] Moving things: getting stuck where the map showed the way clear puts a blocker a step ahead. It fades after 45 seconds (a player, an enemy, a platform). Stuck at the same spot again after it faded means it doesn't move, so it's saved on the map for good.
- [x] Blind walks find another way around a blocker (up to twice) before handing back to the brain.
- [x] celly's local reflex model can drive blind walks too: `DottieGameReflexModel.nextBlindMove` gets the frame, the place, the leg and how far into it she is; returning nil keeps the planned keys.

## 8. Later (not in this build)

- [ ] Multi-frame reconstruction (Depth Anything 3 small) for sharper geometry.
- [ ] A real navigation mesh (Recast/Detour style) with heights, so stairs, slopes and several floors plan properly instead of the flat grid.
- [ ] Moving things tracked as they move (where an enemy is heading), not just as spots to avoid.

## Needs testing on a Mac

- [ ] The model download works and the Core ML model loads (first game start).
- [ ] Roblox: walk around, quit, start again, and check Dottie says she knows the game and doesn't remap the start area.
- [ ] `go_to_place` reaches a named place without the brain in between.
- [ ] Memory stays under 4-5 GB while playing.
- [ ] A route over something low: Dottie jumps at the right moment, and the jump height in `movement.json` moves after a few tries.
- [ ] Stand a player in the way of a known route: Dottie goes around, and the spot isn't saved as blocked once they've moved.
