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
| 3 | Player combat core | Not Started |
| 4 | UI foundation and HUD v1 | Not Started |
| 5 | Minion system and load harness | Not Started |
| 6 | Guardians and Titan (first full round) | Not Started |
| 7 | Jungle camps and monster kit | Not Started |
| 8 | Eggs and hatcheries | Not Started |
| 9 | Persistence, levels, and pets | Not Started |
| 10 | Classes | Not Started |
| 11 | Balance, anti-snowball, and telemetry | Not Started |
| 12 | Gold, cosmetics, and monetization | Not Started |
| 13 | UX polish, onboarding, audio, and effects | Not Started |
| 13B | Mobile and console pass | Not Started |
| 14 | Admin panel, live ops, and anti-cheat | Not Started |
| 15 | Soft launch and launch | Not Started |

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

**Status:** Not Started

**Goal:** One class (Knight) that can attack, dodge, take damage, die, and fight other players, with server-authoritative results.

**Tasks**

- [ ] Stats component per player: max health, health, damage, defence, move speed, derived from a single pure stat function whose input is the active class level (stubbed until Phase 9) and the active pet (stubbed).
- [ ] Input layer mapping touch, mouse and keyboard, and gamepad to the same actions.
- [ ] Melee attack: client plays the swing immediately; server validates range, arc, cooldown, and line of sight, then applies damage.
- [ ] Dodge with a short invulnerability window and cooldown.
- [ ] Damage pipeline: one function for all damage, with source, target, type, and modifiers, emitting events for UI and telemetry. Targets can be player characters or NPC rows through one interface.
- [ ] Health regeneration out of combat and at base.
- [ ] Death, kill credit, assist credit (anyone who damaged the target in the last 10 seconds), respawn.
- [ ] Lag handling: server accepts hits within a bounded latency window and rejects impossible ones.
- [ ] Unit tests for the stat function and the damage pipeline.
- [ ] Combat gym: a dev-only test area with a target dummy, a simple bot that walks and attacks, a spawner for a pack of weak enemies, and one test monster that uses a telegraphed ground slam (minimal state machine: idle, telegraph, attack, recover). This is a throwaway precursor to the Phase 6 monster framework, not a replacement for it. Gym enemies and the test monster are built as a minimal version of the data-driven NPC model (server rows, client rendering), not Humanoid characters, so Phase 5 extends this rather than replacing it.
- [ ] Placeholder combat feedback: hit flash, hit-stop, knockback, damage numbers, a basic health bar, hit and swing sounds, light camera shake. Rough quality is acceptable; each must be present. Hit-stop is purely visual on each player's own screen and never pauses the server simulation. Damage numbers and the health bar are replaced in Phase 4.
- [ ] Live tuning panel (dev builds only) for attack speed, attack range and arc, dodge distance and cooldown, invulnerability window, hit-stop duration, knockback strength, and enemy health.
- [ ] Instrument input-to-swing latency and time-to-kill in the gym.

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

_None yet._

---

## Phase 4: UI foundation and HUD v1

**Status:** Not Started

**Goal:** A design system and UI framework that every later phase builds on, plus the first real HUD. The target is a clean, modern look comparable to top current Roblox games.

**Tasks**

- [ ] Choose the UI framework (Fusion or React-lua) and record the decision.
- [ ] Define design tokens: colour palette (neutral dark surfaces, one accent per team, semantic colours for health, danger, rarity), type scale, spacing scale, corner radii, stroke, elevation, motion durations and easing.
- [ ] Build core components: button, icon button, panel, modal, tab bar, list, card, progress bar, tooltip, toast, badge, cooldown ring.
- [ ] Responsive layout for desktop: scale from 1366x768 to 4K and ultrawide, respect the Roblox top bar. Keep layouts adaptable so touch, tablet and console layouts can be added in the Phase 13B mobile pass.
- [ ] Full keyboard navigation for every component (gamepad in the Phase 13B mobile and console pass).
- [ ] Motion: spring-based transitions, press feedback, number roll-ups; a reduced-motion setting.
- [ ] HUD v1: health bar, level badge, ability buttons with cooldowns, team score strip, round timer, kill feed, respawn screen.
- [ ] World-space UI: name plates, health bars over players, damage numbers, all pooled.
- [ ] Minimap v1: lanes, bases, teammates.
- [ ] Settings screen shell: effects quality (the game's own effect tiers; games cannot change Roblox's graphics quality level), audio sliders, control options, reduced motion.
- [ ] Component gallery: a dev-only screen in the main place for visual review of every component in every state.

