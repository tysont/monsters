# Monster Lane Wars: Implementation Plan

Working title. "Hatch a Monster" and "Monster Fighters" are the other candidates; the name is not final.

## How to use this document

- Phases are implemented one at a time, in order. A phase is not started until the previous one is marked Complete.
- Every phase has a **Status** line, a task checklist, acceptance tests, a performance gate, and an **Implementation notes** section. Phase 3 also has a **Fun gate** that must pass before the phase is Complete.
- Status values: `Not Started`, `In Progress`, `Blocked`, `Complete`.
- When a phase is in progress, tick tasks as they land and record anything surprising under Implementation notes (decisions made, deviations from the plan, numbers measured, known issues carried forward).
- A phase is Complete only when every acceptance test passes, any fun gate passes, and the performance gate is met on the reference devices. Until Phase 15, low-end PC results are approximated on the development PC (see section 2) and must be labelled as approximated.
- API names and engine limits in this plan are from general knowledge of the Roblox engine and were not re-verified when the plan was written. Confirm each against current Roblox documentation at the start of the phase that uses it.

## Phase overview

| # | Phase | Status |
|---|---|---|
| 0 | Project foundation and tooling | Complete |
| 1 | Map greybox | Complete |
| 2 | Teams, sessions, and round skeleton | Complete |
| 3 | Player combat core | In Progress |
| 4 | UI foundation and HUD v1 | Complete |
| 5 | Minion system and load harness | Complete |
| 6 | Guardians and Titan (first full round) | Complete |
| 7 | Jungle camps and monster kit | Complete |
| 8 | Eggs and hatcheries | Complete |
| 9 | Persistence, levels, and pets | Complete |
| 10 | Classes | Complete |
| 11 | Balance, anti-snowball, and telemetry | Complete |
| 12 | Gold, cosmetics, and monetization | Complete (Robux products in Phase 16) |
| 13 | UX polish, onboarding, audio, and effects | Not Started |
| 13B | Mobile and console pass | Not Started |
| 14 | Admin panel, live ops, and anti-cheat | Not Started |
| 15 | Soft launch and launch | Not Started |
| 16 | Purchases go live | Not Started (after all game development) |

---

## 1. Game summary

A casual, large-team lane war. Two teams fight across a three-lane map. Each lane is defended by Guardian monsters; each base is defended by a Titan. When a Titan falls the round ends, teams reshuffle, and the map resets. Players drop in and out at any time.

### Design decisions already made

| Area | Decision |
|---|---|
| Structure | Eternal war. Only territory resets between rounds. |
| Map | Three lanes, jungle between them, one base per team. |
| Guardians | Large stationary monsters in place of towers. Outer and inner guardian per lane per team (12 total). |
| Titan | One final monster per base. Its death ends the round. |
| Minions | Small monsters that spawn in waves and march down lanes. |
| Jungle camps | Monster groups that drop an egg of their type when cleared. |
| Hatcheries | Six total: one per lane per team, behind the outer guardian and in front of the inner guardian. |
| Eggs | Carried from a camp to a hatchery, incubate, then hatch. On hatch the owner chooses: claim as a pet, feed to an existing pet for pet XP, or unleash on that hatchery's lane. Eggs never convert to gold and do not persist between rounds. |
| Raiding | Enemy players can steal incubating eggs and carry them home. Hatcheries cannot be captured. |
| Classes | Knight, Hunter, Mage, Healer. One weapon per class. |
| Class selection | A picker on first join, defaulting to Knight. Switch class at your base (a class station in the spawn area) or on the respawn screen, including mid-round. No switching in the field. |
| Level | Persistent, per class. Each class has its own level and XP; XP earned goes to the active class. The active class's level is the only source of player stats, on a flattening curve. The number keeps climbing as status and unlocks. |
| Account level | The sum of all class levels. Shown on the nameplate with the class level. Gates the second and third pet slots and titles. |
| Catch-up XP | A class below the player's highest class level earns double XP until it reaches that level (multiplier in Config). |
| Abilities | Each class unlocks its full core ability kit by class level 10. |
| Pets | Persistent stable of up to three, one active at a time. Pets and pet XP are account-wide. |
| Gold | Earned in play or bought with Robux. Cosmetics only. Never affects stats. Gold and cosmetics are account-wide. |
| Purchases | Nothing bought with Robux may change the rate or ceiling of any stat, including how fast XP is earned. |
| Fairness | A maxed player is about 1.5 times a new player in combat power. Cooperative attackers get a bonus against stronger targets. |
| Team balance | Balance is headcount and strength together. Each member has a power value (their combat multiplier: 1.0 new, about 1.5 maxed); team strength is the sum. Headcount never differs by more than one; within that, joins and reshuffles favour the weaker team, and the strength gap drives small equalisers (Phase 11). Equalisers make matches slightly more even; they never let a far weaker player beat a far stronger one alone. |

### Assumptions made for this plan (confirm or change before Phase 1)

| # | Assumption | Why it matters |
|---|---|---|
| A1 | 20 versus 20, server cap 40 | Sets map scale and every performance budget |
| A2 | Defeated guardians stay dead for the round (no taming) | Simplest win path; taming changes Phase 6 |
| A3 | PC (mouse and keyboard) is the primary platform; phones, tablets and consoles come in a later pass (Phase 13B) | Drives controls, UI size, and render budgets |
| A4 | Third-person camera, standard Roblox character controller | Affects combat feel and telegraph design |
| A5 | Six monster types at launch, three built in Phase 7 | Content cost |

---

## 2. Technical architecture

### Stack and repository

- **Language:** Luau with `--!strict` in all modules.
- **Sync:** Rojo project, code in Git, so implementation can be done in an external editor or by an agent. Studio is used for running, play-testing, and art.
- **Packages:** Wally for dependencies.
- **Quality:** Selene (lint), StyLua (format), Luau LSP strict type checking, and unit tests run under Lune. All of it runs locally with `make check` before every commit; there is no hosted CI.
- **Tooling:** Rokit pins every tool. `make` targets wrap each step; recipes are single commands so they work from PowerShell, Git Bash and macOS, and anything more involved is a Lune script in `scripts/`.
- **Layout:**

```
src/
  server/
    Main.server.luau   creates remotes, starts services
    Services/          one module per service (Round, Teams, Combat, Minions, Monsters, Eggs, Data, Admin)
  client/
    Main.client.luau   starts controllers
    Controllers/       one module per controller (Input, Camera, Render, UI, Audio)
    UI/                design system components and screens (from Phase 4)
  shared/              Config, Net, Remotes, Loader, types, math, monster definitions
tests/                 Lune unit tests (*.spec.luau) and the bot load harness
scripts/               Lune tooling scripts used by make targets
assets/                models and animations referenced by ID (when needed)
```

- **Requires:** inside one container (`server`, `client`, `shared`) modules use string requires (`require("./Config")`, `require("@self/Guard")`), which resolve the same way in Roblox, Lune and luau-lsp. Across containers they use instance paths (`require(ReplicatedStorage.Shared.Config)`). Shared modules that hold pure logic must not touch the engine when required, so Lune can test them.

### Core patterns

- **Server authority.** The server owns all health, damage, positions of NPCs, egg ownership, and currency. Clients send intent ("attack", "dodge", "pick up") and never results.
- **Data-driven NPCs.** Minions, monsters, guardians, and pets are rows in server-side arrays (ID, type, team, position, health, state, target). No Humanoid or physics instance exists on the server for them. The damage pipeline treats player characters and NPC rows as targets through one interface.
- **Pure simulation logic.** Combat, NPC and round rules live in pure shared modules (no engine access when required, time and randomness injected), so they are unit tested under Lune and can run headless for bot-versus-bot simulation (Phase 11).
- **Bots.** Roblox cannot create fake `Player` objects, and bots built as full characters would add server physics cost that real players (simulated on their own clients) do not. Bots are lightweight server-side entities that drive the same combat and movement code paths as players. Client frame rate is measured separately with several real clients (Studio multi-client test).
- **Client-side rendering.** Clients keep a pool of anchored models, place them from replicated state, interpolate between updates, and play animations and effects locally.
- **Compact networking.** One typed net module defines every remote. NPC snapshots are packed into `buffer` values and sent over unreliable remotes at 10 Hz with delta encoding. Unreliable remote events over 1000 bytes are dropped, so snapshots are chunked by interest cell with an entity cap per message, keeping each message under 900 bytes for headroom. Reliable remotes carry only events that must arrive (deaths, egg pickups, round changes).
- **Spatial grid.** A uniform grid over the map indexes players and NPCs for target finding and area hits, replacing physics overlap queries.
- **Interest management.** Each client receives NPC snapshots only for grid cells near it, plus a low-rate summary of the rest for the minimap.
- **Config in one place.** All tunable numbers live in `shared/Config` and are read through `Config.get()`. From Phase 14, Roblox ConfigService supplies live overrides behind `Config.get()` (see Phase 14).
- **Player data.** Session-locked profiles on DataStore through a profile library (ProfileStore or equivalent), with versioned schemas and migrations. Development happens in the main place, so data store names are namespaced by environment from `Config` (for example a `dev_` prefix in Studio) and Studio sessions never touch live player data.
- **Map content.** The greybox map (Phase 1) is generated by code at runtime from `MapLayout`, so it can be resized by changing numbers. Final map art (Phase 13) is built in Studio and lives in the cloud place, laid out on the same `MapLayout` positions.

### Performance budgets

| Budget | Target |
|---|---|
| Players per server | 40 |
| Live minions | 150 typical, 300 worst case |
| Live monsters (camps, guardians, Titans, unleashed, pets) | 100 worst case |
| Server simulation time | Under 5 ms per frame at worst case |
| Server frame rate | 60 Hz held, NPC logic ticked at 10 Hz |
| Network send per client | Under 50 KB/s average, under 100 KB/s peak |
| Client frame rate | 60 on mid-range PC, 30 minimum on low-end PC (phone targets set in the Phase 13B mobile pass) |
| Client memory | Under 1.5 GB on PC (under 1 GB on phone from the Phase 13B mobile pass) |
| Map instances | Under 15,000 parts, instance streaming enabled |
| Join to playable | Under 15 seconds on low-end PC |

### Reference devices

PC is the primary platform. Gates are measured on:

| Tier | Spec | Notes |
|---|---|---|
| Low-end PC | Laptop, 4-core CPU, integrated graphics (Intel Iris Xe or AMD Radeon Vega class), 8 GB RAM, 1080p, Roblox graphics on automatic | Minimum target; most performance gates use this |
| Mid-range PC | Desktop, 6-core CPU, GTX 1660 or RTX 3050 class GPU, 16 GB RAM, 1080p | Target for 60 frames per second |
| Development PC | The machine Studio runs on | Day-to-day checks and Studio playtests |

No low-end PC is available during development. Until Phase 15, low-end PC gates are approximated on the development PC with Roblox graphics quality at minimum and the client limited by a CPU cap (for example processor affinity limited to two cores). Record these results as "approximated". Phase 15 verifies every gate on real low-end hardware before soft launch.

Added in the Phase 13B mobile and console pass: a mid-range Android phone (Galaxy A54 class), an iPhone 12 class phone, an iPad (9th generation class), and an Xbox Series S with controller.

---

## Phase 0: Project foundation and tooling

**Status:** Complete

**Goal:** A repository that builds into a Roblox place, with lint, types and tests run locally through `make`.

**Tasks**

- [x] Create the Roblox experience. Development happens in the main place; a separate test place is deferred until we publish (moved to Phase 15).
- [x] Set up the Rojo project, Wally manifest, Selene, StyLua, and Luau LSP configuration.
- [x] Create the folder layout from section 2 with the server and client bootstraps.
- [x] Write the service loader: ordered start-up for server services and client controllers.
- [x] Write the typed net module (remote creation, naming, payload validation, per-player rate limits).
- [x] Write `shared/config` with a typed table and environment switch (dev, test, production).
- [x] Add a unit test runner and passing tests.
- [x] Add `make check`, which runs format check, lint, type check, and tests locally (replaces hosted CI).
- [x] Add a developer debug overlay showing server frame time, heartbeat rate, network send and receive, instance count, and memory.
- [x] Choose and record the reference devices (PC-first; see section 2).

**Acceptance tests**

- [x] A fresh clone builds with `make setup` and syncs into Studio with Rojo.
- [x] `make check` fails on a format error, a lint error, a type error, and a failing test.
- [x] The main place runs in a Studio playtest and shows the debug overlay (phone check moved to the Phase 13B mobile pass).

**Performance gate:** None; record the empty-place baseline numbers.

**Implementation notes**

- **Make on Windows:** GNU make from winget (`ezwinports.make`). PowerShell has no `sh`, so every recipe is one plain command; logic lives in Lune scripts (`scripts/test.luau`, `scripts/fetch-types.luau`).
- **Tests:** Lune with a small in-repo harness (`tests/TestKit.luau`) instead of TestEZ or Jest-Lua. It needs no packages, runs in about a second, and the same specs can later run inside Studio for engine-dependent code. Lune has no `task` or `Vector3`, so testable modules take those as injected dependencies (for example `Loader.run(modules, { spawn = ... })`).
- **Loader:** modules declare `name` and optional `dependencies`, `init()` and `start()`. Every `init` runs in dependency order and must not yield; then every `start` runs in its own thread. Cycles, unknown dependencies and duplicate names fail at start-up. Placeholder services for later phases were not created; each phase adds its own.
- **Net:** all remotes are defined once in `Shared.Remotes`. Client-to-server calls are rate limited per player (token bucket, default 10/s with a burst of 20), limited to one argument, and validated with a `Guard` check that rejects NaN, infinity, oversized strings and arrays, and unexpected table keys. Rejections go to `Net.setViolationHandler` (logs for now; anti-cheat in Phase 14). Server-to-client payloads are validated on the client only outside production.
- **Config:** `Config.get()` is resolved once and deeply frozen. Studio is `dev`, live servers are `production`, and setting the `Environment` attribute on `game` forces one (for example `production` in Studio).
- **Debug overlay:** toggle with F2 or by tapping it. Shown to everyone in dev; in production only to the experience owner and `Config.debug.overlayUserIds`. Server stats go only to players who have it expanded, over an unreliable remote once a second.
- **Verified in Studio:** string requires resolve in Roblox; a playtest starts one service and one controller; the overlay shows client and server stats; a wrong payload type, an extra argument and a flood of 20 calls were each dropped with a logged reason.
- **Empty-place baseline (Studio, laptop, not representative of devices):** server 60 Hz with a 16.7 ms average and 19.5 ms worst frame interval; server send about 0.5 KB/s with the overlay open; 1 player. Studio's memory (about 2.5 GB) and instance counts (about 55,000) include Studio itself; record a standalone-client baseline on the low-end PC when Phase 1 is measured. `Stats.HeartbeatTimeMs` reads 0 in Studio; check it on a live server.

---

## Phase 1: Map greybox

**Status:** Complete

**Goal:** The full map in simple blocks, generated from a layout table, so it can be walked, measured, and resized cheaply.

**Tasks**

