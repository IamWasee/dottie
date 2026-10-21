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

## 8. Research, map mode and map files (third build, asked for on 2026-10-21)

- [x] Dottie names the game from what the user asked ("build a golem roblox"), the window and the screen text, so each Roblox experience gets its own notebook and map instead of sharing one called "Roblox". A game she knows keeps its exact name.
- [x] Before the first session (and every two weeks), she searches the web for the game and writes a short guide (what it is, the goal, how to progress, controls, tips) into the notebook, which the brain reads every turn.
- [x] "Map this game for me": the user plays, Dottie follows on the map with their keys and mouse, maps every new spot, and gameplay recording runs too. Ends on "done", stop, or after 30 minutes.
- [x] Every save draws the map from above (`map/overview.png`) and writes `map/report.txt` saying whether the depth model works, how many spots were recognized and what movement she has learned.
- [x] "Game maps" button in the menu bar panel opens the maps in Finder.
- [x] `game_maps` voice tool: list maps, open one, or delete one (after an on-screen confirmation; the notebook and recordings stay).

## 9. Fixes from the first Mac test of Build a Golem (2026-10-21)

- [x] The controls test only counts once it learned something, writes what it learned straight into the notebook, and runs again for games it got wrong before (routine version 3). Walking no longer reads as "a menu opened": a menu also needs new text on screen. A default key that did nothing is tried once more at the end.
- [x] The game lookup runs while Dottie starts playing instead of before. A lookup that found nothing waits a day, and the play log says why it failed. Searches drop the brackets ("Build a Golem Roblox") and try the bare name when the longer searches find nothing; the Worker's search also asks Roblox's own search for Roblox games.
- [x] Every captured frame goes to the map (not only brain looks and walking), except while trying keys or watching the user. Every minute she turns all the way around in eighths, so the map covers every direction.
- [x] Floor and walls: the bottom of the view either side of the player is taken as ground, which gives the camera's tilt and height, so open ground lands at floor height instead of reading as wall.
- [x] Recognizing spots: prints leave out the HUD strips and are made from the 320-point picture for saved and live views alike (older spots get new prints from their pictures). Before she knows where she is, a looser match counts when it clearly beats every other spot, and the play log shows how close the nearest spot came.
- [x] A brain look that fails tries a second Gemini model, and play stops only after five failed looks in a row, waiting a little longer each time. The play log says why each one failed.
- [x] `report.txt`'s "Is it working?" lines are worked out from the map instead of fixed text.
- [x] Tasks with several parts: the brain writes the parts down (`task_parts`), gets its plan back every look, and moves on to the next part by itself.
- [x] Finding things off screen: map places first, then look around (views labeled +90°, 180°, -90°), then signs, minimap and exploring, then the wiki. `turn_to` turns to face a box exactly instead of guessing degrees.
- [x] Naming places: a name given before she knows where she is waits and is placed once she does (it was dropped before). "This is the sell area" or "remember this as the shop" names her spot at once. A `go_to` whose target was already big when it went out of view counts as reached, so its name lands on the map. The brain is told to name every landmark it's next to.
- [x] Walking no longer ends a step as "the screen changed a lot": a big change only counts when several new lines of text come up with it (a menu).
- [x] Teleports: a black screen (loading, portal, respawn) makes her find where she is again; if nothing looks familiar after 30 seconds, the new area is mapped as its own zone, 500 units away, instead of on top of the old one.
- [x] Light map (celly's idea): every frame she sees about once a second (not only new spots) casts its ~10,000 depth samples from her position, and each lights a small block (1/8 unit, a quarter of the walking grid) with the color it saw, averaged over sightings. Kept in `map/detail.bin` (13 bytes a block, up to 1.5 million). Walking plans still use the coarse grid.
- [x] Spawn is 0,0,0 and is known by sight too: views taken at spawn are saved in the game's `spawn/` folder (outside `map/`, so deleting the map keeps them). Seeing one snaps her to 0,0,0; an empty map with a known spawn waits until she sees spawn so the new map keeps the same origin. Every session starts with a look around, which saves spawn's views the first time and finds where she is after that.
- [x] The map as a 3D model: every save writes `map/map3d.obj` (colored blocks, opens in Preview, Blender or MeshLab), and "open the 3D map of <game>" opens it.

## 10. Later (not in this build)

- [ ] Multi-frame reconstruction (Depth Anything 3 small) for sharper geometry.
- [ ] A real navigation mesh (Recast/Detour style) with heights, so stairs, slopes and several floors plan properly instead of the flat grid.
- [ ] Moving things tracked as they move (where an enemy is heading), not just as spots to avoid.

## Needs testing on a Mac

- [ ] The model download works and the Core ML model loads (first game start).
- [ ] Roblox: walk around, quit, start again, and check Dottie says she knows the game and doesn't remap the start area.
- [ ] `go_to_place` reaches a named place without the brain in between.
- [ ] Memory stays under 4-5 GB while playing.
- [ ] A route over something low: Dottie jumps at the right moment, and the jump height in `movement.json` moves after a few tries.
- [ ] Say "play build a golem roblox": Dottie says she's looking it up, and the game's `notebook.json` gets a `guide`.
- [ ] Say "map this game for me", walk around, say "done": `map/overview.png` shows the spots, and `report.txt` shows 3D points above 0.
- [ ] Ask Dottie to delete a game's map: the confirmation shows, and the `map` folder is gone afterwards.
- [ ] Stand a player in the way of a known route: Dottie goes around, and the spot isn't saved as blocked once they've moved.