**Acceptance tests**

- Every component is usable by mouse and keyboard.
- The HUD is readable and unobstructed at 1366x768 and at 4K.
- No UI element overlaps the Roblox top bar or other system UI.

**Performance gate:** HUD costs under 1 ms per frame on the low-end PC; no per-frame instance creation.

**Implementation notes**

_None yet._

---

## Phase 5: Minion system and load harness

**Status:** Not Started

**Goal:** Waves of minions marching and fighting down all three lanes at full scale, proven by an automated load test. This is the highest-risk system for performance.

**Tasks**

- [ ] Minion data model: struct-of-arrays storage with free-list reuse.
- [ ] Movement along the lane spline as a scalar lane progress plus lateral offset; no pathfinding.
- [ ] Wave spawner per lane per team on a timer, with wave composition in config.
- [ ] Targeting through the spatial grid: nearest enemy minion, then player, then guardian.
- [ ] Minion combat: melee and ranged variants, attack timers, damage through the shared pipeline.
- [ ] Player-versus-minion hits resolved against the data arrays.
- [ ] Proximity credit for nearby players (no last-hit requirement): emit credit events now; XP is applied from Phase 9 and gold from Phase 12.
- [ ] Snapshot replication: packed buffers, delta encoded, 10 Hz, filtered by interest area, chunked by interest cell with an entity cap per message so every unreliable message stays under 900 bytes (the engine drops messages over 1000 bytes).
- [ ] Client renderer: pooled models, interpolation, local animation, local hit and death effects, level-of-detail by distance (full model, simplified model, hidden with minimap dot).
- [ ] Minimap: minion wave indicators per lane.
- [ ] Bot load harness: N server-side bot entities (see section 2) that move down lanes, attack, dodge, and die through the same code paths as players, for repeatable tests.
- [ ] Automated performance report: server frame time, per-system time, bytes per client, and client frame time measured with several real clients (Studio multi-client test) on the reference PCs (low-end approximated until Phase 15).
- [ ] Evaluate moving the minion tick to Parallel Luau if the single-thread budget is exceeded.

**Acceptance tests**

- Two opposing waves meet mid-lane, fight, and the survivors continue.
- A player can cut through a wave; minions die in one to three hits.
- Minions seen by two clients are in the same place within a small tolerance.

**Performance gate:** 300 minions plus 40 bots: server simulation under 5 ms per frame, under 50 KB/s per client, 30 frames per second on the low-end PC. From here on, this test is rerun at the end of every phase.

**Implementation notes**

_None yet._

---

## Phase 6: Guardians and Titan (first full round)

**Status:** Not Started

**Goal:** Lanes are defended, bases can fall, and a complete round can be played from start to reset.

**Tasks**

- [ ] Replace the Phase 3 throwaway test monster with the full monster behaviour framework, carrying over the tuning values that passed the fun gate.
- [ ] Monster behaviour framework: state machine with idle, telegraph, attack, recover, stagger, dead.
- [ ] Attack primitives, part one: ground slam (circle), sweep (cone), projectile.
- [ ] Telegraph rendering: ground decals with fill timing, readable at a glance in a crowded fight.
- [ ] Guardian definition: stationary, large health pool, two or three attacks, targets minions before players unless a player attacks a teammate nearby.
- [ ] Lane gating: inner guardian is invulnerable until the outer guardian in that lane is dead; Titan is invulnerable until at least one inner guardian is dead.
- [ ] Titan definition: three phases with changing attacks, defender buffs while it is under attack (faster respawn near base).
- [ ] Stagger window: damage during recovery fills a stagger bar that opens a bonus-damage window.
- [ ] Knockback and ragdoll on heavy hits, client-simulated with server-validated end positions.
- [ ] Guardian sleep: no logic ticks when no enemy is in range.
- [ ] Round end on Titan death, wired into the Phase 2 state machine.
- [ ] HUD: guardian and Titan health on the score strip, boss bar when in range, lane status on minimap.
- [ ] Round summary screen v1: winner, duration, personal stats.