- [x] Define `MapLayout` in shared config: map bounds, lane splines (top, middle, bottom) as ordered control points, base positions, spawn zones.
- [x] Add marker positions: 12 guardians (outer and inner per lane per team), 2 Titans, 6 hatcheries, 12 jungle camps, minion spawn points.
- [x] Write a generator that builds the greybox from `MapLayout` at runtime (code in the repo, not saved in the place): ground, lane surfaces, jungle walls and paths, base platforms, coloured marker blocks.
- [x] Mirror the layout so both teams have identical geometry.
- [x] Enable instance streaming and set streaming radii.
- [x] Set collision fidelity to simple shapes on everything.
- [x] Add team-coloured spawn locations and a temporary spawn at each base.
- [x] Add a developer free-camera and a top-down overview camera.
- [x] Add lane-distance helpers (position to lane progress, progress to position) with unit tests.
- [x] Add a temporary sprint or speed debug toggle for traversal testing.

**Acceptance tests**

- Walking a full lane from base to base takes 60 to 90 seconds at default walk speed.
- Jungle paths connect all three lanes; no dead ends; nothing can be climbed out of bounds.
- Every hatchery sits between its lane's outer and inner guardian markers.
- Changing one number in `MapLayout` rescales the map correctly.

**Performance gate:** 60 frames per second on the mid-range PC anywhere on the map; part count recorded.

**Implementation notes**