**Acceptance tests**

- A full round is played from start to Titan death to reset with bots and with human testers.
- Every telegraphed attack can be avoided by a player who reacts to the telegraph.
- A guardian cannot be damaged out of order.

**Performance gate:** Phase 5 load test plus all 14 large monsters active stays within budget.

**Implementation notes**

_None yet._

---

## Phase 7: Jungle camps and monster kit

**Status:** Not Started

**Goal:** Jungle fights that are fun in their own right, built from a reusable kit.

**Tasks**

- [ ] Attack primitives, part two: charge, summon, grab-and-throw, burrow.
- [ ] Monster definition format: stats, two primitives, one signature mechanic, model and animation references, egg type.
- [ ] Three monster types, each with a distinct signature (examples: takes damage only from behind; splits into two on death; burrows and resurfaces under a player).
- [ ] Camp controller: spawn group, leash range, reset when players leave, respawn timer.
- [ ] Camp difficulty tiers by distance from base, with the centre camps the hardest.
- [ ] Egg drop on clear (pickup only; carrying arrives in Phase 8).
- [ ] Group scaling: camp health scales mildly with the number of attackers so groups are faster but not trivial.
- [ ] Camp sleep when no player is near.
- [ ] Minimap: camp alive and respawn indicators.
- [ ] Authoring tool: grow the Phase 3 combat gym (dev-only, in the main place) so it can spawn any monster definition for isolated tuning.

**Acceptance tests**

- Each monster type requires a different approach, confirmed by play-testers.
- A solo player using the stubbed stat function at a mid-range class level (Phase 9 does not exist yet) clears an outer camp in about 30 seconds.
- A new monster type can be added with a definition file and assets, without new code.

**Performance gate:** All 12 camps awake at once plus the Phase 6 gate stays within budget.

**Implementation notes**

_None yet._

---

## Phase 8: Eggs and hatcheries

**Status:** Not Started

**Goal:** The full egg loop inside a round: carry, incubate, raid, and unleash.

**Tasks**

- [ ] Egg entity: type, rarity, owner, state (dropped, carried, incubating, hatched).
- [ ] Pickup and carry: carrier is slowed, cannot dodge, is marked on the enemy minimap when seen, and drops the egg on death.
- [ ] Dropped egg rules: who can pick it up, despawn timer.
- [ ] Hatchery: fixed number of slots, deposit interaction, incubation timer by rarity, visible glowing eggs in slots.
- [ ] Raiding: an enemy player inside the hatchery can channel to take an incubating egg, then must carry it home to restart incubation.
- [ ] Hatchery access rule: raidable only after that lane's outer guardian is dead (decide and record; alternative is always raidable but guarded).
- [ ] Hatch prompt for the owner with the three choices; claim and feed are stubbed until Phase 9.
- [ ] Unleash: spawns the monster as an allied lane unit at that hatchery, using its camp definition scaled for lane use.
- [ ] Offline or absent owner: auto-unleash after a timeout.
- [ ] Round reset clears all eggs.
- [ ] HUD: carry indicator, hatchery slot display, incubation timers, hatch prompt, raid alert for the defending team.
- [ ] Anti-abuse: movement speed validation on carriers, interaction range and rate checks.

**Acceptance tests**

- An egg goes from camp to hatchery to unleashed lane monster.
- A raider steals an incubating egg and incubates it at their own hatchery.
- Killing a carrier drops the egg and either team can recover it according to the rules.

**Performance gate:** 20 unleashed monsters on lanes plus the Phase 7 gate stays within budget.

**Implementation notes**

_None yet._

---

## Phase 9: Persistence, levels, and pets

**Status:** Not Started

**Goal:** Progress that carries across rounds and sessions.

**Tasks**

- [ ] Profile schema v1: a per-class map of level and XP, last active class, pets (up to three, each with type, pet XP, cosmetic), active pet, gold, cosmetics owned, settings, statistics. Pets, pet XP, gold and cosmetics are account-wide.
- [ ] Data store names namespaced by environment from `Config` (for example a `dev_` prefix in Studio), so Studio sessions in the main place never read or write live player data.
- [ ] Session-locked load and save with retry, autosave, save on leave, and schema migration support.
- [ ] Failure handling: if a profile cannot load, the player is told and is not allowed to play on an empty profile.
- [ ] XP sources: minions, monsters, guardians, player kills and assists, objectives, round completion. All XP awards go to the active class (wired to the Phase 5 credit events).
- [ ] Level curve and stat function per Appendix A, driven by the active class level; stats flatten, level number does not cap.
- [ ] Account level: the sum of class levels, shown on the nameplate with the class level.
- [ ] Unlocks split by level type: class level unlocks abilities and class milestone looks; account level unlocks the second and third pet slots and titles.
- [ ] Catch-up XP: a class below the player's highest class level earns double XP (multiplier in Config) until it reaches that level, with a unit test covering below, at and crossing the threshold.
- [ ] Claim: add hatched monster to the stable; if full, choose one to replace.
- [ ] Feed: convert the hatched monster to pet XP on a chosen pet, with a bonus for matching type.
- [ ] Pet stat curve per Appendix A.
- [ ] Set `TeamService.powerOf` from each player's combat multiplier (active class level multiplier times active pet multiplier, Appendix A), and refresh team strength when a player levels, switches class, or switches pet.
- [ ] Active pet in the world: follows the owner, auto-attacks, uses its signature move on a cooldown; simulated in the same data pipeline as minions.
- [ ] Switching the active pet at base.
- [ ] Unleash reward: level XP to the owner based on what the unleashed monster achieves.
- [ ] UI: level-up moment, XP bar, pet stable screen, pet detail, hatch choice screen with comparison.
- [ ] Data tooling: wipe and edit a test profile from developer commands.

**Acceptance tests**

- Progress survives leaving, rejoining, and a server shutdown.
- Two servers cannot load the same profile at once.
- A maxed test profile measures no more than about 1.5 times the combat power of a new profile.

**Performance gate:** 40 active pets plus the Phase 8 gate stays within budget.

**Implementation notes**

_None yet._

---

## Phase 10: Classes

**Status:** Not Started

**Goal:** Four distinct roles that make groups stronger than individuals.

**Tasks**

- [ ] Ability framework: data-defined abilities with cooldown, cost, targeting shape, effects, and client prediction.
- [ ] Status effect system: slow, stun, shield, heal over time, taunt, damage amplification, with stacking rules.
- [ ] Knight: block or taunt, gap closer.
- [ ] Hunter: ranged basic attack, weak-point bonus, trap or snare.
- [ ] Mage: area damage, crowd control.
- [ ] Healer: targeted heal, area heal or shield, a damage option so solo play is viable.
- [ ] Targeting: mouse aim with generous hit shapes for all abilities (auto-aim assist for touch and gamepad in the Phase 13B mobile pass).
- [ ] First-join class picker, defaulting to Knight.
- [ ] Class station in each base's spawn area. Switching rules: switch at the class station or on the respawn screen, including mid-round; no switching in the field.
- [ ] Ability unlocks follow class level: each class has its full core kit by class level 10.
- [ ] Class-specific level milestone looks (stub visuals), driven by class level.
- [ ] Healing and support credit: XP and assists for heals and shields.
- [ ] UI: class picker, ability bar per class, status effect icons.
- [ ] Balance pass using server-side bots of each class.

**Acceptance tests**

- A mixed group of four clears a centre camp measurably faster than four of the same class.
- A Healer earns comparable XP to a damage class over a full round.
- Every ability is usable without pixel-precise aiming.