- **Layout:** `src/shared/Config/MapLayout.luau`. Bases sit west (team 1) and east (team 2); the middle lane is straight and the top and bottom lanes bend out towards the map edges. Only team 1's half is authored; `Shared.Map` mirrors it across x = 0 for team 2, and mirrors the north jungle across z = 0 for the south. `scale` multiplies every horizontal distance.
- **Lanes are polylines** (straight segments between control points) rather than curved splines. Progress along them is linear and exact, which suits the Phase 5 minion movement; corners can be softened later by adding control points.
- **Lane lengths:** middle 1100 studs (69 s at walk speed 16), top and bottom about 1316 studs (82 s).
- **Data-checked acceptance tests:** `tests/shared/Map.spec.luau` checks lane walking times, marker counts, that each hatchery's lane progress lies between its inner and outer guardian, mirroring, that walls are too tall to jump onto and clear of lanes and markers, a grid flood fill showing every lane, structure, camp and the enemy base is reachable on foot, and that changing `scale` rescales everything.
- **Simple collision:** the greybox uses only plain block parts, which always have simple box collision. Marker blocks are non-colliding, because guardians, camps and the rest become data-driven NPCs in later phases.
- **Streaming:** the greybox model is `Persistent` (it is small, and the dev cameras need the whole map); final art will use normal streaming.
- **Dev tools:** F3 overview camera, F4 free camera (WASD, E/Q, Shift, right mouse to look), F6 4x walk speed (checked on the server against DebugAccess). The current state shows in the debug overlay.
- **Studio incident (2026-11-22):** a single MCP call that set `Workspace.StreamingEnabled` and removed the template Baseplate and SpawnLocation hung; Studio and the Rojo task were later found stopped (Rojo exited with 0x40010004 and the task did not restart it). Rojo was restarted from its scheduled task and the place reopened; the edit had not applied. Streaming was already on, so setting `StreamingEnabled` from MCP is the likely cause; the radii and the template removal then worked as separate small calls. Make one small change per MCP call when editing place properties.
- **Place changes (need saving in Studio):** template Baseplate and SpawnLocation removed; `StreamingMinRadius` 192 and `StreamingTargetRadius` 768 (streaming was already enabled).
- **No PlayerModule:** this place has no `PlayerModule` in PlayerScripts (character controls are built into the engine), so `GetControls()` is not available. The dev cameras freeze the character by anchoring its root part on the client instead. Phase 3's input layer must not assume PlayerModule either.
- **Atmosphere haze:** the place's Atmosphere (density 0.3) turns the map grey from overview height; dev cameras set it to 0 locally while active and restore it afterwards.
- **Verified in Studio:** the map generates (73 parts, 38 markers); the player spawns at a base; the F3 overview shows the whole mirrored map; F4 free camera moves without moving the character and releases it on exit; F6 sets walk speed to 64 and back to 16. The console is clean apart from the pre-existing template asset warning.
- **Lane walk (acceptance):** the character was walked along the lanes at walk speed 16 by server `MoveTo` waypoints: middle 72.3 s, top 84.9 s (data: 68.8 s and 82.3 s; the extra time is slowing at each waypoint). Both are inside 60 to 90 s. Bottom is the mirror image of top.
- **Performance gate:** 60 FPS (Studio's frame cap) with the whole map in view, 73 parts. Measured on the development PC (Ryzen 7 7700, Radeon RX 9070 XT, 32 GB), which is well above the mid-range reference, so this is weaker evidence than the gate asks for; with 73 plain parts the risk is negligible. Re-check on mid-range and low-end hardware with the Phase 15 verification.

---

## Phase 2: Teams, sessions, and round skeleton

**Status:** Complete

**Goal:** Players join, land on the smaller team, spawn, respawn, and go through a round reset.

**Tasks**

- [x] Team service: two teams, assign each joiner to the smaller team, tie broken toward the team that is behind (hook only; "behind" defined in Phase 11).
- [x] Keep friends who join together on the same team where balance allows.
- [x] Handle leavers: update counts, flag imbalance for the fill logic.
- [x] Spawn and respawn at the team base with a respawn timer and brief spawn protection.
- [x] Round state machine: `Starting`, `Active`, `Ending`, `Intermission`, with replicated state and timers.
- [x] Round end sequence: freeze input, show result, reshuffle teams, reset map state, start next round.
- [x] Late join: a player joining in any state lands in the right place.
- [x] Developer commands (dev builds only): end round for a team, switch team, add a bot (a server-side bot entity, see section 2; not a fake player).
- [x] Server shutdown handling: graceful message and teleport on update (Phase 14 extends this into the full soft-shutdown and migration flow).
- [x] Unit tests for assignment, reshuffle, and state transitions.

**Acceptance tests**

- Ten clients joining in any order never produce teams differing by more than one.
- Twenty consecutive round resets leave no leftover state and no errors.
- A client joining during `Ending` or `Intermission` is playable when the next round starts.

**Performance gate:** No measurable server cost from round logic at 40 players.

**Implementation notes**

- **Pure rules (Lune tested):** `Shared.TeamAssignment` (joiner team choice, friend groups as connected components, reshuffle), `Shared.Round` (phase machine, respawn delay, clock format), `Shared.Signal` (typed in-process signal). 24 new tests, 85 in total.
- **Join rule:** smaller team first; on a tie, the team with more of the joiner's friends; then the `TeamService.behindTeam` hook (returns nil until Phase 11); then random. Friends can only decide ties, so friends-together never unbalances teams. Friend checks (`IsFriendsWithAsync`) run in parallel with a 3 s cap before assignment.
- **Reshuffle:** friend groups are shuffled and placed largest first on the smaller team; a group too big to fit is split so the teams never differ by more than one.
- **Services:** `TeamService` (Roblox `Team` objects named from `Config.teams`, `Members`/`Bots` attributes per team, `Imbalance` attribute on Teams for the Phase 11 fill logic); `CharacterService` (manual spawning with `CharacterAutoLoads` off, respawn timer via the `RespawnAt` player attribute, and movement: round freeze plus the dev speed multiplier; Phase 3 stats will feed in here); `RoundService` (machine on `workspace:GetServerTimeNow()`, state replicated as attributes on ReplicatedStorage, `phaseChanged` and `roundReset` signals); `ShutdownService`.
- **Round flow:** Ending freezes input (WalkSpeed and JumpHeight 0) and shows the result; Intermission reshuffles, fires `roundReset` (map geometry is static, so later phases reset their own NPC, guardian and egg state on this signal), respawns everyone at their new base and unfreezes; Starting spawns anyone missing. Defaults: Starting 10 s, Ending 10 s, Intermission 15 s, respawn 5 s + 0.25 s per minute (max 15 s), 3 s spawn protection (SpawnLocation ForceField; Phase 3 damage must respect it).
- **Bots** are team slots for now (they count towards balance and reshuffle); Phase 3 gives them bodies.
- **Team strength (added after review, 2026-11-22):** balance is headcount plus strength. `TeamAssignment.balance` returns headcounts, strength (sum of member power), the gap, team 1's share and the weaker team. Joiners: smaller team first; on equal headcount, the weaker team when the gap exceeds `Config.teamBalance.strengthTolerance` (0.25); then friends, the behind hook, random. Reshuffle: groups placed largest then strongest first onto the weaker team, then single members swapped across teams while that narrows the gap (friend groups are never split for strength). `TeamService.powerOf` returns 1.0 for everyone until Phase 9; `TeamService.balance()` and the `Strength` (per team) and `StrengthGap` (on Teams) attributes expose the numbers, and the placeholder HUD shows them. 8 new tests (93 in total).
- **Dev commands** are chat commands (`TextChatCommand`, checked against DebugAccess on the server): `/endround [team]`, `/switchteam`, `/addbot [n]`, `/clearbots`, `/timescale [n]`, `/shutdowntest`, `/devhelp`. Replies arrive as chat system messages over the `DevMessage` remote.
- **Soft shutdown:** on `BindToClose` (not in Studio) players see a message and are teleported together to a new reserved server (`TeleportOptions.ReservedServerId` = new GUID, teleport data `softShutdown`); that server detects itself (`PrivateServerId ~= ""` and `PrivateServerOwnerId == 0`) and sends players back to a public server after 5 s. Teleports cannot run in Studio; only the message path was verified (`/shutdowntest`). Verify on a live server at the first real update.
- **Placeholder HUD:** `RoundHudController` shows round, phase and timer, team sizes (with bots, your team marked), the result banner, the respawn countdown and the shutdown message. Phase 4 replaces it.
- **Deprecated APIs avoided:** `LoadCharacterAsync` and `IsFriendsWithAsync` replace `LoadCharacter` and `IsFriendsWith`.
- **Acceptance, ten joiners:** 200 random ten-member join sequences in unit tests never exceed a difference of one; in Studio, the player plus `/addbot 9` (same assignment path) gave 5 vs 5. Studio's MCP tooling can only run one real client, so a real ten-client join and live friend grouping were not exercised; run Studio's multi-client test (Test tab, Clients and Servers) for a real-client check.
- **Acceptance, twenty resets:** with `/timescale 20`, twenty `/endround` cycles (rounds 2 to 22) ran in 38 s with no errors. Instance count (54,909), workspace parts (91) and workspace children were identical before and after; Lua heap grew 31 KB; teams were still 5 vs 5 and movement was restored.
- **Acceptance, late join:** a player with no character during Intermission was spawned at Starting and was playable (health 100, walk speed 16) when the round went Active. A real join runs the same assignment-then-spawn path verified at session start; a joiner during Ending is also respawned by Intermission.
- **Also verified in Studio:** death gave a 5.1 s respawn at the team base with a ForceField; `/switchteam` moved the player to the other team and base; the result banner and freeze appeared during Ending.
- **Performance gate:** the round logic's pure functions measured on Studio's server: a round tick 0.17 µs (run 5 times a second), a 40-member reshuffle with friend groups 33 µs (once per round), choosing a joiner's team 0.14 µs. The server held 60 Hz (16.65 ms average frame) throughout.
- **MCP note:** `TextChannel:SendAsync` called directly in an MCP `execute_luau` never returns; send chat from a spawned thread.

---

## Phase 3: Player combat core

**Status:** In Progress

**Goal:** One class (Knight) that can attack, dodge, take damage, die, and fight other players, with server-authoritative results.

**Tasks**

- [x] Stats component per player: max health, health, damage, defence, move speed, derived from a single pure stat function whose input is the active class level (stubbed until Phase 9) and the active pet (stubbed).
- [x] Input layer mapping touch, mouse and keyboard, and gamepad to the same actions.
- [x] Melee attack: client plays the swing immediately; server validates range, arc, cooldown, and line of sight, then applies damage.
- [x] Dodge with a short invulnerability window and cooldown.
- [x] Damage pipeline: one function for all damage, with source, target, type, and modifiers, emitting events for UI and telemetry. Targets can be player characters or NPC rows through one interface.
- [x] Health regeneration out of combat and at base.
- [x] Death, kill credit, assist credit (anyone who damaged the target in the last 10 seconds), respawn.
- [x] Lag handling: server accepts hits within a bounded latency window and rejects impossible ones.
- [x] Unit tests for the stat function and the damage pipeline.
- [x] Combat gym: a dev-only test area with a target dummy, a simple bot that walks and attacks, a spawner for a pack of weak enemies, and one test monster that uses a telegraphed ground slam (minimal state machine: idle, telegraph, attack, recover). This is a throwaway precursor to the Phase 6 monster framework, not a replacement for it. Gym enemies and the test monster are built as a minimal version of the data-driven NPC model (server rows, client rendering), not Humanoid characters, so Phase 5 extends this rather than replacing it.
- [x] Placeholder combat feedback: hit flash, hit-stop, knockback, damage numbers, a basic health bar, hit and swing sounds, light camera shake. Rough quality is acceptable; each must be present. Hit-stop is purely visual on each player's own screen and never pauses the server simulation. Damage numbers and the health bar are replaced in Phase 4.
- [x] Live tuning panel (dev builds only) for attack speed, attack range and arc, dodge distance and cooldown, invulnerability window, hit-stop duration, knockback strength, and enemy health.
- [x] Instrument input-to-swing latency and time-to-kill in the gym.

**Acceptance tests**

- Two clients fight; both screens agree on health and on who died.
- With 200 ms simulated latency, attacks still feel immediate and results stay consistent.
- A modified client that sends attacks faster than the cooldown or from out of range deals no extra damage.
- The swing animation starts within 100 ms of input on the mid-range reference PC.
- Weak gym enemies die in one to three hits.
- A player reacting to the telegraph can dodge the test monster's slam every time.

**Fun gate**

- Phase 3 is not Complete until the fun gate passes. Phase 4 does not start before it passes.
- Protocol: at least three players in the target age range (9 to 14) play the combat gym on a PC for five unguided minutes each. The project owner also plays it. Outside playtesters get access by being granted play permission on the main place.
- Pass signals: players keep fighting without prompting, dodge deliberately, and ask to continue or play again; the owner judges the combat enjoyable.
- If the gate fails, tune with the live tuning panel and retest. If it still fails after three tuning rounds, stop and escalate to the owner to reconsider the combat model before any further phase work.
- Record each playtest round, the tuning values used, and the outcome under Implementation notes.

**Performance gate:** 40 server-side bots fighting continuously cost under 1 ms of server time per frame.

**Implementation notes**

- **Status:** everything is built and the automated acceptance tests and performance gate pass. Phase 3 stays In Progress until the fun gate (human playtesters) passes, and the two-client acceptance test still needs a real multi-client session.
- **Pure core (Lune tested, 21 new tests, 114 in total):** `Shared.Combat.Stats` (Appendix A; level 1 = exactly 1.0, the input is class level), `Damage` (the single pipeline: friendly fire, spawn protection, dodge invulnerability, defence, minimum 1 damage, kill and assists within 10 s), `Melee` (range by body edge, arc, nearest-first cap, cooldown with jitter tolerance), `History` (position ring buffer with interpolation, for rewind), `NpcCodec` (snapshot buffers: 10-byte header plus 9 bytes per NPC, split under 900 bytes), `Tuning` (live values with limits).
- **Server authority:** the client sends only a facing direction (`CombatAttack`) or a dodge (`CombatDodge`). `CombatService` checks the round phase and cooldown (0.05 s jitter tolerance), rewinds target positions by the attacker's ping (capped at 0.25 s), selects targets by range (+2 studs tolerance for players) and arc, checks line of sight against map and gym walls, then applies damage through `Damage.apply`. Health lives on the server and is mirrored into `Humanoid.Health`; the default Health script is removed so regeneration is only out of combat (2%/s after 5 s) and at base (10%/s). Spawn protection is the SpawnLocation ForceField.
- **Dodge:** the client moves itself with a short `LinearVelocity` (the client owns its character's physics); the server grants invulnerability starting half a ping before the request arrived. Monster area attacks resolve 0.1 s after impact so a dodge sent just before impact still counts.
- **NPCs are data rows** (`NpcService`): no Humanoid or physics on the server; 10 Hz tick and snapshots; clients render pooled-style local models with 100 ms interpolation (`NpcRenderController`). Kinds: dummy (heals after 3 s, not pushed by knockback), weak (40 HP, 4 damage every 1.5 s; softened from 5 every 1.2 s after a 3-pack killed a player in about 8 s), slammer (400 HP, 1 s telegraph, 14-stud slam for 35, 1.5 s recover), bot (Knight stats, team, uses the same `meleeSwing` path as players).
- **Instant feel:** the swing animation (procedural shoulder motion; no animation assets yet) and swing sound start on input; the client predicts its own hits with the same `Melee` rules for hit-stop, flash, hit sound and a light shake; damage numbers come from the server (pooled, no per-hit instance creation). Feedback lives in `src/client/Feedback.luau`.
- **Input:** `ContextActionService` actions: Attack (left mouse, R2, X; on-screen button on touch), Dodge (Q, B; on-screen button on touch). Attacks aim where the camera looks and turn the character to match. Clicks on visible UI buttons are ignored.
- **Sounds (placeholders, ProSoundEffects via Roblox):** swing 9119710806, hit 9117971636, slam 9113524242 (`Config.combat.sounds`).
- **Dev tools:** the gym is a walled arena at z = 900 (off the map), built only when `Config.combat.gym.enabled` (off in production). Chat commands `/gym`, `/base`, `/dummy`, `/slammer`, `/pack [n]`, `/botfight [n]`, `/clearnpcs`, `/heal`. The tuning panel toggles with the backquote key (F7 is taken by Studio); values are replicated attributes on ReplicatedStorage.CombatTuning, so changes apply to server and clients at once. Time-to-kill arrives as a chat message; swing latency shows in the panel; NPC simulation cost shows in the debug overlay (`sim`).
- **Acceptance, cheating client:** 20 attack requests in 1 s at point blank dealt 59 damage (3 swings at the 0.5 s cooldown; the rate limiter also logged the flood); 10 requests from 30 studs and 3 requests facing away dealt nothing.
- **Acceptance, 200 ms latency** (`settings().Network` 100 ms each way, restored to 0 afterwards): all 5 attacks on the dummy hit; server confirmations arrived about 235 ms after each request (one round trip plus a frame) while the swing itself started locally at once.
- **Acceptance, swing latency:** input to the first animated swing frame averaged 0.7 ms (max 0.8 ms, 5 samples), plus at most one 16.7 ms frame to display, measured on the development PC (stronger than the mid-range reference).
- **Acceptance, weak enemies:** three kills, each 2 hits, about 0.55 s from first hit.
- **Acceptance, slam dodge:** standing still under the slam took 35 damage after a visible 1.1 s telegraph. With the dodge request sent 0.8 s into the telegraph, no damage (twice); sent 0.4 s in, the invulnerability had ended and the full 35 landed (twice). In normal play a dodge also moves the player 14 studs, out of the 14-stud slam circle.
- **Acceptance, two clients:** not yet run (MCP tooling drives one client). Health and deaths are decided only on the server and replicated, so clients cannot disagree on outcomes by design; confirm with Studio's multi-client test (Test tab, Clients and Servers, 2 players) during the fun gate session.
- **Performance gate:** `/botfight 20` (40 bots) for 25 s: NPC simulation (AI, melee through the damage pipeline, snapshots) averaged 0.035 ms per frame, max 0.075 ms; server held 60 Hz (worst frame 19.6 ms); 105 defeats; server send about 3.8 KB/s. Measured on the development PC.
- **Fun gate access (open):** the gym and its commands only exist in Studio and for the owner, and live servers count as production. For outside playtesters on the main place, a playtest mode is needed (see the hand-off question to the owner).
- **Fun gate rounds:** none yet.
- **Fun gate deferred (owner decision, 2026-11-22):** Phase 4 starts before the fun gate runs. Phase 3 stays In Progress until the gate passes; if it later fails, combat is retuned (or reconsidered) before further phase work builds on it.

---

## Phase 4: UI foundation and HUD v1

**Status:** Complete

**Goal:** A design system and UI framework that every later phase builds on, plus the first real HUD. The target is a clean, modern look comparable to top current Roblox games.

**Tasks**

- [x] Choose the UI framework (Fusion or React-lua) and record the decision.
- [x] Define design tokens: colour palette (neutral dark surfaces, one accent per team, semantic colours for health, danger, rarity), type scale, spacing scale, corner radii, stroke, elevation, motion durations and easing.
- [x] Build core components: button, icon button, panel, modal, tab bar, list, card, progress bar, tooltip, toast, badge, cooldown ring.
- [x] Responsive layout for desktop: scale from 1366x768 to 4K and ultrawide, respect the Roblox top bar. Keep layouts adaptable so touch, tablet and console layouts can be added in the Phase 13B mobile pass.
- [x] Full keyboard navigation for every component (gamepad in the Phase 13B mobile and console pass).
- [x] Motion: spring-based transitions, press feedback, number roll-ups; a reduced-motion setting.
- [x] HUD v1: health bar, level badge, ability buttons with cooldowns, team score strip, round timer, kill feed, respawn screen.
- [x] World-space UI: name plates, health bars over players, damage numbers, all pooled.
- [x] Minimap v1: lanes, bases, teammates.
- [x] Settings screen shell: effects quality (the game's own effect tiers; games cannot change Roblox's graphics quality level), audio sliders, control options, reduced motion.
- [x] Component gallery: a dev-only screen in the main place for visual review of every component in every state.

**Acceptance tests**

- Every component is usable by mouse and keyboard.
- The HUD is readable and unobstructed at 1366x768 and at 4K.
- No UI element overlaps the Roblox top bar or other system UI.

**Performance gate:** HUD costs under 1 ms per frame on the low-end PC; no per-frame instance creation.

**Implementation notes**

- **Framework: Fusion 0.3** (`elttob/fusion@0.3.0` via Wally) rather than React-lua (`roblox/react` 17.3). Fusion is small, written for Luau, and has springs and tweens built in (the motion task); React-lua would add a large dependency tree with weaker strict typing. Strict typing works with a few casts: string-literal unions, `ForValues` inner scopes, and children lists passed through props (typed `{ any }`).
- **Package types:** Wally link files only `return require(...)`, so luau-lsp could not see Fusion\x27s exported types. `scripts/package-types.luau` (run by `make packages` and `make setup`) rewrites each link file to re-export the package\x27s `export type` declarations. This replaces the `wally-package-types` tool, which was not installed because adding a new third-party binary needs the owner\x27s approval.
- **Rojo:** the optional `Packages` path is only picked up when Rojo starts; after the first `wally install` the Rojo task was restarted and the Studio plugin reconnected.
- **Structure:** `src/client/UI/` holds `Theme` (tokens: colours with one accent per team, semantic and rarity colours, type scale, spacing, radii, stroke, elevation, motion), `UiState` (root Fusion scope, session settings, screen scale), `Motion` (springs that settle instantly with reduced motion), `Layout`, `Components/` (Button, IconButton, Panel, Text, Modal, TabBar, List, Card, ProgressBar, Tooltip, Toast, Badge, CooldownRing) and `Screens/` (Hud, Minimap, SettingsScreen, Gallery). `UiController` mounts them and keeps `HudState` current; `NameplateController` draws world-space plates. The Phase 2 placeholder RoundHud and the Phase 3 placeholder HP bar and kill feed were removed.
- **Responsive layout:** designed in points at 1600 x 900; each screen\x27s root frame gets a `UIScale` of min(width / 1600, height / 900) clamped to 0.8 to 2.4, and is sized so it fills the core UI safe area after scaling (`ScreenInsets = CoreUISafeInsets`, so nothing sits under the Roblox top bar). At both 1366 x 768 (scale 0.85) and 3840 x 2160 (scale 2.4) the layout is identical in points.
- **Keyboard and gamepad:** every interactive control is `Selectable`; opening a modal selects its first control, arrows move, Enter (or A) activates, Backspace (or B) or the close button closes. Escape is reserved by Roblox for its system menu, so it cannot close game dialogs. P toggles settings. The debug overlay is not a navigation target.
- **Motion:** springs drive button colour and press scale, modal fade and scale, tab underline, progress fills and the team kill roll-up; the reduced-motion setting makes them instant and turns off camera shake.
- **HUD v1:** team strip (name, members, round kills with roll-up, strength) with the round timer between the teams; result and new-teams banner (also the shutdown message); minimap with lanes, bases and teammates; kill feed (your kills, deaths and assists highlighted); ability buttons with cooldown rings and key badges (clickable, same functions as keys); level badge and health bar; settings button; respawn screen with killer name and countdown; toasts. Team kill counts are a `Kills` attribute per team, reset on `roundReset`; class level is a `ClassLevel` player attribute.
- **Settings shell:** effects quality (Low turns off shake and hit flash; it controls the game\x27s own effects, since games cannot change Roblox\x27s graphics level), master, effects and music volume (effects play through an SFX SoundGroup), aim attacks with camera, reduced motion. Kept for the session until Phase 9 saves them.
- **World-space UI:** one name plate per other player (name in team colour, level, health bar), parented to the local PlayerGui and moved onto each new character, with Roblox\x27s default name and health display turned off. Damage numbers are the pooled ones from Phase 3. Only one real client was available, so plates were not seen on screen (verify in the Phase 3 multi-client session).
- **Component gallery:** `/gallery` (dev only) shows every component and state, including an animated cooldown ring and toast triggers.
- **No per-frame instance creation:** HUD values update at 20 Hz and only when changed; the minimap uses a fixed pool of 24 dot frames and only pushes new positions when a dot moves more than half a stud. Kill feed lines and toasts are created per event, not per frame.
- **Bugs found in Studio and fixed:** the cooldown ring rotated the wrong half (fixed and checked in the gallery); a `UIStroke` on text buttons outlined the text instead of the border (`ApplyStrokeMode.Border`); the first modal control could not take selection while the modal was still invisible during its fade-in.
- **Acceptance, mouse and keyboard:** settings opened with P, arrows moved between tabs, Enter switched to the Audio page, and the close button and Backspace close it; attacks and dodges work from keys and from the ability buttons.
- **Acceptance, resolutions:** with Device Simulator custom desktop devices at 1366 x 768 and 3840 x 2160, an automated check found nothing off screen, and screenshots show the HUD readable and unobstructed at both (simulator reset and custom devices removed afterwards).
- **Acceptance, system UI:** all screens use the core UI safe area; nothing overlaps the top bar in any screenshot.
- **Performance gate:** HUD update cost on the development PC was 0.018 ms per frame idle and 0.08 ms in a 18-NPC fight. Approximated low-end PC (Studio limited to 2 CPU cores and rendering quality level 1, both restored afterwards): 0.062 ms average and 0.138 ms worst per frame during the same fight, FPS at least 59. Fusion\x27s own spring animation steps run outside this measurement; they animate only while values change.

---

## Phase 5: Minion system and load harness

**Status:** Complete

**Goal:** Waves of minions marching and fighting down all three lanes at full scale, proven by an automated load test. This is the highest-risk system for performance.

**Tasks**

- [x] Minion data model: struct-of-arrays storage with free-list reuse.
- [x] Movement along the lane spline as a scalar lane progress plus lateral offset; no pathfinding.
- [x] Wave spawner per lane per team on a timer, with wave composition in config.
- [x] Targeting through the spatial grid: nearest enemy minion, then player, then guardian.
- [x] Minion combat: melee and ranged variants, attack timers, damage through the shared pipeline.
- [x] Player-versus-minion hits resolved against the data arrays.
- [x] Proximity credit for nearby players (no last-hit requirement): emit credit events now; XP is applied from Phase 9 and gold from Phase 12.
- [x] Snapshot replication: packed buffers, delta encoded, 10 Hz, filtered by interest area, chunked by interest cell with an entity cap per message so every unreliable message stays under 900 bytes (the engine drops messages over 1000 bytes).
- [x] Client renderer: pooled models, interpolation, local animation, local hit and death effects, level-of-detail by distance (full model, simplified model, hidden with minimap dot).
- [x] Minimap: minion wave indicators per lane.
- [x] Bot load harness: N server-side bot entities (see section 2) that move down lanes, attack, dodge, and die through the same code paths as players, for repeatable tests.
- [x] Automated performance report: server frame time, per-system time, bytes per client, and client frame time measured with several real clients (Studio multi-client test) on the reference PCs (low-end approximated until Phase 15).
- [x] Evaluate moving the minion tick to Parallel Luau if the single-thread budget is exceeded.

**Acceptance tests**

- Two opposing waves meet mid-lane, fight, and the survivors continue.
- A player can cut through a wave; minions die in one to three hits.
- Minions seen by two clients are in the same place within a small tolerance.

**Performance gate:** 300 minions plus 40 bots: server simulation under 5 ms per frame, under 50 KB/s per client, 30 frames per second on the low-end PC. From here on, this test is rerun at the end of every phase.

**Implementation notes**

- **Pure modules (Lune tested, 12 new tests, 126 in total):** `Shared.Combat.SpatialGrid` (uniform grid, 16-stud cells in combat and 32 for interest; O(1) moves and swap-remove), `MinionCodec` (10 bytes per minion including kind and team, so clients need no spawn events; `quantize` for change detection), `Minions` (wave plan and scale, formation offsets, direction of travel, target priority, combatant ID mapping).
- **Spatial grid in combat:** `CombatService` keeps every combatant in the grid (refreshed at 20 Hz with position history). Melee swings, area hits, nearest-hostile searches and minion targeting query nearby cells instead of scanning every combatant; this also speeds up the Phase 3 gym NPCs and bots.
- **Minion data model:** `MinionService` keeps lane, distance along the lane, lateral offset, position, facing, state, target, timers and knockback in parallel arrays indexed by slot, with a free list. Each slot also owns one `CombatService` entry created the first time the slot is used and reused for every later minion in it (its position function reads the arrays), so minion damage goes through the shared pipeline and players hit minions through the normal melee path. This is a deliberate hybrid: simulation state is struct-of-arrays, combat state is one reusable record per slot.
- **Waves:** every 30 s per lane per team during Active (first wave 5 s in), 3 melee then 3 ranged, spread 8 studs across the lane; cleared on round reset. Minions walk their lane by distance and offset, engage within 16 studs (nearest enemy minion first, then players and bots; guardians from Phase 6), chase, fight, then rejoin the lane from where they stand. A minion that reaches the enemy base is removed for now (Phase 6 makes it attack the Titan). Melee: 40 HP, 6 damage every 1.2 s; ranged: 30 HP, 5 damage every 1.6 s at 14 studs (instant hit, no projectile visual yet).
- **Kill feed and team score:** minion defeats are not announced to the kill feed and do not count towards team kills; hits between two minions send no hit event (health shows through snapshots).
- **Proximity credit:** when a minion dies, every hostile player within 40 studs fires `CombatService.credited` (XP from Phase 9, gold from Phase 12); a `MinionCredits` player attribute counts them for testing.
- **Replication:** per client, minions within 300 studs of their character, at 10 Hz; only minions whose quantised position, facing, health or state changed since last sent to that client, plus every minion in range once a second (keyframe). Chunks are grouped by grid cell and capped under 900 bytes. Dying minions are sent with a dead state for a second, then released.
- **Client renderer:** `MinionRenderController` pools models per kind, team and level of detail (no per-frame creation once warm), interpolates 100 ms behind the server clock, bobs fighting minions, shows a health bar on damaged minions up close, shrinks and fades the dying, and releases minions not heard from for 2.5 s. Level of detail by camera distance: full model within 120 studs, a single block to 250, hidden beyond.
- **Minimap:** a 1 Hz `WaveSummary` gives each lane and team's minion count and front; the minimap shows a diamond per wave front sized by count.
- **Load harness:** lane bots (`NpcService` kind `lanebot`): Knight stats, push their lane, fight with the player melee path (`CombatService.meleeSwing`), dodge every few seconds through the player dodge path (`CombatService.dodge`), and respawn at their lane start. `/loadtest [bots] [scale]` spawns them and forces scaled waves every 12 s; `/perf` reports minion, NPC and combatant counts, per-frame minion tick (average and worst), snapshot and NPC cost, server send, and minion snapshot bytes per client. Also `/waves`, `/wave`, `/wavescale`, `/waveinterval`, `/clearminions`.
- **Spike fix:** the first version ticked every minion on one frame ten times a second (about 3.5 ms at 720 minions, 7.7 ms on two cores); minions are now ticked in six groups, one per server frame, each integrating its own elapsed time, so the cost is flat.
- **Acceptance, waves meet:** middle-lane waves met at the centre and fought (screenshot); over the next 20 s the fronts overlapped and swayed, and the side with survivors advanced (team 2 front 0.42 to 0.48) while later waves arrived.
- **Acceptance, cutting through a wave:** five enemy minions in a row each died in exactly 2 Knight hits (3.6 s total).
- **Acceptance, two clients agree:** not run with two real clients (MCP drives one). Both clients interpolate the same server-timestamped samples at server time minus 100 ms, so they differ only by clock-sync error (milliseconds, about 0.1 stud at walking speed) and 1/16-stud quantisation. Check visually in the multi-client session alongside the Phase 3 and 4 checks.
- **Scaling (development PC, 40 lane bots):** minion tick per frame 0.10 ms at 72 minions, 0.18 at 216, 0.25 at 288, 0.31 ms (worst 0.57) at 360.
- **Performance gate (approximated low-end PC: Studio limited to 2 cores and graphics level 1, restored afterwards; server and client share those cores in Studio):** 413 minions and 37 lane bots: minion tick 0.60 ms per frame (worst 0.99), snapshots 0.03 ms, NPCs 0.04 ms; server held 60 Hz (worst frame 20 ms); minion snapshots to the client 10.5 KB/s; client 60 FPS (95th percentile 18 ms, worst 19.4 ms) drawing 104 models. An earlier run with 932 minions also held 60 FPS on the client. Parallel Luau is not needed at this headroom.
- **Not measured:** client frame time with several real clients at once (MCP drives one client).
- **Studio note:** during the 720-minion run the game view stopped rendering because it was not the visible Studio tab (the game kept running; a screenshot call hung until the view was shown again). Keep the game view visible for render measurements.

---

## Phase 6: Guardians and Titan (first full round)

**Status:** Complete

**Goal:** Lanes are defended, bases can fall, and a complete round can be played from start to reset.

**Tasks**

- [x] Replace the Phase 3 throwaway test monster with the full monster behaviour framework, carrying over the tuning values that passed the fun gate.
- [x] Monster behaviour framework: state machine with idle, telegraph, attack, recover, stagger, dead.
- [x] Attack primitives, part one: ground slam (circle), sweep (cone), projectile.
- [x] Telegraph rendering: ground decals with fill timing, readable at a glance in a crowded fight.
- [x] Guardian definition: stationary, large health pool, two or three attacks, targets minions before players unless a player attacks a teammate nearby.
- [x] Lane gating: inner guardian is invulnerable until the outer guardian in that lane is dead; Titan is invulnerable until at least one inner guardian is dead.
- [x] Titan definition: three phases with changing attacks, defender buffs while it is under attack (faster respawn near base).
- [x] Stagger window: damage during recovery fills a stagger bar that opens a bonus-damage window.
- [x] Knockback and ragdoll on heavy hits, client-simulated with server-validated end positions.
- [x] Guardian sleep: no logic ticks when no enemy is in range.
- [x] Round end on Titan death, wired into the Phase 2 state machine.
- [x] HUD: guardian and Titan health on the score strip, boss bar when in range, lane status on minimap.
- [x] Round summary screen v1: winner, duration, personal stats.

**Acceptance tests**

- A full round is played from start to Titan death to reset with bots and with human testers.
- Every telegraphed attack can be avoided by a player who reacts to the telegraph.
- A guardian cannot be damaged out of order.

**Performance gate:** Phase 5 load test plus all 14 large monsters active stays within budget.

**Implementation notes**

- **Pure modules (Lune tested, 16 new tests, 142 in total):** `Shared.Combat.MonsterBrain` (state machine idle, telegraph, attack, recover, stagger, dead; attack choice by range band, cooldown, phase and weight; phase tempo; stagger bar), `Shared.Combat.Shapes` (circle, cone, segment tests, fans, worst-case escape distance), `Shared.Combat.Structures` (structure list from map markers, lane gating, guardian target priority). A spec checks every configured attack: its telegraph leaves time to react, attacks never come faster than the dodge cooldown, and guardian and Titan targeted slams and bolts can be walked out of.
- **Definitions are data:** `Config.monsters` holds slammer, outerGuardian, innerGuardian and titan (stats, attacks with primitive, range band, telegraph, recovery, cooldown, shape sizes, knockback, heavy flag, minimum phase, weight; stagger; phases and tempo). The Phase 3 slammer is now a definition with its fun-gate tuning (35 damage, 14-stud slam, 1 s telegraph, 1.5 s recovery), and the throwaway NPC code is gone.
- **MonsterService** drives every monster as an NPC row (`NpcService.spawnCustom`, a custom tick per row). When an attack is chosen, its aim is fixed and the telegraph is broadcast to players within 400 studs (`MonsterAction`). Impact lands exactly at the telegraph's end (scheduled, not on the 10 Hz tick). Circles and cones resolve 0.1 s later through `CombatService.shapeHit`, with invulnerability judged at impact. Bolts are simulated every frame with swept segment tests; dodged bolts fly on, and bolts from a dead monster fizzle.
- **Stagger:** damage during recovery fills the bar (replicated in a new snapshot byte); full staggers the monster for 2.5 to 3.5 s with x1.5 damage taken (passed as a damage-pipeline modifier). Verified in the gym: eight bots on the slammer staggered it on its first recovery.
- **Heavy hits:** knock players down on their own client (0.7 s, thrown and tipped; no attacks or dodges while down). The server remembers the start position and, after the knockdown, pulls the character back if it ended farther than the push plus walking allows (`CombatService` knockback checks).
- **Sleep:** a monster with no hostile within its wake range runs only a 2 Hz check and sleeps again after 3 s with nothing to do. Normal play showed 1 of 14 structures awake.
- **Structures:**
  - An outer and inner guardian per lane per team plus a Titan per team, spawned at the map markers, persistent across `/clearnpcs`, and respawned on round reset.
  - Lane gating sets `gated` (skipped as a target) and `protected` (hits miss). Everything is also locked outside the Active phase, so dev bots fighting through Intermission can't decide the next round.
  - Guardians prefer provokers (hostiles who hurt their team's players or bots within 36 studs, for 4 s), then minions, then the nearest. This is unit tested only; seeing it live needs a second player.
  - Minions and lane bots that reach the end of their lane march on the enemy Titan. While a Titan takes damage, its team respawns twice as fast.
  - A Titan's death calls `RoundService.finish`. Health and alerts replicate as attributes on `ReplicatedStorage.Structures`.
  - Greybox markers for guardians and the Titan were removed.
- **NPC separation:** rows that cannot be pushed (monsters, the dummy) take no part, so bots pass through guardians as players do. Before this, lane bots piled up on their own guardians.
- **Client:**
  - `NpcRenderController` draws monsters from their definitions (body, head, glowing eyes, arms, team band, Titan crown), shows state (wind-up lean and raised arms with red eyes, swing, stagger slump) and sinks defeated monsters into the ground.
  - `MonsterFxController` draws telegraphs as a faint outline of the full area plus a bright fill growing from the origin until impact: circles, cones built from wedge triangles, and lines and fans for bolts. Hostile shapes are red-orange; your own guardians' shapes are faint blue. It also draws impact flashes, locally simulated bolts, phase toasts and stagger toasts.
  - `StructureController` reads the structure attributes, draws ruins and toasts on destruction.
- **HUD:** guardian pips (outer and inner per lane: bright, faded while locked, dark when destroyed) and a Titan health bar under each team block, outlined red while that Titan is under attack. A boss bar for the nearest large monster within 60 studs shows its name, phase, health, stagger bar and LOCKED or STAGGERED. Minimap lane status uses the same colours. The kill feed names monsters with their team ("Blue Outer Guardian").
- **Round summary v1:** `RoundStatsService` tracks kills, deaths, assists, damage, structure damage, minion credit and structures destroyed per player, and sends `RoundSummary` at Ending. The screen shows victory or defeat, round and duration, the stats, team kills and structures destroyed, and the MVP, then closes itself when the next round starts.
- **Acceptance, full round with bots:** structures at 10% health (`/structurehp 0.1`), 18 Red lane bots plus waves. They destroyed all six Blue guardians in lane order and took the Titan from 100% to 40% (it fought back through its phases). I landed the last 400 damage with `/hitstructure` to finish it. The round then went to Ending with Red the winner, the summary appeared, and on Starting round 2 every structure was back at full health with the summary closed. Not yet run with human testers.
- **Acceptance, telegraphs can be avoided:** `/avoidtest` runs a reactor bot against a monster in the gym. The bot moves between three distances and, 0.25 s after a telegraph covers it, walks straight out of the shape or dodges through the impact.
  - Outer guardian, walking: 27 of 27 avoided.
  - Outer guardian, dodging: 27 of 27 avoided.
  - Titan in phase 3 (30% health), dodging: 48 of 48 avoided.
  - Control run, standing still: 12 hits from 14 telegraphs.
  - Walking alone does not beat the Titan's wide sweep, three-bolt volley or 22-stud quake; this is by design and recorded in the decision log.
  - Guardian sweep telegraphs were lengthened from 0.8 s to 0.9 s so their worst-case escape (about 9 studs) is walkable after a reaction.
  - Not yet confirmed by human players.
- **Acceptance, no damage out of order:** `/hitstructure` showed an inner guardian and the Titan missing ("protected") while the lane's outer guardian lived. Killing the top outer guardian opened only the top inner guardian; the middle one stayed locked. Killing the top inner guardian opened the Titan.
- **Performance gate:** Phase 5 load test plus `/siege` (a stationary enemy target next to every structure, so all 14 stay awake and attack nonstop).
  - Development PC: 720 minions and 54 NPCs. Minion tick 0.89 ms per frame (worst 1.24), NPCs and monsters 0.10 ms, bolts 0.011 ms; minion snapshots 24 KB/s.
  - Approximated low-end PC (2 cores, graphics level 1, restored afterwards): 576 minions. Minion tick 1.04 ms (worst 1.43), NPCs and monsters 0.17 ms, bolts 0.013 ms, about 1.25 ms in all. Server held 60 Hz; client held 60 FPS (worst frame 18.7 ms); minion snapshots 20 KB/s.
- **Dev commands:** `/monster [id]`, `/avoidtest id [walk|dodge|stand] [seconds] [health%]`, `/structures`, `/hitstructure key [n]`, `/killstructure key`, `/structurehp [x]`, `/resetstructures`, `/siege`, `/lanebots team [n]`.
- **Carried forward:**
  - Human-tester round and avoidance checks, and provocation seen live, go into the multi-client session.
  - Kills by minions still count towards team kills (as in Phase 5).
  - Ragdoll and telegraph art are placeholders (Phase 13).

---

## Phase 7: Jungle camps and monster kit

**Status:** Complete

**Goal:** Jungle fights that are fun in their own right, built from a reusable kit.

**Tasks**

- [x] Attack primitives, part two: charge, summon, grab-and-throw, burrow.
- [x] Monster definition format: stats, two primitives, one signature mechanic, model and animation references, egg type.
- [x] Three monster types, each with a distinct signature (examples: takes damage only from behind; splits into two on death; burrows and resurfaces under a player).
- [x] Camp controller: spawn group, leash range, reset when players leave, respawn timer.
- [x] Camp difficulty tiers by distance from base, with the centre camps the hardest.
- [x] Egg drop on clear (pickup only; carrying arrives in Phase 8).
- [x] Group scaling: camp health scales mildly with the number of attackers so groups are faster but not trivial.
- [x] Camp sleep when no player is near.
- [x] Minimap: camp alive and respawn indicators.
- [x] Authoring tool: grow the Phase 3 combat gym (dev-only, in the main place) so it can spawn any monster definition for isolated tuning.

**Acceptance tests**

- Each monster type requires a different approach, confirmed by play-testers.
- A solo player using the stubbed stat function at a mid-range class level (Phase 9 does not exist yet) clears an outer camp in about 30 seconds.
- A new monster type can be added with a definition file and assets, without new code.

**Performance gate:** All 12 camps awake at once plus the Phase 6 gate stays within budget.

**Implementation notes**

- **Definition format:** `src/shared/Monsters/Types.luau` defines a monster type:
  - stats;
  - attacks built from seven primitives;
  - an optional signature (`armoredFront`, `splits`, `burrower`) with its data;
  - `egg` type;
  - `model` and `animations` asset references (nil until Phase 13);
  - a placeholder `look` (blocky, blob, shell, worm with a colour).

  Each type is one file in `src/shared/Monsters/`, listed in its `init.luau`; `Config.monsters` points at that index. Phase 6's guardians, Titan and slammer moved there unchanged.
- **Attack primitives, part two** (MonsterService):
  - charge: a line telegraph as wide as the monster, ending inside its leash; then the monster dashes along it at the attack speed, hitting each body once. It runs through the same per-frame swept-segment loop as bolts, with the monster carried along.
  - summon: calls `count` monsters of a type, at most `max` alive per summoner; they join the summoner's camp.
  - grab: a small circle at the target; the body nearest its centre is hit and thrown away from the monster (heavy).
  - burrow: the monster goes underground at once (hidden, gated, invulnerable; new snapshot state `hidden`), and its eruption circle is drawn where the target stood, inside the leash. At impact it surfaces there with a heavy circle hit.
- **Three jungle types**, each with two primitives and a signature:
  - Shellback: bite (sweep) and charge. Armoured front: hits from its front half do no damage and show "Blocked". It only turns while idle, so its charge carries it past you with its back open during a 2 s recovery.
  - Splitter: self slam and calling splitlings. Splits into two splitlings on death; the camp is cleared only when every piece is dead.
  - Burrower: burrow and grab. Underground and untouchable for much of the fight; hit it after it surfaces.
- **Camps:**
  - `Shared.Combat.Camps` (pure, 6 new tests, 148 in total) gives 12 camps from the map markers. Tier by distance from the centre line: tier 3 within 180 studs, tier 2 within 350, tier 1 beyond.
  - Each quadrant has one of each type, so every type appears at every tier.
  - Tiers scale health x1, x1.4, x1.9 and damage x1, x1.15, x1.3; they respawn after 60, 75 and 90 s and drop common, rare and epic eggs.
  - `CampService` spawns each camp's monster, tracks members (summons and split pieces join through `MonsterService.spawned`) and clears on the last death through `MonsterService.died`. On clear it drops the egg, publishes the respawn time as an attribute on `ReplicatedStorage.Camps`, and respawns on the timer.
  - Leash: camp monsters walk home past 45 studs.
  - Reset: a damaged camp with no player or bot within 55 studs for 6 s respawns fresh.
  - Group scaling: health grows by 15% per distinct attacker in the last 6 s beyond the first, up to x1.6, and never shrinks mid-fight. This is unit tested; seeing it live needs more than one attacker.
  - Sleep: camp monsters use monster sleep; the camp itself ticks once a second.
- **Eggs (pickup only):** `EggService` drops a glowing egg (colour by rarity) with a hold-to-pick-up prompt. Pickup is validated on the server (alive, within 12 studs) and counted in the `EggsCollected` attribute. Eggs disappear after 90 s and are cleared on round reset. Phase 8 adds carrying.
- **Client:**
  - Placeholder looks per type: translucent blob with a core, shell on a low body, worm with a glowing maw.
  - Burrowed monsters sink out of sight.
  - Charge telegraphs reuse the line shape.
  - Zero-damage hits read "Blocked".
  - The minimap shows each camp as a purple dot sized by tier, or grey with a seconds countdown while respawning.
  - Jungle kills stay out of the kill feed.
- **Acceptance, solo outer camp in about 30 s:** `/cleartest index [level]` runs a duelist bot with stubbed level-20 Knight stats (x1.12). It uses the player melee path, stands behind Shellbacks and dodges every telegraph that covers it. Outer camps, from the first hit:
  - Splitter: 29.8 s.
  - Burrower: 25.1 s.
  - Shellback: 69.4 s at first. After cutting its health from 600 to 280 and lengthening its post-charge recovery from 1.8 to 2 s, it took 27.8 s.
  - The duelist took no damage, so a human will be slower; recheck in the fun session.
- **Acceptance, a new type needs only a definition file:** the three jungle types and the splitling were added as files plus index lines. Spawning, camps, telegraphs, models and minimap needed no type-specific code.
- **Acceptance, each type needs a different approach:** by design (flank the Shellback, thin the splitlings, keep moving against the Burrower). Needs human playtesters (fun session).
- **Also verified:**
  - All 12 camps spawned with the tier scaling.
  - Clearing dropped an egg and the camp respawned on its timer.
  - Holding E on the egg picked it up.
  - Camp 10, left damaged (204/380), reset to full once nobody was near.
- **Performance gate (approximated low-end PC, 2 cores, graphics level 1, restored afterwards):** Phase 5 load test plus `/siege`, now with a target at every camp too, so 38 monsters stayed awake (14 structures, 12 camps, summons and split pieces).
  - Load: 684 minions and 40 lane bots.
  - Simulation per frame: minion tick 1.62 ms (worst 2.44), NPCs and monsters 0.26 ms, bolts and charges 0.017 ms, about 2.0 ms in all.
  - Server held 60 Hz; client held 60 FPS (worst frame 19.2 ms); minion snapshots 20 KB/s.
- **Fixes along the way:**
  - `/loadtest` cleared camp monsters, which left camps stuck; camp monsters are now persistent like structures.
  - Dev chat replies were capped at 500 characters; the limit is now 2000.
- **Dev commands:** `/camps`, `/gocamp index`, `/cleartest index [level] [timeout]`, `/resetcamps`; `/monster id` spawns any type in the gym (the authoring tool).

---

## Phase 8: Eggs and hatcheries

**Status:** Complete

**Goal:** The full egg loop inside a round: carry, incubate, raid, and unleash.

**Tasks**

- [x] Egg entity: type, rarity, owner, state (dropped, carried, incubating, hatched).
- [x] Pickup and carry: carrier is slowed, cannot dodge, is marked on the enemy minimap when seen, and drops the egg on death.
- [x] Dropped egg rules: who can pick it up, despawn timer.
- [x] Hatchery: fixed number of slots, deposit interaction, incubation timer by rarity, visible glowing eggs in slots.
- [x] Raiding: an enemy player inside the hatchery can channel to take an incubating egg, then must carry it home to restart incubation.
- [x] Hatchery access rule: raidable only after that lane's outer guardian is dead (decide and record; alternative is always raidable but guarded).
- [x] Hatch prompt for the owner with the three choices; claim and feed are stubbed until Phase 9.
- [x] Unleash: spawns the monster as an allied lane unit at that hatchery, using its camp definition scaled for lane use.
- [x] Offline or absent owner: auto-unleash after a timeout.
- [x] Round reset clears all eggs.
- [x] HUD: carry indicator, hatchery slot display, incubation timers, hatch prompt, raid alert for the defending team.
- [x] Anti-abuse: movement speed validation on carriers, interaction range and rate checks.

**Acceptance tests**

- An egg goes from camp to hatchery to unleashed lane monster.
- A raider steals an incubating egg and incubates it at their own hatchery.
- Killing a carrier drops the egg and either team can recover it according to the rules.

**Performance gate:** 20 unleashed monsters on lanes plus the Phase 7 gate stays within budget.

**Implementation notes**

- **Rules (pure, `Shared.Eggs`, 7 new tests, 155 in total):** incubation by rarity (60, 120, 180, 240 s), unleash scale by rarity (x1, 1.3, 1.6, 2), who can pick up (dropped eggs only, anyone), deposit (own team's hatchery with a free slot), raid (enemy, empty hands, an incubating egg, outer guardian dead), raid pick (the egg closest to hatching), and the carrier movement limit. Numbers live in `Config.eggs`.
- **Eggs (`EggService`):** each egg is one server part, tagged `Egg` for clients, with attributes for state, kind, rarity, team, carrier, hatchery and end time.
  - States: dropped, carried, incubating, hatched.
  - Pickup: a hold prompt, checked on the server (alive, within 12 studs, rate limit).
  - Carrying: the egg is welded to the carrier's back. Carriers walk at 70% (a `CharacterService.speedScale` hook) and cannot dodge (a `CombatService.canDodge` hook, and the client refuses too).
  - A carrier who dies or leaves drops the egg where they were. Dropped eggs vanish after 90 s, and every egg is cleared on round reset.
- **Hatcheries:**
  - One per lane per team at the map markers (the greybox pads were removed): a pad with a glowing core and four slots.
  - Deposit prompt for your own team; steal prompt (hold F for 3 s) for enemies. Each client shows a prompt only where it applies, and the server checks range, state, team, free slots and the rate limit.
  - The depositor owns the egg. Incubating eggs sit on the slots with a countdown label; hatchery labels show free slots, or raidable/guarded to enemies.
  - Raid alerts go to the defending team when the hold starts. A raid takes the egg closest to hatching, and the raider carries it home, where incubation starts over.
- **Hatching:**
  - The owner gets `HatchReady` and a dialog: claim as pet, feed to pet, or unleash on lane, with a 30 s countdown. Keyboard and gamepad navigation work (tested with arrows and Enter).
  - No choice in time, or an absent owner, unleashes it.
  - Claim and feed are recorded as `EggsClaimed` and `EggsFed` player attributes until Phase 9 adds pets (decision log).
- **Unleashed monsters (lane units):** the egg's monster definition spawns at the hatchery with the rarity scale and `lane` set. With nothing to fight it marches its lane, re-finding its place on the lane after a chase as minions do. It fights whatever is hostile in range and besieges the enemy Titan at the end. Lane units never sleep, ignore leash and are removed on round reset.
- **Carriers on the minimap:** teammates carrying an egg show as gold dots. Enemy carriers show as red dots while any teammate is within 150 studs.
- **HUD:** a carry pill above the abilities ("rare shellback egg · slowed, no dodge · take it to your hatchery"), toasts for picking up and for raids, world labels on eggs and hatcheries, and the hatch dialog.
- **Anti-abuse:** carriers are position-checked every 0.5 s against the slowed walk speed plus slack; a carrier who moves too far is put back. A carrier hit in the last 1.5 s is skipped so knockback is not punished. Verified: an 80-stud teleport while carrying was undone ("moved too fast while carrying an egg; put back").
- **Acceptance, camp to hatchery to lane:** a duelist cleared camp 10 (29.3 s) and it dropped a common Splitter egg. I picked it up (walk speed 16 to 11.2), walked to my team's bottom hatchery, deposited it (incubating, 1:00 countdown, 3 of 4 slots free) and finished incubation with `/hatchnow`. The hatch dialog appeared and I chose "Unleash on lane". The Splitter spawned at the hatchery and marched west along the bottom lane at its walk speed (275 to 227 on x in 6 s).
- **Acceptance, raid and re-incubate:** I deposited a rare Burrower egg at Red's bottom hatchery and destroyed Red's bottom outer guardian (the hatchery turned raidable). On Blue, I stole the egg with the 3 s hold, walked it to Blue's bottom hatchery and deposited it; incubation restarted there at the full 120 s.
- **Acceptance, carrier death:** carrying an epic Shellback egg next to an enemy guardian, I was killed; the egg dropped where I died in the dropped state, which anyone can pick up.
- **Performance gate (approximated low-end PC, 2 cores, graphics level 1, restored afterwards):** Phase 5 load test plus `/siege` plus `/unleash 20`.
  - Load: 576 minions, 145 NPCs, 79 monsters (58 awake).
  - Simulation per frame: minion tick 1.55 ms (worst 2.21), NPCs and monsters 0.28 ms, bolts and charges 0.026 ms, about 1.9 ms in all.
  - Server held 60 Hz; client held 60 FPS (worst frame 18.3 ms); server send 23 KB/s.
- **Carried forward:**
  - NPC snapshots go to every client unfiltered (about 14.5 KB/s at 145 NPCs). Add interest filtering like minions' if NPC counts grow (Phase 11 or 13B).
  - Seeing a raid alert and enemy carrier markers needs a second player (multi-client session).
- **Dev commands:** `/egg [kind] [rarity]`, `/eggs`, `/gohatchery key`, `/hatchnow key`, `/unleash [n]`. `/killstructure` now works on your own team's structures too.

---

## Phase 9: Persistence, levels, and pets

**Status:** Complete

**Goal:** Progress that carries across rounds and sessions.

**Tasks**

- [x] Profile schema v1: a per-class map of level and XP, last active class, pets (up to three, each with type, pet XP, cosmetic), active pet, gold, cosmetics owned, settings, statistics. Pets, pet XP, gold and cosmetics are account-wide.
- [x] Data store names namespaced by environment from `Config` (for example a `dev_` prefix in Studio), so Studio sessions in the main place never read or write live player data.
- [x] Session-locked load and save with retry, autosave, save on leave, and schema migration support.
- [x] Failure handling: if a profile cannot load, the player is told and is not allowed to play on an empty profile.
- [x] XP sources: minions, monsters, guardians, player kills and assists, objectives, round completion. All XP awards go to the active class (wired to the Phase 5 credit events).
- [x] Level curve and stat function per Appendix A, driven by the active class level; stats flatten, level number does not cap.
- [x] Account level: the sum of class levels, shown on the nameplate with the class level.
- [x] Unlocks split by level type: class level unlocks abilities and class milestone looks; account level unlocks the second and third pet slots and titles.
- [x] Catch-up XP: a class below the player's highest class level earns double XP (multiplier in Config) until it reaches that level, with a unit test covering below, at and crossing the threshold.
- [x] Claim: add hatched monster to the stable; if full, choose one to replace.
- [x] Feed: convert the hatched monster to pet XP on a chosen pet, with a bonus for matching type.
- [x] Pet stat curve per Appendix A.
- [x] Set `TeamService.powerOf` from each player's combat multiplier (active class level multiplier times active pet multiplier, Appendix A), and refresh team strength when a player levels, switches class, or switches pet.
- [x] Active pet in the world: follows the owner, auto-attacks, uses its signature move on a cooldown; simulated in the same data pipeline as minions.
- [x] Switching the active pet at base.
- [x] Unleash reward: level XP to the owner based on what the unleashed monster achieves.
- [x] UI: level-up moment, XP bar, pet stable screen, pet detail, hatch choice screen with comparison.
- [x] Data tooling: wipe and edit a test profile from developer commands.

**Acceptance tests**

- Progress survives leaving, rejoining, and a server shutdown.
- Two servers cannot load the same profile at once.
- A maxed test profile measures no more than about 1.5 times the combat power of a new profile.

**Performance gate:** 40 active pets plus the Phase 8 gate stays within budget.

**Implementation notes**

- **Pure modules (14 new tests, 169 in total):**
  - `Shared.Progression`:
    - XP curve: 100 + 25 (L - 1)^1.2 per level, never capped.
    - XP awards with catch-up, tested below, at and crossing the threshold.
    - Account level, pet slots (account level 1, 15 and 40), titles.
    - Pet multiplier: 1 + 0.2 x / (x + 2000).
    - Combat power, and feed XP with a x1.5 same-type bonus.
  - `Shared.Profile`: schema v1, migration step list, fill-in of missing fields, refusal of newer versions, pet add and replace.
  - `Shared.SessionLock`: claim, refresh and release on an injected atomic update, stale takeover, and saves refused once the lock is lost; with an in-memory store.
- **DataService:**
  - The store is named per environment (`dev_profiles_v1` in Studio, `test_` in test, unprefixed live).
  - Load on join retries with backoff. If the profile is still locked or failing, the player is kicked with a message, never given an empty profile, and players cannot spawn until loaded.
  - Saves: autosave every 60 s (refreshing the lock), save and release on leave, and save everyone on shutdown.
  - Without data store access in dev or test it falls back to an in-memory store with a warning; never in production.
- **ProgressionService:**
  - XP to the active class from every source: minion credit, camp monsters (shared by attackers), camp clears (by tier), structures (attacking team within 120 studs), kills and assists, egg deposits, raids and hatches, round win or loss, and damage dealt by your unleashed monsters.
  - Level-ups update max health and damage at once, and team strength via the new `TeamService.refresh`.
  - `TeamService.powerOf` and `CombatService.classLevelOf` now read profiles.
  - Player attributes feed the HUD and nameplates (class level, account level, title).
- **Pets:**
  - Claim and feed replace the Phase 8 stub; a claim with a full stable replaces the pet you pick.
  - `PetService` spawns the active pet as a monster at 45% size, with 30% of the type's damage times its pet multiplier. It follows its owner, fights hostiles within 22 studs of them, teleports back if left 60 studs behind, and is untargetable (decision log).
  - Switching the active pet is checked to be in your own base.
  - Fixed in testing: pets were held to a leash around their spawn point, and a Splitter pet's summon (range 25) kept it from closing in. Pets now ignore leash, never summon, and get a summon-free copy of their definition.
- **UI:**
  - XP bar under the health bar.
  - Level-up moment: a big "LEVEL n" banner, toast, flash and sound.
  - Nameplates show class level, account level and title.
  - Pet stable screen (K or the paw button): slots, pet XP, power bonus bar, make active.
  - The hatch dialog lists your pets for comparison, shows each pet's feed XP, and picks the pet to feed or replace.
  - Pets have no health bar and no boss bar.
- **Data tooling (dev):** `/profile`, `/wipeprofile`, `/setlevel n`, `/addxp n`, `/addpet kind [xp]`, `/maxprofile`, `/savenow`, `/locktest`, `/petdebug`, `/pets n`.
- **Acceptance, persistence:** with Studio API access on, I set Knight level 12 with 60 XP and a Shellback pet with 777 XP, then stopped the server. On the next start the profile loaded at once with everything intact, so the shutdown save wrote the profile and released the lock.
- **Acceptance, one server at a time:** `/locktest` (a second session loading the profile) was refused ("locked by" this server's session) on the real data store. Unit tests cover the release and stale-takeover cases.
- **Acceptance, 1.5x ceiling:** a maxed profile (level 500, pet XP 10,000,000) measures power 1.488. Health and damage both scale by power, and team strength uses it too (unit test: never above 1.5).
- **Also verified:**
  - 250 XP took a Knight from level 1 to 3 with 25 XP left over, and max health rose to 102.
  - Feeding a rare Splitter egg to a Splitter pet gave 600 pet XP (1500 to 2100, power x1.102), and the class got 70 XP for the deposit and hatch.
  - The pet damaged camp monsters without the owner attacking.
- **Performance gate (approximated low-end PC):** Phase 8 load plus `/pets 40`.
  - Load: 120 monsters (99 awake), 186 NPCs, 576 minions.
  - Simulation: about 1.6 ms per frame.
  - Server held 60 Hz; client held 60 FPS (worst frame 19.1 ms).
  - Server send: 32.5 KB/s before filtering NPC snapshots by distance, 21.9 KB/s after (development PC rerun).
- **Carried forward:** the unleash reward is XP from damage dealt; kill-based bonuses could come in Phase 11 balance.

---

## Phase 10: Classes

**Status:** Complete (fun gate still deferred from Phase 3)

**Goal:** Four distinct roles that make groups stronger than individuals.

**Tasks**

- [x] Ability framework: data-defined abilities with cooldown, cost, targeting shape, effects, and client prediction.
- [x] Status effect system: slow, stun, shield, heal over time, taunt, damage amplification, with stacking rules.
- [x] Knight: block or taunt, gap closer.
- [x] Hunter: ranged basic attack, weak-point bonus, trap or snare.
- [x] Mage: area damage, crowd control.
- [x] Healer: targeted heal, area heal or shield, a damage option so solo play is viable.
- [x] Targeting: mouse aim with generous hit shapes for all abilities (auto-aim assist for touch and gamepad in the Phase 13B mobile pass).
- [x] First-join class picker, defaulting to Knight.
- [x] Class station in each base's spawn area. Switching rules: switch at the class station or on the respawn screen, including mid-round; no switching in the field.
- [x] Ability unlocks follow class level: each class has its full core kit by class level 10.
- [x] Class-specific level milestone looks (stub visuals), driven by class level.
- [x] Healing and support credit: XP and assists for heals and shields.
- [x] UI: class picker, ability bar per class, status effect icons.
- [x] Balance pass using server-side bots of each class.

**Acceptance tests**

- A mixed group of four clears a centre camp measurably faster than four of the same class.
- A Healer earns comparable XP to a damage class over a full round.
- Every ability is usable without pixel-precise aiming.

**Performance gate:** 40 server-side bots using abilities at realistic rates plus the Phase 9 gate stays within budget.

**Implementation notes**

- **Data, not code.** Each class is one file in `src/shared/Classes` (format in `Types.luau`): stats, weapon, basic attack (left mouse), three abilities (keys 1, 2, 3; gamepad L1, Y, R1) and milestone looks. An ability is an aim (self, direction, point, ally), a shape (circle, cone, line), effect lists for enemies, allies and self, and optional dash, delay, trap and projectile speed. `Shared.Abilities` resolves aim and shapes (pure, tested); `AbilityService` applies effects. Players and class bots cast through the same `AbilityService.cast`.
- **Kits** (unlock levels 1, 4, 8; full kit by 8):
  - Knight (tank, 120 health, defence 25): Slash (the Phase 3 sword path, tuning panel included), Charge (dash, hit and slow), Rally (taunt monsters and minions, self shield), Shield Bash (cone, stun).
  - Hunter (85 health): Arrow (long line, +35% against monsters: weak points), Volley (cone), Snare Trap (armed trap that snares), Marked Shot (target takes +25% damage from everyone).
  - Mage (80 health): Arcane Bolt, Fireball (point, projectile), Frost Nova (slow around you), Arcane Prison (delayed area stun).
  - Healer (95 health): Smite (its damage option), Mend (ally heal plus heal over time), Sanctuary (area heal, and burns enemies), Barrier (area shield). Everything the Healer casts on allies also empowers them: +20% damage for 6 s.
- **Statuses** (`Shared.Combat.Status`, pure, tested): slow (strongest applies, capped at 80%), stun (no stacking, 1.5 s immunity afterwards), shield (sources add up to 60% of max health; the shield ending first drains first), heal over time (adds up), taunt (latest wins), vulnerable and empower (strongest applies, no adding up). Vulnerable and shields are part of the one damage pipeline (`Damage.apply`); empower scales the attacker's hits in `CombatService.applyHit`. Structures are immune to stun, slow and taunt. A stun on a monster cancels its telegraphed attack (`MonsterBrain.interrupt`). Players' statuses replicate as the `Statuses` attribute (HUD labels); slows and stuns change walk speed (stun: no jumping, attacking or casting).
- **Teamwork** (decision): a monster takes +12% damage for each distinct class beyond the first that hit it in the last 6 s (+36% for all four). Without it, roles only added up: with no real danger in a 15 s fight, a support slot always lost a raw damage race (four Knights cleared centre camps fastest).
- **Aim:** directions snap to the enemy nearest the aim within a 30-degree cone, on both client and server. Lines are 2.5 to 3 studs wide on each side. Points land under the mouse, clamped to range, or ahead of the character without a mouse. Ally aim picks the ally nearest the aim within 50 degrees, else yourself.
- **Cost:** cooldowns only, no mana (decision).
- **Classes and switching:**
  - Each class keeps its own level and XP; the profile gained `classChosen`. Until a class is picked, the player has `NeedsClass` and the picker opens; closing it keeps Knight.
  - Switching is allowed at the base class station (a prompt beside spawn), while dead (a "Change class" button on the respawn screen), or on first join. The server refuses it elsewhere (verified: refused 24 studs from the station, accepted beside it).
  - Cooldowns are kept per class and slot, so switching does not reset or share them.
- **Support credit:** heals, heal over time, and shields that absorb damage on someone else give 0.25 XP per point and make the healer a supporter. Supporters of the killer or an assister within 10 s get an assist. Self-heals give nothing.
- **Milestone looks** (stubs): per class weapon (sword, bow, staff, wand) with an accent colour from level 10, a glow from 25 and sparkles from 50.
- **Camps:** tier 3 (centre) camps are now group content: health x4 (was 1.9), damage x3 (was 1.3).
- **Balance bots** (`ClassBotService`, dev):
  - Each bot plays its class sensibly: band distances, abilities on cooldown, a healer that keeps blessings up and heals the most hurt.
  - Bots dodge telegraphs, but with the player dodge cooldown and a 25% chance of reacting too late.
  - In camp tests a dead bot stays out, since a real death means respawning at base.
  - Commands: `/classclear`, `/classfight`, `/classbots`, `/class`, `/statuses`.
- **Acceptance, mixed group:** centre camps, level 20, two runs each, seconds from first hit:

  | Group | C3 (Burrower) | C6 (Splitter) | C9 (Shellback) | Average |
  |---|---|---|---|---|
  | Mixed (Knight, Hunter, Mage, Healer) | 13.1, 12.5 | 15.1, 10.6 | 13.0, 16.2 | 13.4 |
  | 4 Knights | 19.2, 17.8 | 14.7, 17.0 | 17.5, 25.6 | 18.6 |
  | 4 Hunters | 16.1, 15.2 | 26.7, 35.4 | 17.2, 9.0 | 19.9 |
  | 4 Mages | 24.8, wiped | 51.3, not in 90 s | 13.8, 16.2 | worst |

- **Acceptance, Healer XP:** 4v4 mixed bot skirmish in the middle lane with minion waves, 5 minutes, XP per bot. Run 1: Healer 2070, Hunter 1899, Mage 1578, Knight 736. Run 2 (sturdier Knight): Healer 1978, Hunter 1984, Mage 1717, Knight 688. The Healer's XP came from assists (650 to 850), kills, support (about 250) and minions.
- **Acceptance, aim:** every ability resolves through aim assist, a clamped point, or a self or ally pick. Verified in Studio by casting each kit at gym targets: Mark's +25% shows on the next arrow (19 to 24); Prison stunned the slam monster; Rally taunted and shielded; Bash stunned; Mend healed 41 then ticked; Barrier shielded.
- **Performance gate (approximated low-end PC, 2 cores, graphics level 1, restored afterwards):** Phase 9 load plus `/classbots 20` (40 class bots using abilities).
  - Load: 1152 minions (waves piled up behind the fight in the middle: double Phase 9's), 210 NPCs, 113 monsters (92 awake), up to 6 traps.
  - Per frame: minion tick 2.95 ms (worst 4.3), NPCs, monsters and class bots 0.41 ms (0.28 before), about 3.4 ms in all.
  - Server held 60 Hz (95th percentile 18.1 ms, worst 19.6); client simulation held 60 Hz; server send 26.5 KB/s.
  - The Studio viewport was not rendering in this session, so client render frame rate was not measured. Rerun it with the viewport visible.
- **Carried forward to Phase 11:**
  - The Knight earns a third of the others' XP in PvP skirmishes: it dies about every 14 s leading the charge, since taunt does not affect players. More health and defence did not change that.
  - Four Mages struggle against single big monsters.
  - Mage AoE hits minions near camps.
  - Teamwork and blessing should show in the UI (boss bar).
  - Human checks: the picker and station flow by mouse, ability feel, effect readability.

---

## Phase 11: Balance, anti-snowball, and telemetry

**Status:** Complete (human-data checks pending: the acceptance numbers below come from the round simulator and class bots)

**Goal:** Rounds that swing back and forth and then resolve, measured with data.

**Tasks**

- [x] Telemetry events per Appendix B, sent to Roblox analytics and to a custom sink for round-level analysis.
- [x] Team fill: joiners go to the smaller team, then the weaker team by strength (Phase 2), then the losing team; minion waves scale up for a team that is short on players or strength.
- [x] Strength equalisers driven by `TeamService.balance()`: small, capped adjustments for the weaker team (for example minion wave strength, respawn time, objective rewards), scaled by the strength gap. They nudge matches towards even and never let a far weaker player beat a far stronger one alone.
- [x] Escalation: wave strength grows over the round and siege minions appear after a set time so rounds end.
- [x] Fading comeback help: defender bonuses are strong early and decay after a set time.
- [x] Power score per player (active class level, active pet) for bounty and underdog logic; this is the same value as `TeamService.powerOf`, so team strength and individual power agree.
- [x] Bounties: high power score or kill streak marks a player and adds a reward for defeating them.
- [x] Underdog bonus: attackers deal extra damage to a target in proportion to the power gap, capped (Appendix A).
- [x] Full, unsplit assist rewards.
- [x] Round payout: contribution-based, losing team receives most of the winner's amount, bonus for long and close rounds, bonus for staying to the end.
- [x] Leaver handling and idle detection.
- [x] Neutral jungle boss on a timer as a planned swing moment.
- [x] Bot-versus-bot overnight simulation to tune numbers before human tests, run headless under Lune on the pure simulation modules (see section 2) via a `make` target.
- [x] Balance dashboard: round length distribution, first-guardian win rate, front-line reversals per round, class pick and win rates.

**Acceptance tests**

- Median round length is 20 to 30 minutes.
- The team that kills the first guardian wins 55 to 60 percent of rounds.
- A group of three new players can defeat one maxed player.
- In bot simulation, a team holding 55 percent of total strength wins between 50 and 65 percent of rounds (starting target: equalisers help the weaker team without erasing the stronger team's edge).

**Performance gate:** Telemetry adds no measurable frame cost; full regression load test passes.

**Implementation notes**

- **Rules are pure** (`Shared.Balance`, tested): equalisers, escalation and siege counts, the behind bonus, fading defender help, underdog, bounties, payout, idle, and front-line reversals. `BalanceService` applies them through hooks: `MinionService.strengthOf` and `siegeCount`, `MonsterService.defenderRespawnScale`, `CharacterService.respawnScale` (wrapped), `ProgressionService.rewardScale`, `TeamService.behindTeam`, and `TeamService.powerOf` (wrapped so idle players count 0).
- **Wave strength per team** is the equaliser x escalation x behind bonus x jungle boss buff, applied to new minions' health and damage.
  - Equaliser: up to +25% waves, -25% respawn and +20% XP. It reaches full strength at a 40% strength gap; short-handed teams get +5% waves per missing player, up to +15%.
  - Escalation: from minute 8, +8% a minute, up to x2. Siege minions (200 health, 22 damage) join each wave from minute 12, one more every 5 minutes, up to 3.
  - Behind bonus: +20% waves per structure lost beyond the other team, up to +50%.
- **Comeback help:** defender respawn help (x0.5) now applies while any of a team's structures is under attack, not only the Titan. It fades to nothing between minutes 10 and 25.
- **Underdog:** damage between players (and class bots) is multiplied by 1 + 0.5 x (target power / attacker power - 1), capped at +25%.
- **Bounties:** power 1.35 or a 4-kill streak puts a bounty on a player: 50 XP plus 15 per kill past 4, up to 200. It shows on their nameplate and is announced when placed and when claimed.
- **Payout** (replaces the flat 200/100 round XP): 200 for a win, 80% of that for a loss. Contribution (score against the round average, now including healing) moves it by up to ±30%. Long rounds add up to +25% (15 to 30 min), close rounds add up to +25%, and staying for the second half adds 50. Seen in Studio: a win with the clock fast-forwarded paid 265.
- **Unsplit rewards:** assists now pay the full kill XP (50), and camp monster XP goes in full to everyone who damaged the monster.
- **Idle:**
  - After 3 minutes without movement or combat, a player gets the `Idle` attribute: their power counts 0, "idle" shows on their nameplate, and they get a toast. Moving clears it.
  - Removed after 15 minutes (not in Studio).
- **Leavers:** when a leave makes the teams differ by two or more, the next player on the bigger team to die respawns on the smaller team, with a toast.
- **Jungle boss** (`JungleBossService`, new monster type Warden: 6000 health, slam, tail, charge, calls splitlings at half health):
  - It appears at minute 10, then 8 minutes after each death, alternating between the north and south pits between the centre walls.
  - Its killers' team gets waves x1.5 for 120 s, and that team gets 150 XP near the pit. Everyone is told.
  - Verified in Studio: it spawned on schedule; killing it announced "Red slew the Warden", set Red's waves to x1.5 and gave 150 XP.
- **Telemetry** (`Shared.Telemetry`, tested; `TelemetryService`):
  - Appendix B events plus `boss_killed` and `bounty_claimed`. Player events go to `AnalyticsService:LogCustomEvent` (one value, three custom fields), batched by design: one event per action.
  - Every event goes into the round log. Lane control (from the minion fronts) and team sizes are sampled every 10 s, server frame time every 30 s.
  - At round end the log becomes one compact record (length, winner, average team sizes, front-line reversals, first guardian, kills, camps, eggs, bosses, class and result per player, frame time). It is saved to `<prefix>telemetry_v1` (last 200 rounds, one write per round).
  - `/dashboard` shows the round length distribution, first-guardian win rate, reversals per round, and class pick and win rates.
  - Verified: a round ended with `/endround` was saved and appeared on the dashboard.
  - `economy`, `purchase` and `onboarding_step` are defined but unused until Phases 12 and 13.
- **Round simulator** (`Shared.RoundSim`, `make sim`; about 6,000 rounds in a few seconds).
  - What it uses from the game: structure health, gating, respawn rules and every Phase 11 rule.
  - Players have power (levels and pets: what the game balances on) and a per-round skill factor (log-normal, about ±40%, invisible to the game).
  - Fights scale with power squared (health x damage); pushing scales with power.
  - Calibration found two model bugs: the underdog bonus was applied to all pushing, which erased any power edge; and a plain LCG's correlated values biased per-player rolls (now xorshift).
  - Calibrated with seeds 1 and 7, 1500 rounds per scenario, 10 v 10:

  | Scenario | Median length | First guardian wins | Team 1 wins | Reversals |
  |---|---|---|---|---|
  | Even teams | 22.2 to 22.7 min | 56.9 to 57.9% | 48.8 to 49.2% | 6.3 |
  | Team 1 at 55% strength | 18.9 to 20.6 min | 60.4 to 61.0% | 56.4 to 61.1% | 5.7 |
  | Team 1 at 60% strength | 15.1 to 15.4 min | 70.9 to 72.6% | 73.2 to 73.4% | 4.5 |
  | Team 1 one player short | 23.0 to 23.4 min | 57.2 to 58.0% | 51.4 to 51.8% | 6.2 |

  - Without skill noise, a whole team 1.5x stronger (60% share) wins about 63%. Equalisers soften the edge but do not erase it (unit test).
- **Structure health** is now x0.7 (outer 2100, inner 2800, Titan 5600). It took this to bring the simulated median into 20 to 30 minutes, and it fits Phase 6, where bots could not finish the Titan.
- **Acceptance, three new against one maxed:** class bots in the gym; level 1 with no pet, against level 500 with a maxed pet (power 1.5). The three new players won all six matchups:
  - Knights against a Knight (5.2 s, one standing).
  - Hunters against a Hunter (1.6 s).
  - Mages against a Mage (1.0 s, all standing).
  - Knight, Hunter and Healer against a Knight (3.9 s).
  - Knights against a Hunter (3.4 s).
  - Healers against a Knight (6.2 s).
  - A unit test checks the same with the stat function alone.
- **Performance gate (approximated low-end PC, 2 cores, graphics level 1, restored afterwards):** Phase 10 load (`/loadtest`, `/siege`, `/unleash 20`, `/pets 40`, `/classbots 20`) with the round aged 16 minutes (escalation and siege minions on).
  - Load: 1056 minions, 208 NPCs, 116 monsters.
  - Per frame: minion tick 2.49 ms (worst 3.6), NPCs 0.35 ms.
  - Server held 60 Hz (p99 19.0 ms); client simulation held 60 Hz; send 26.9 KB/s.
  - Telemetry only reacts to signals and samples on slow timers.
  - One isolated server frame of 76 to 96 ms appeared about once a minute; it does not follow the 12 s waves or the 30 s telemetry timer (likely garbage collection at this minion count). To profile with the MicroProfiler in Phase 14.
- **Carried forward:**
  - Player fights are very short: three Mages remove a maxed Mage in 1 s. Time to kill is for the fun gate.
  - Round numbers must be checked against human telemetry once players exist (the simulator's skill spread and lane model are assumptions).
  - The Knight's PvP XP (Phase 10) is still to be fixed.
  - The Warden and wave buffs should appear on the minimap and HUD.

---

## Phase 12: Gold, cosmetics, and monetization

**Status:** Complete (Robux products and the game pass are created in Phase 16, after all game development; client render cost needs the viewport visible)

**Goal:** A cosmetic economy that funds the game without affecting fairness.

**Tasks**

- [x] Gold earning from play, with rates in config.
- [x] Cosmetic catalogue format: weapon skins, armour skins, pet skins, trails, kill effects, emotes, titles, each with rarity and price.
- [x] Cosmetic rendering on players and pets with a strict per-item performance budget.
- [x] Level milestone looks for each class (free, show real strength).
- [x] Shop screen: featured items, categories, preview on the player's own character, purchase flow.
- [x] Inventory and loadout screen.
- [x] Robux gold packs as developer products with an idempotent receipt handler and purchase history.
- [x] Game passes that do not affect power (for example, extra cosmetic loadout slots).
- [x] Daily login reward and daily quests paying gold.
- [x] Policy compliance: check regional restrictions through the platform policy service; no paid random items for restricted players; clear pricing.
- [x] Economy telemetry: sources and sinks of gold, conversion, revenue per user.
- [x] Unit tests proving no cosmetic or purchase alters the stat function or the rate or ceiling of any stat, including the XP earn rate. (There is no paid XP boost; free time-limited XP events are a Phase 14 live-ops tool.)

**Acceptance tests**

- A purchase interrupted by a disconnect is granted exactly once on rejoin.
- Every cosmetic renders correctly on all four classes and on the low-end PC.
- A fully cosmetic-equipped profile has identical stats to a bare one.

**Performance gate:** 40 players in the heaviest cosmetics plus the regression load test stays within budget.

**Implementation notes**

- **Catalogue as data** (`src/shared/Cosmetics`, format in `Types.luau`): 31 items.
  - Weapon skins: 7 (three fit any weapon, one per weapon).
  - Armour skins (shoulder plates): 4. Pet skins: 4. Trails: 4. Kill effects: 4. Emotes (G): 4. Titles: 3.
  - Prices by rarity: common 250, rare 600, epic 1200, legendary 2500 gold.
  - Items carry only looks. Tests check there are no other fields, and check the budget: at most 12 particles per second, trails up to 0.6 s and 2 studs wide.
  - Rendering (`Shared.CosmeticLook`) adds at most two parts, one emitter and one light per item.
- **Rules are pure** (`Shared.Economy`, tested): buying, equipping, loadout presets, which items apply to the weapon in hand, the login streak, daily quests (three per day, deterministic per player and day), the featured rotation, and the receipt ledger.
- **Gold from play** (`Config.economy.gold`): win 100, loss 80, player kill 5, assist 3, guardian 20 (attacking team nearby), camp clear 10, Warden 40, hatched egg 10. Daily login: 50 rising by 25 a day to 200 over a 7-day streak. Quests pay 100 to 150. A common item costs about three rounds.
- **Loadouts:** one free preset, three with the game pass. Each holds weapon skin, armour, trail, kill effect, emote and title; pet skins are set per pet. Weapon skins made for one weapon only show while using it.
- **Rendering:**
  - The server puts worn cosmetics on characters (`CosmeticService`) on spawn, on class or weapon change, and on equip.
  - Kill effects and emotes go to nearby clients (`KillEffect`, `EmotePlayed`).
  - Bought titles replace the account title on the nameplate.
  - Pet skins recolour the pet (a `tint` on the NPC spawn event).
  - Shop preview uses the same `CosmeticLook` code locally for 6 s; the worn weapon look comes back afterwards.
- **UI:**
  - Shop (H): featured, seven category tabs, gold packs, and daily login and quests.
  - Loadout (J): presets, a row per slot cycling owned items, and pet skins.
  - Gold on the HUD, with shop and loadout buttons.
- **Robux:**
  - `PurchaseService.process` grants a gold pack only if the buyer's profile is loaded here, records the receipt ID in the profile (last 100) and purchase history (last 50), and reports PurchaseGranted only after the save succeeds.
  - Gold packs (proposed): 500 for R$49, 1200 for R$99, 2600 for R$199, 7000 for R$499. The extra loadouts pass is proposed at R$99.
  - Product and pass IDs are 0 (not created yet: hidden from the shop) until approved and created on Roblox.
  - Studio has a dev-only pack (product 1, 100 gold) for `/receipt`.
- **Policy:** `PolicyService` is checked per player (`PaidRandomItemsRestricted` kept). Nothing sold is random, and nothing can be traded. Prices show before buying (gold on cards, Robux on packs and the pass).
- **Economy telemetry:** every gold source and sink goes to `AnalyticsService:LogEconomyEvent` ("Gold", with transaction type and SKU); Robux packs are logged as IAP. Conversion and revenue per user come from the Roblox Economy dashboard. Not recorded from Studio.
- **Acceptance, exactly once** (Studio, real `dev_` profile store):
  - The receipt granted +100 gold, and an immediate retry granted nothing.
  - A receipt for a buyer not in the server was NotProcessedYet.
  - After leaving and rejoining (profile saved and reloaded), the same receipt came back as PurchaseGranted with no gold added (8450 stayed 8450), and a new receipt granted +100.
- **Acceptance, all four classes:** with Royal (any weapon), Dragon Plates and Flame Trail worn, each class showed a reskinned weapon (2 parts recoloured), 2 shoulder plates and a trail. The emote, kill effect (on a class bot) and pet skin all reached the client. Not yet checked by eye or on the low-end PC with the viewport rendering.
- **Acceptance, identical stats:** unit test. A profile owning and wearing everything, with a skinned pet, has the same health, damage, defence and power at levels 1, 20 and 500 for every class, gains the same XP from the same award, and has the same power as a bare one.
- **Performance gate (approximated low-end PC, 2 cores, graphics level 1, restored afterwards):** 40 R15 rigs in the heaviest cosmetics walking in circles, plus the full regression load with the round aged 16 minutes.
  - Heaviest cosmetics: Star Staff or Royal, Dragon Plates, Void Trail.
  - Cosmetics on the rigs: 800 parts, 50 emitters, 40 trails, 80 lights.
  - Regression load: 918 minions, 209 NPCs, 117 monsters.
  - Server held 60 Hz (p99 19.1 ms); client simulation 60 Hz; send 28.1 KB/s.
  - The same isolated server hitch as Phase 11 appeared once.
  - The client render cost was not measured: the Studio viewport was not rendering. Rerun it with the viewport visible.
- **Carried forward:**
  - The products and pass are created in Phase 16, after all game development (owner decision).
  - Real cosmetic art (Phase 13).
  - Blocky-shaped pets ignore skins: only placeholder shapes with a look take the tint.
  - Render check by eye and on the low-end PC.

---

## Phase 13: UX polish, onboarding, audio, and effects

**Status:** Not Started

**Goal:** The game looks, sounds, and teaches like a top-tier Roblox game.

**Tasks**

- [ ] First-time experience: a guided first two minutes (attack a minion, dodge a telegraph, pick up an egg, deliver it) with skippable prompts.
- [ ] Contextual hints for later systems, shown once.
- [ ] HUD v2 pass: final art, iconography, animation, and information hierarchy for every screen.
- [ ] Full-screen moments: round start, guardian down, Titan phase change, victory and defeat, level-up, rare hatch.
- [ ] Ping and quick-chat wheel for team communication.
- [ ] Minimap v2 and a full map screen.
- [ ] Scoreboard and round summary v2 with highlights and progress earned.
- [ ] Final map art: terrain, lane dressing, jungle biomes per monster type, base set pieces, lighting, skybox.
- [ ] Final monster and class models, animations, and the three remaining monster types.
- [ ] Visual effects pass with quality levels; final versions of the Phase 3 placeholder combat feedback, with an off switch for hit-stop and camera shake.
- [ ] Audio: music layers that follow round state, monster voices, hit sounds, UI sounds, positional mixing.
- [ ] Accessibility: colour-blind safe team colours, text scale, reduced motion, hold-versus-toggle options, subtitles for audio cues.
- [ ] Localization of all text through the platform's translation tables.
- [ ] Effects quality presets (the game's own tiers) with automatic selection from the player's Roblox graphics level and device.
- [ ] Loading screen and asset preloading.
- [ ] Store presence: icon, thumbnails, trailer, description.

**Acceptance tests**

- New testers who have never played a lane game deliver an egg within five minutes without help.
- The game is fully playable with sound off and with colour-blind settings on.
- Every screen passes review on the reference PCs.

**Performance gate:** Full regression load test on final art: 30 frames per second on the low-end PC (approximated), memory under budget, join to playable under 15 seconds.

**Implementation notes**

_None yet._

---

## Phase 13B: Mobile and console pass

**Status:** Not Started

**Goal:** The finished PC game plays well on phones, tablets and consoles.

**Tasks**

- [ ] Add the mobile and console reference devices from section 2 and record their baselines.
- [ ] Touch controls: attack and dodge buttons, thumbstick placement, adjustable button size.
- [ ] Auto-aim assist for touch and gamepad.
- [ ] Phone and tablet UI layouts with safe areas, notches and 44-point touch targets.
- [ ] Full gamepad navigation for every component and screen.
- [ ] Phone performance budgets (frame rate and the under 1 GB memory target) and effect quality tiers tuned for phones.
- [ ] Check that the game loads on a phone and shows the debug overlay.
- [ ] Re-run the Phase 3 fun gate on phones with players aged 9 to 14.

**Acceptance tests**

- Every component and screen is usable by touch and by gamepad.
- Every screen passes review on all reference devices, including the mobile and console devices.
- No UI element overlaps system UI or the notch on any reference phone.
- The fun gate passes on phones.

**Performance gate:** Full regression load test: 30 frames per second on the reference phones, memory under 1 GB on phones.

**Implementation notes**

_None yet._

---

## Phase 14: Admin panel, live ops, and anti-cheat

**Status:** Not Started

**Goal:** The tools needed to run the game after launch.

**Tasks**

- [ ] Permission model: roles (owner, admin, moderator, tester) by user ID or group rank, checked on the server for every admin action.
- [ ] In-game admin panel built on the Phase 4 design system, invisible and inaccessible to non-staff.
- [ ] Player tools: search, view profile and session, spectate, kick, ban and unban through the platform ban interface, mute.
- [ ] Data tools: view and edit a profile, grant gold and cosmetics, restore from backup, all with a reason field.
- [ ] Match tools: end round, switch a player's team, spawn or remove monsters, set time scale, toggle bots.
- [ ] Live config through Roblox ConfigService behind `Config.get()`: ConfigService values override the defaults in `shared/Config` without a server restart. Config snapshots do not update on their own, so the wrapper refreshes them on a timer and on the change signal, and systems read through `Config.get()` rather than caching values. Confirm the ConfigService API against current documentation at the start of this phase.
- [ ] Feature flags and experiments as ConfigService usage (per-player targeting and A/B experiments where useful), read through the same wrapper.
- [ ] Announcements and scheduled events (free time-limited XP events such as double XP weekends, limited-time monsters).
- [ ] Server browser: live servers, player counts, round state, performance, with jump-to-server.
- [ ] Audit log of every admin action, stored and viewable.
- [ ] Anti-cheat: movement and teleport checks, damage sanity checks, a `Net.setViolationHandler` that feeds the remote rate-limit and payload-validation rejections (built in Phase 0) into detection, automated flags to a review queue, no automatic permanent bans.
- [ ] Player reporting flow and a moderation queue.
- [ ] Error and performance monitoring with alerts on error spikes, frame-time regressions, and data-save failures.
- [ ] External access through the platform's cloud API for data lookups and bans outside the game.
- [ ] Soft-shutdown and migration flow for updates, extending the Phase 2 shutdown handling.

**Acceptance tests**

- A non-staff client cannot open the panel or trigger any admin remote, verified with a modified client.
- A ConfigService change reaches every running server within one minute without a restart, and systems pick up the new value through `Config.get()`.
- Every admin action appears in the audit log with who, what, when, and why.

**Performance gate:** Admin and monitoring systems add no measurable cost when idle.

**Implementation notes**

_None yet._

---

## Phase 15: Soft launch and launch

**Status:** Not Started

**Goal:** Prove the game with real players, then open it.

**Tasks**

- [ ] Create a separate private test place and a publish script for it (deferred from Phase 0).
- [ ] Complete the platform's maturity and content questionnaire and all required experience settings.
- [ ] Closed test with invited players at full server size; fix what breaks.
- [ ] Real-player load test: several full 40-player servers at once.
- [ ] Verify every performance gate on real low-end PC hardware before soft launch, replacing the approximated results recorded in earlier phases.
- [ ] Soft launch to a limited audience; watch retention, session length, round completion, crash and error rates.
- [ ] Tune the first-session funnel from telemetry.
- [ ] Balance pass from real data against the Phase 11 targets.
- [ ] Private server support and pricing decision.
- [ ] Community setup: group, social links, update log, feedback channel.
- [ ] Launch checklist: backups verified, alerts on, rollback plan, on-call plan for the first 72 hours.
- [ ] Public launch.
- [ ] Post-launch content plan: new monster types, seasonal events, cosmetic drops.

**Acceptance tests**

- Full servers of real players hold the performance budgets.
- Day-one retention and average session length meet the targets set at the start of this phase.
- No data-loss incidents during soft launch.

**Performance gate:** All budgets in section 2 hold under real load.

**Implementation notes**

_None yet._

---

## Phase 16: Purchases go live

**Status:** Not Started (owner decision: after all game development)

**Goal:** Turn on Robux purchases once the game is finished, using the purchase code built in Phase 12.

**Tasks**

- [ ] Confirm the products and prices (proposed in Phase 12): gold packs of 500, 1200, 2600 and 7000 gold for R$49, 99, 199 and 499; an extra loadouts game pass for R$99.
- [ ] Grant the Open Cloud permissions (developer products and game passes, read and write), or create the products in the Creator Dashboard.
- [ ] Create the developer products and the game pass (they cannot be deleted), with icons.
- [ ] Put their IDs in `Config.economy` (`goldPacks[].productId`, `extraLoadoutsPass.passId`); the shop shows them as soon as the IDs are set.
- [ ] Test a real purchase of each in the published experience, including a disconnect before the grant (granted exactly once on rejoin).
- [ ] Check the Economy dashboard records Robux purchases (IAP) and gold sources and sinks.

**Acceptance tests**

- Each gold pack and the game pass can be bought, and each purchase is granted exactly once.
- No purchase changes stats, XP rates or ceilings (the Phase 12 unit tests still pass).

**Implementation notes**

_None yet._

---

## Appendix A: Progression and fairness maths (starting values)

All constants live in config and are expected to change in Phase 11.

- **Level stat multiplier:** `1 + 0.25 * L / (L + 20)`, where `L` is the active class's level. Level 20 gives half the bonus; the ceiling is 1.25.
- **Class levels and account level:** each class has its own level and XP, and XP earned goes to the active class. Account level is the sum of all class levels; it gates the second and third pet slots and titles. Each class has its full core ability kit by class level 10.
- **Catch-up XP:** a class whose level is below the player's highest class level earns XP at `catchUpMultiplier` (starting value 2) until it reaches that level. An award that crosses the threshold is multiplied only up to the threshold.
- **Pet power multiplier:** `1 + 0.20 * x / (x + h)`, where `x` is pet XP and `h` is the half-way constant. The ceiling is 1.20.
- **Combined ceiling:** `1.25 * 1.20 = 1.5` times a new player.
- **Underdog bonus:** attacker damage is multiplied by `1 + k * max(0, P_target / P_attacker - 1)`, capped, where `P` is power score. It has no effect between equals.
- **Team strength:** each member's power `P` is their combat multiplier (level multiplier times pet multiplier, 1.0 to 1.5); team strength is the sum of `P` over the team, and the strength gap is the difference. Joiners go to the weaker team when headcount is equal and the gap exceeds `strengthTolerance` (starting value 0.25, a quarter of a new player). Phase 11 equalisers are capped functions of the gap.
- **Starting tuning values:** wave every 30 seconds; six minions per wave; respawn five seconds plus scaling; escalation from minute 15; incubation 60 to 180 seconds by rarity; four slots per hatchery; carrier speed reduced by 30 percent.

## Appendix B: Telemetry events

| Event | Key fields |
|---|---|
| `round_start`, `round_end` | duration, winner, team sizes over time, front-line reversals |
| `guardian_killed`, `titan_phase` | lane, team, time in round |
| `player_join`, `player_leave` | time in round, team state, session length |
| `player_kill` | classes, levels, power gap, assists, bounty |
| `camp_cleared` | monster type, group size, clear time |
| `egg_event` | picked up, dropped, deposited, stolen, hatched, choice made |
| `level_up`, `pet_progress` | new value, time played |
| `economy` | gold source or sink, amount, item |
| `purchase` | product, price, first purchase flag |
| `onboarding_step` | step, time to complete, skipped |
| `performance_sample` | server frame time, bytes per client, client frame rate, device class |

## Appendix C: Risk register

| Risk | Mitigation |
|---|---|
| Minion and monster counts exceed the server budget | Data-driven simulation, early load gate in Phase 5, parallel execution as fallback, lower counts with stronger units |
| Low-end PCs (and later phones) cannot render large fights | Level of detail, effect quality tiers, interest-based replication |
| Rounds stalemate or end too fast | Escalation timer, fading comeback help, telemetry targets in Phase 11 |
| Persistent power gap drives new players away | Hard 1.5 times ceiling, underdog bonus, bounties |
| Monster content cost grows | Primitive kit and definition files; six types at launch |
| Data loss | Session locking, autosave, backups, save-failure alerts |
| Exploits in a competitive game | Server authority from Phase 3, validation on every remote, Phase 14 detection |
| Name or likeness too close to an existing game | Original names, art, and map; name check before store assets in Phase 13 |
| Combat is not fun, and later phases build on it | Phase 3 fun gate with players aged 9 to 14, live tuning panel, escalation to the owner after three failed tuning rounds |
| Development and live servers share save data (one place) | Data store names namespaced by environment from Phase 9; Studio uses a `dev_` prefix |
| Low-end gates pass only on approximated hardware | Label approximated results; verify on real low-end PC hardware in Phase 15 before soft launch |

## Appendix D: Decision log

Record decisions here as they are made, with the date and the reason.

| Date | Decision | Reason |
|---|---|---|
| 2026-11-22 | Level gives stats; gold is cosmetic only | Fewer stacking systems; gold can be sold without affecting fairness |
| 2026-11-22 | Eggs incubate at six fixed hatcheries; raid-only | Lane choice for carriers; avoids forward-spawn snowball |
| 2026-11-22 | All structures and creeps are monsters | Single readable theme |
| 2026-11-22 | Checks run locally through `make check`, not hosted CI | Local compute is enough for a small team; no CI secrets or Roblox runtime in the cloud |
| 2026-11-22 | Develop in the main place; no test place until publishing | Nothing is public yet, so a second place only adds sync and publish overhead |
| 2026-11-22 | Unit tests run under Lune with an in-repo harness | No package dependency, fast, and runs from `make`; engine-dependent tests can run in Studio later |
| 2026-11-22 | PC first; phones, tablets and consoles in a Phase 13 pass | Ship and tune the core game on one platform; the input layer and UI stay adaptable so other platforms are an addition, not a rewrite |
| 2026-11-22 | Added a combat fun gate and placeholder feedback to Phase 3 | Combat feel must be proven before later phases build on it |
| 2026-11-22 | Per-class levels and XP; account level is the sum of class levels; double catch-up XP for lower classes; class switching at base or on respawn only | Players can try every class without starting over on power, while the active class still reflects time invested in it |
| 2026-11-22 | Nothing bought with Robux changes the rate or ceiling of any stat; paid XP boost removed | Keeps the fairness promise that money buys cosmetics only |
| 2026-11-22 | Live config uses Roblox ConfigService behind `Config.get()` | Built-in live updates and experiments replace custom propagation, versioning and rollback |
| 2026-11-22 | Low-end PC gates approximated on the development PC until Phase 15 | No low-end hardware during development; real hardware verifies before soft launch |
| 2026-11-22 | Fun gate target age range is 9 to 14 | Matches the intended audience |
| 2026-11-22 | Mobile and console work split into Phase 13B | Phase 13 was too large; keeps the platform pass separate from polish |
| 2026-11-22 | Team balance is headcount plus strength (sum of member power); joins and reshuffles favour the weaker team; the gap drives capped Phase 11 equalisers | Levels make headcount alone misleading; balance should nudge matches towards even without making high levels meaningless |
| 2026-11-22 | Fun gate deferred; Phase 4 starts while Phase 3 stays In Progress | Owner chose to keep building; the gate still runs before launch work depends on combat feel |
| 2026-11-22 | UI framework is Fusion 0.3 | Small, Luau-native, built-in springs for motion; React-lua is heavier with weaker strict typing |
| 2026-11-22 | Structures cannot be damaged outside the Active phase | Nothing is decided before a round starts (bots or players fighting during Intermission) |
| 2026-11-22 | Guardians are fully escapable on foot; the Titan's sweep, volley and quake are dodge checks | Guardians stay fair for new players; the Titan asks for the dodge skill |
| 2026-11-22 | Kills by guardians, Titans and other monsters do not count towards team kills | Team kills measure the teams' own fights |
| 2026-11-22 | Monster types are one definition file each in `src/shared/Monsters`, listed in its index | A new type needs a file and assets, no code; the index line is the only registration |
| 2026-11-22 | Jungle camps are one monster each (plus its summons or split pieces); tier by distance from the centre line | Keeps each fight readable; tiers put the hardest camps in the contested middle |
| 2026-11-22 | Camp monsters and structures survive `/clearnpcs` | Dev load tests must not break camp and round bookkeeping |
| 2026-11-22 | Hatcheries are raidable only after that lane's outer guardian is dead | Raids become a reward for pushing a lane, so new players' eggs are safe early in a round |
| 2026-11-22 | Until Phase 9, "claim" and "feed" record counters on the player; "unleash" is fully live | The hatch loop is testable end to end now; Phase 9 swaps the stub for pets |
| 2026-11-23 | Profiles use our own session lock on `UpdateAsync` (Shared.SessionLock) instead of a profile library | Small, pure and unit tested with a fake store; no extra package; the semantics we need (claim, refresh, release, stale takeover) fit in one module |
| 2026-11-23 | Pets cannot be targeted or damaged, never summon, and run through MonsterService (the monster kit) rather than the minion arrays | Pets need the monster attacks and telegraphs; at most 40 exist; untargetable companions avoid griefing and keep the 1.5x power ceiling the only pet effect on fights |
| 2026-11-23 | NPC snapshots are filtered per client by the interest radius | Monster and pet counts grew; this cut server send at the full load test from 32.5 to 21.9 KB/s |
| 2026-11-23 | Launch pads: one per lane in each base, flying the player in an arc to the furthest guardian their team still holds in that lane (outer, then inner; idle once both fall). No attacking or dodging mid-flight; egg carriers cannot launch; the client flies its own character and the server corrects a flight that does not arrive | The map took too long to cross (owner request). Landing at your own guardian keeps launches defensive and never drops you behind enemy lines (Shared.Launchers, LauncherService, LauncherController) |
| 2026-11-23 | Abilities cost cooldowns only (no mana or other resource) | Casual game; one fewer bar to read; cooldowns already pace casting |
| 2026-11-23 | Teamwork: monsters take +12% damage per distinct class beyond the first among recent attackers (max +36%) | Without it roles only add up, so stacking the highest damage class beats any mixed group in short fights; this makes "four distinct roles" pay off directly and visibly |
| 2026-11-23 | The Healer's casts on allies also empower them (+20% damage, no stacking); "damage amplification" exists both as vulnerable (target) and empower (attacker) | Gives the support role a way to speed up fights, not only prevent deaths |
| 2026-11-23 | Centre (tier 3) camps are group content: health x4, damage x3 | They are the contested middle; at x1.9 a group of four cleared them in 8 s with no danger, so roles never mattered |
| 2026-11-23 | Class cooldowns are kept per class and slot; switching class is only at the base station, while dead, or on first join | Switching cannot reset or share cooldowns, and nobody swaps kits mid-fight |
| 2026-11-23 | A behind bonus (stronger waves per structure lost beyond the other team, capped) and defender respawn help for any structure under attack | In simulation, without them the team that took the first guardian won about 73% of rounds; with them, 57 to 58% |
| 2026-11-23 | Structure health x0.7 | Needed for a 20 to 30 minute median in simulation; matches Phase 6, where bots could not finish the Titan |
| 2026-11-23 | Assists pay the full kill XP; camp monster XP is given in full to every contributor | "Full, unsplit" rewards: helping is never worth less than finishing |
| 2026-11-23 | The round payout replaces the flat win/loss XP | Contribution, closeness, length and staying now matter; losers still get 80% |
| 2026-11-23 | Telemetry's custom sink is a DataStore of compact round records (last 200), one write per round | No external service needed; enough for the balance dashboard; within DataStore budgets |
| 2026-11-23 | The round simulator models skill as a hidden per-round factor and fights as power squared | Without skill, power alone decided rounds; without power squared, power barely mattered |
| 2026-11-23 | Robux receipts are recorded in the player's own profile (last 100 IDs) and reported granted only after the profile save succeeds | Exactly-once with the existing session lock; no second data store to keep consistent |
| 2026-11-23 | Products are configured by ID and hidden until created (ID 0); proposed prices: gold packs 500/1200/2600/7000 for R$49/99/199/499, extra loadouts pass R$99 | Creating real products is outward-facing and needs owner approval |
| 2026-11-23 | Nothing sold is random and nothing is tradable | Simplest policy compliance in every region |
| 2026-11-23 | Robux products and the game pass are created in a final milestone (Phase 16), after all game development | Owner decision; the purchase code stays in place, hidden while product IDs are 0 |