**Performance gate:** 40 server-side bots using abilities at realistic rates plus the Phase 9 gate stays within budget.

**Implementation notes**

_None yet._

---

## Phase 11: Balance, anti-snowball, and telemetry

**Status:** Not Started

**Goal:** Rounds that swing back and forth and then resolve, measured with data.

**Tasks**

- [ ] Telemetry events per Appendix B, sent to Roblox analytics and to a custom sink for round-level analysis.
- [ ] Team fill: joiners go to the smaller team, then the weaker team by strength (Phase 2), then the losing team; minion waves scale up for a team that is short on players or strength.
- [ ] Strength equalisers driven by `TeamService.balance()`: small, capped adjustments for the weaker team (for example minion wave strength, respawn time, objective rewards), scaled by the strength gap. They nudge matches towards even and never let a far weaker player beat a far stronger one alone.
- [ ] Escalation: wave strength grows over the round and siege minions appear after a set time so rounds end.
- [ ] Fading comeback help: defender bonuses are strong early and decay after a set time.
- [ ] Power score per player (active class level, active pet) for bounty and underdog logic; this is the same value as `TeamService.powerOf`, so team strength and individual power agree.
- [ ] Bounties: high power score or kill streak marks a player and adds a reward for defeating them.
- [ ] Underdog bonus: attackers deal extra damage to a target in proportion to the power gap, capped (Appendix A).
- [ ] Full, unsplit assist rewards.
- [ ] Round payout: contribution-based, losing team receives most of the winner's amount, bonus for long and close rounds, bonus for staying to the end.
- [ ] Leaver handling and idle detection.
- [ ] Neutral jungle boss on a timer as a planned swing moment.
- [ ] Bot-versus-bot overnight simulation to tune numbers before human tests, run headless under Lune on the pure simulation modules (see section 2) via a `make` target.
- [ ] Balance dashboard: round length distribution, first-guardian win rate, front-line reversals per round, class pick and win rates.

**Acceptance tests**

- Median round length is 20 to 30 minutes.
- The team that kills the first guardian wins 55 to 60 percent of rounds.
- A group of three new players can defeat one maxed player.
- In bot simulation, a team holding 55 percent of total strength wins between 50 and 65 percent of rounds (starting target: equalisers help the weaker team without erasing the stronger team's edge).

**Performance gate:** Telemetry adds no measurable frame cost; full regression load test passes.

**Implementation notes**

_None yet._

---

## Phase 12: Gold, cosmetics, and monetization

**Status:** Not Started

**Goal:** A cosmetic economy that funds the game without affecting fairness.

**Tasks**

- [ ] Gold earning from play, with rates in config.
- [ ] Cosmetic catalogue format: weapon skins, armour skins, pet skins, trails, kill effects, emotes, titles, each with rarity and price.
- [ ] Cosmetic rendering on players and pets with a strict per-item performance budget.
- [ ] Level milestone looks for each class (free, show real strength).
- [ ] Shop screen: featured items, categories, preview on the player's own character, purchase flow.
- [ ] Inventory and loadout screen.
- [ ] Robux gold packs as developer products with an idempotent receipt handler and purchase history.
- [ ] Game passes that do not affect power (for example, extra cosmetic loadout slots).
- [ ] Daily login reward and daily quests paying gold.
- [ ] Policy compliance: check regional restrictions through the platform policy service; no paid random items for restricted players; clear pricing.
- [ ] Economy telemetry: sources and sinks of gold, conversion, revenue per user.
- [ ] Unit tests proving no cosmetic or purchase alters the stat function or the rate or ceiling of any stat, including the XP earn rate. (There is no paid XP boost; free time-limited XP events are a Phase 14 live-ops tool.)

**Acceptance tests**

- A purchase interrupted by a disconnect is granted exactly once on rejoin.
- Every cosmetic renders correctly on all four classes and on the low-end PC.
- A fully cosmetic-equipped profile has identical stats to a bare one.

**Performance gate:** 40 players in the heaviest cosmetics plus the regression load test stays within budget.

**Implementation notes**

_None yet._

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
