--!strict
-- Server-authoritative combat. Every combatant (player characters and NPC rows) is registered
-- here; every hit goes through Shared.Combat.Damage via `applyHit`.
--
--   Attacks: the client sends only a facing direction. The server checks the round phase and
--   cooldown, rewinds target positions by the attacker's ping (capped), selects targets by range
--   and arc (Shared.Combat.Melee), checks line of sight, and applies damage.
--   Dodges: the client moves its own character; the server grants invulnerability, starting half
--   a ping before the request arrived.
--   Health: the server owns it and mirrors it into Humanoid.Health. The default Health script
--   (passive regeneration) is removed; regeneration here is out-of-combat and at-base only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local History = require(ReplicatedStorage.Shared.Combat.History)
local Map = require(ReplicatedStorage.Shared.Map)
local Melee = require(ReplicatedStorage.Shared.Combat.Melee)
local Minions = require(ReplicatedStorage.Shared.Combat.Minions)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)
local SpatialGrid = require(ReplicatedStorage.Shared.Combat.SpatialGrid)
local Stats = require(ReplicatedStorage.Shared.Combat.Stats)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CharacterService = require("./CharacterService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

-- Position samples per second kept for rewinding, and how many.
local HISTORY_HZ = 20
local HISTORY_SAMPLES = 20
local REGEN_INTERVAL = 0.5
-- Clients farther than this from a hit do not receive it (they cannot see it).
local HIT_BROADCAST_RANGE = 250
local PLAYER_RADIUS = 1.5
-- Spatial grid cell size; queries visit the cells overlapping a circle.
local GRID_CELL = 16
-- Largest body radius among combatants, added to grid query radii.
local MAX_RADIUS = 5
-- How far a target can move during the maximum rewind (added to melee query radius).
local REWIND_SLACK = 6

export type Entry = {
	combatant: Damage.Combatant,
	kind: "player" | "npc" | "minion",
	player: Player?,
	-- Body radius for hit tests.
	radius: number,
	-- Base outgoing damage before the target's defence.
	damage: number,
	power: number,
	history: History.History,
	position: () -> Vector3?,
	lastAttackAt: number?,
	lastDodgeAt: number?,
	-- NPC hook: called after this combatant takes a hit.
	onHit: ((result: Damage.Result, knockback: Vector3) -> ())?,
	-- Whether this combatant's defeat goes to every client's kill feed (false for minions).
	announceKills: boolean?,
	-- Whether defeating it counts towards team kills (false for minions and structures).
	scoresKill: boolean?,
	-- Lane gating: true while this structure cannot be damaged yet. Gated combatants are skipped
	-- when choosing targets.
	gated: boolean?,
	-- Multiplier on damage taken (a monster's stagger window), 1 or nil for none.
	vulnerability: number?,
	-- Multiplier on damage taken from a given source, e.g. 0 from the front of an armoured
	-- monster.
	damageFilter: ((source: Entry?) -> number)?,
}

local CombatService = {
	name = "CombatService",
	dependencies = { "TeamService", "CharacterService", "RoundService" },
	-- (victimId, killerId, assistIds, victim)
	killed = Signal.new() :: Signal.Signal<number, number, { number }, Entry>,
	-- (targetId, sourceId, amount)
	damaged = Signal.new() :: Signal.Signal<number, number, number>,
	-- (player, kind, amount): proximity credit, e.g. a nearby minion died. XP from Phase 9,
	-- gold from Phase 12.
	credited = Signal.new() :: Signal.Signal<Player, string, number>,
	-- Class level of a player for the stat function. Phase 9 replaces this with real levels.
	classLevelOf = function(_player: Player): number
		return 1
	end,
	-- Whether a player may dodge right now (EggService: egg carriers cannot).
	canDodge = function(_player: Player): boolean
		return true
	end,
	-- Folders whose parts block line of sight for melee (map walls, gym walls).
	losBlockers = {} :: { Instance },
}

local entries: { [number]: Entry } = {}
-- Every registered combatant by position, refreshed at HISTORY_HZ.
local grid = SpatialGrid.new(GRID_CELL)
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Include

local function now(): number
	return workspace:GetServerTimeNow()
end

local function config()
	return Config.get().combat
end

function CombatService.entry(id: number): Entry?
	return entries[id]
end

function CombatService.entries(): { [number]: Entry }
	return entries
end

function CombatService.register(entry: Entry)
	entries[entry.combatant.id] = entry
	local p = entry.position()
	if p then
		History.record(entry.history, now(), p.X, p.Y, p.Z)
		SpatialGrid.update(grid, entry.combatant.id, p.X, p.Z)
	end
end

function CombatService.unregister(id: number)
	entries[id] = nil
	SpatialGrid.remove(grid, id)
end

-- Moves a combatant in the spatial grid now (callers that teleport or spawn mid-tick).
function CombatService.moved(entry: Entry)
	local p = entry.position()
	if p then
		SpatialGrid.update(grid, entry.combatant.id, p.X, p.Z)
	end
end

-- Calls `visit(entry)` for every combatant in grid cells overlapping the circle (any team, not
-- distance-checked). For cheap neighbourhood work such as minion spacing.
function CombatService.allNear(x: number, z: number, range: number, visit: (Entry) -> ())
	SpatialGrid.query(grid, x, z, range, function(id)
		local entry = entries[id]
		if entry then
			visit(entry)
		end
	end)
end

-- Calls `visit(entry, distance)` for each living combatant hostile to `team` within `range` of
-- (x, z), using the spatial grid. Distance is to the combatant's centre.
function CombatService.hostilesNear(team: number?, x: number, z: number, range: number, visit: (Entry, number) -> ())
	SpatialGrid.query(grid, x, z, range + MAX_RADIUS, function(id)
		local entry = entries[id]
		if entry and entry.combatant.alive and Damage.hostile(team, entry.combatant.team) then
			local p = entry.position()
			if p then
				local dx, dz = p.X - x, p.Z - z
				local d = math.sqrt(dx * dx + dz * dz)
				if d <= range + entry.radius then
					visit(entry, d)
				end
			end
		end
	end)
end

function CombatService.newHistory(): History.History
	return History.new(HISTORY_SAMPLES)
end

-- Whether line of sight between two points is clear of walls.
local function clearLine(from: Vector3, to: Vector3): boolean
	if #CombatService.losBlockers == 0 then
		return true
	end
	losParams.FilterDescendantsInstances = CombatService.losBlockers
	local a = Vector3.new(from.X, 2, from.Z)
	local b = Vector3.new(to.X, 2, to.Z)
	return workspace:Raycast(a, b - a, losParams) == nil
end

local function playersNear(position: Vector3, range: number): { Player }
	local list: { Player } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= range then
			table.insert(list, player)
		end
	end
	return list
end

local function addUnique(list: { Player }, player: Player?)
	if player and not table.find(list, player) then
		table.insert(list, player)
	end
end

-- Heavy knockback is simulated by the target's own client (it owns its character). The server
-- remembers where the target was and, once the knockdown is over, pulls the character back if it
-- ended farther away than the push plus walking could explain.
type KnockbackCheck = { from: Vector3, checkAt: number, allowed: number }
local knockbackChecks: { [Entry]: KnockbackCheck } = {}
local KNOCKDOWN_SECONDS = 1.2

local function watchKnockback(target: Entry, push: Vector3)
	local p = target.position()
	if p == nil then
		return
	end
	local existing = knockbackChecks[target]
	knockbackChecks[target] = {
		from = if existing then existing.from else p,
		checkAt = now() + KNOCKDOWN_SECONDS,
		allowed = (if existing then existing.allowed else 0)
			+ push.Magnitude * 0.45
			+ Map.get().walkSpeed * KNOCKDOWN_SECONDS * 1.5
			+ 4,
	}
end

local function validateKnockbacks(t: number)
	for entry, check in knockbackChecks do
		if t >= check.checkAt then
			knockbackChecks[entry] = nil
			local p = entry.position()
			local character = entry.player and entry.player.Character
			if p and character and entry.combatant.alive then
				local offset = Vector3.new(p.X - check.from.X, 0, p.Z - check.from.Z)
				if offset.Magnitude > check.allowed then
					local fixed = check.from + offset.Unit * check.allowed
					character:PivotTo(CFrame.new(fixed.X, p.Y, fixed.Z) * character:GetPivot().Rotation)
					warn(`[Combat] knockback end position corrected for {character.Name}`)
				end
			end
		end
	end
end

-- Applies one hit through the damage pipeline and tells clients about it.
function CombatService.applyHit(
	sourceId: number,
	targetId: number,
	amount: number,
	kind: string,
	knockback: Vector3?,
	at: number?,
	heavy: boolean?
): Damage.Result?
	local target = entries[targetId]
	if target == nil then
		return nil
	end
	local source = entries[sourceId]
	local sourceTeam = if source then source.combatant.team else nil

	if target.player then
		local character = target.player.Character
		target.combatant.protected = character ~= nil and character:FindFirstChildOfClass("ForceField") ~= nil
	end

	local result = Damage.apply(target.combatant, {
		sourceId = sourceId,
		sourceTeam = sourceTeam,
		amount = amount,
		kind = kind,
		now = at or now(),
		modifiers = {
			target.vulnerability or 1,
			if target.damageFilter then target.damageFilter(source) else 1,
		},
	}, config().assistWindow)
	if not result.applied then
		return result
	end

	local push = knockback or Vector3.zero
	if target.player then
		local character = target.player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = target.combatant.health
		end
		if heavy and not result.killed then
			watchKnockback(target, push)
		end
	end
	if target.onHit then
		target.onHit(result, push)
	end
	CombatService.damaged:fire(targetId, sourceId, result.amount)

	-- Minion-on-minion hits send no event: health shows through snapshots, and damage numbers
	-- for every minion scuffle would be clutter and bandwidth.
	local minionOnly = target.kind == "minion" and (source == nil or source.kind == "minion")
	if not minionOnly then
		local position = target.position() or Vector3.zero
		local recipients = playersNear(position, HIT_BROADCAST_RANGE)
		addUnique(recipients, target.player)
		addUnique(recipients, source and source.player)
		Net.fireClients(Remotes.CombatHit, recipients, {
			target = targetId,
			source = sourceId,
			amount = result.amount,
			position = position,
			knockback = push,
			killed = result.killed,
			heavy = heavy == true,
		})
	end

	if result.killed then
		CombatService.unregister(targetId)
		if target.announceKills ~= false then
			Net.fireAllClients(Remotes.CombatKill, { killer = sourceId, victim = targetId, assists = result.assists })
		end
		CombatService.killed:fire(targetId, sourceId, result.assists, target)
	end
	return result
end

-- Starts a dodge for `entry` at `startedAt`: invulnerable for the tuned window. Players and bots.
function CombatService.dodge(entry: Entry, startedAt: number)
	entry.lastDodgeAt = startedAt
	entry.combatant.invulnerableUntil = startedAt + Tuning.get("iframes")
end

-- Resolves a melee swing from `attacker` facing `direction`, rewinding targets by `rewind`
-- seconds. Shared by players and bots. Returns the IDs that were hit.
function CombatService.meleeSwing(attacker: Entry, direction: Vector3, rewind: number, at: number): { number }
	local origin = attacker.position()
	if origin == nil then
		return {}
	end
	local candidates: { Melee.Candidate } = {}
	local positions: { [number]: Vector3 } = {}
	local tolerance = if attacker.kind == "player" then config().rangeTolerance else 0
	local reach = Tuning.get("attackRange") + tolerance + MAX_RADIUS + REWIND_SLACK
	SpatialGrid.query(grid, origin.X, origin.Z, reach, function(id)
		local entry = entries[id]
		if
			entry
			and id ~= attacker.combatant.id
			and entry.combatant.alive
			and Damage.hostile(attacker.combatant.team, entry.combatant.team)
		then
			local x, y, z = History.sample(entry.history, at - rewind)
			local p = if x and y and z then Vector3.new(x, y, z) else entry.position()
			if p then
				positions[id] = p
				table.insert(candidates, { id = id, position = { x = p.X, z = p.Z }, radius = entry.radius })
			end
		end
	end)
	local ids = Melee.selectTargets({ x = origin.X, z = origin.Z }, { x = direction.X, z = direction.Z }, candidates, {
		range = Tuning.get("attackRange") + tolerance,
		arc = Tuning.get("attackArc"),
		maxTargets = config().maxTargets,
	})
	local hit: { number } = {}
	for _, id in ids do
		local p = positions[id]
		if clearLine(origin, p) then
			local away = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z)
			local push = if away.Magnitude > 1e-3 then away.Unit * Tuning.get("knockback") else Vector3.zero
			local result = CombatService.applyHit(attacker.combatant.id, id, attacker.damage, "melee", push, at)
			if result and result.applied then
				table.insert(hit, id)
			end
		end
	end
	return hit
end

-- Damages every hostile to `source` whose body passes `test(x, z, radius)`, searching within
-- `bound` of (cx, cz). Knockback pushes away from (cx, cz), or along `pushDirection` if given.
-- Used by monster attack shapes (circles and cones). Invulnerability is judged at `at`.
function CombatService.shapeHit(
	source: Entry,
	cx: number,
	cz: number,
	bound: number,
	test: (x: number, z: number, radius: number) -> boolean,
	amount: number,
	knockback: number,
	heavy: boolean,
	at: number,
	pushDirection: Vector3?
): { number }
	local targets: { { entry: Entry, push: Vector3 } } = {}
	CombatService.hostilesNear(source.combatant.team, cx, cz, bound, function(entry)
		if entry.gated or entry == source then
			return
		end
		local p = entry.position() :: Vector3
		if test(p.X, p.Z, entry.radius) then
			local away = pushDirection or Vector3.new(p.X - cx, 0, p.Z - cz)
			local push = if away.Magnitude > 1e-3 then away.Unit * knockback else Vector3.zero
			table.insert(targets, { entry = entry, push = push })
		end
	end)
	local hit: { number } = {}
	for _, t in targets do
		local id = t.entry.combatant.id
		local result = CombatService.applyHit(source.combatant.id, id, amount, "monster", t.push, at, heavy)
		if result and result.applied then
			table.insert(hit, id)
		end
	end
	return hit
end

-- The nearest living hostile to `entry` within `range`, by current position.
function CombatService.nearestHostile(entry: Entry, range: number): (Entry?, number)
	local origin = entry.position()
	if origin == nil then
		return nil, math.huge
	end
	local best: Entry? = nil
	local bestDistance = math.huge
	CombatService.hostilesNear(entry.combatant.team, origin.X, origin.Z, range, function(other, d)
		if other ~= entry and not other.gated and d < bestDistance then
			best, bestDistance = other, d
		end
	end)
	if best == nil then
		return nil, math.huge
	end
	return best, bestDistance
end

local function inputAllowed(): boolean
	return Round.inputAllowed(RoundService.state().phase)
end

-- Player characters -------------------------------------------------------------------------

local function attachSword(character: Model)
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand == nil or not hand:IsA("BasePart") or character:FindFirstChild("Sword") then
		return
	end
	local sword = Instance.new("Part")
	sword.Name = "Sword"
	sword.Size = Vector3.new(0.25, 0.25, 4.4)
	sword.Color = Color3.fromRGB(200, 205, 215)
	sword.Material = Enum.Material.Metal
	sword.CanCollide = false
	sword.CanQuery = false
	sword.CanTouch = false
	sword.Massless = true
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = sword
	-- Blade extends forward from the grip.
	weld.C0 = CFrame.new(0, -hand.Size.Y / 2 + 0.1, -2.1)
	weld.Parent = sword
	sword.Parent = character
end

local function onCharacterSpawned(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		return
	end
	-- The default Health script regenerates health passively; combat regen replaces it.
	local healthScript = character:FindFirstChild("Health")
	if healthScript and healthScript:IsA("Script") then
		healthScript:Destroy()
	end

	local level = CombatService.classLevelOf(player)
	player:SetAttribute("ClassLevel", level)
	local stats = Stats.compute(config().knight, level)
	humanoid.MaxHealth = stats.maxHealth
	humanoid.Health = stats.maxHealth
	attachSword(character)

	local combatant = Damage.newCombatant(player.UserId, TeamService.teamOf(player), stats.maxHealth, stats.defence)
	local entry: Entry = {
		combatant = combatant,
		kind = "player",
		player = player,
		radius = PLAYER_RADIUS,
		damage = stats.damage,
		power = stats.power,
		history = CombatService.newHistory(),
		position = function(): Vector3?
			if root.Parent == nil then
				return nil
			end
			return root.Position
		end,
	}
	CombatService.register(entry)

	humanoid.Died:Connect(function()
		combatant.alive = false
		if entries[player.UserId] == entry then
			CombatService.unregister(player.UserId)
		end
	end)
end

local function onAttack(player: Player, request: Remotes.AttackRequest)
	local entry = entries[player.UserId]
	if entry == nil or not entry.combatant.alive or not inputAllowed() or player:GetAttribute("Launching") then
		return
	end
	local t = now()
	if not Melee.cooldownReady(entry.lastAttackAt, t, Tuning.get("attackCooldown"), config().cooldownTolerance) then
		return
	end
	local direction = Vector3.new(request.direction.X, 0, request.direction.Z)
	if direction.Magnitude < 1e-3 then
		return
	end
	entry.lastAttackAt = t

	local origin = entry.position()
	if origin then
		local others = playersNear(origin, HIT_BROADCAST_RANGE)
		local index = table.find(others, player)
		if index then
			table.remove(others, index)
		end
		Net.fireClients(Remotes.CombatSwing, others, player.UserId)
	end
	local rewind = math.clamp(player:GetNetworkPing(), 0, config().maxRewind)
	CombatService.meleeSwing(entry, direction.Unit, rewind, t)
end

local function onDodge(player: Player)
	if not CombatService.canDodge(player) then
		return
	end
	local entry = entries[player.UserId]
	if entry == nil or not entry.combatant.alive or not inputAllowed() or player:GetAttribute("Launching") then
		return
	end
	local t = now()
	if not Melee.cooldownReady(entry.lastDodgeAt, t, Tuning.get("dodgeCooldown"), config().cooldownTolerance) then
		return
	end
	-- The dodge started on the client about half a ping before it arrived here.
	local started = t - math.clamp(player:GetNetworkPing() / 2, 0, config().maxRewind)
	CombatService.dodge(entry, started)
	entry.lastDodgeAt = t
end

-- Regeneration and history ------------------------------------------------------------------

local function inOwnBase(entry: Entry): boolean
	local team = entry.combatant.team
	local p = entry.position()
	if team == nil or p == nil then
		return false
	end
	local base = Map.get().bases[team]
	if base == nil then
		return false
	end
	return math.abs(p.X - base.center.x) <= base.size.x / 2 and math.abs(p.Z - base.center.z) <= base.size.z / 2
end

local function regenerate()
	local t = now()
	local regen = config().regen
	for _, entry in entries do
		local c = entry.combatant
		if entry.kind == "player" and c.alive and c.health < c.maxHealth then
			local rate = 0
			if inOwnBase(entry) then
				rate = regen.atBasePerSecond
			elseif t - c.lastDamagedAt >= regen.outOfCombatDelay then
				rate = regen.outOfCombatPerSecond
			end
			if rate > 0 and Damage.heal(c, c.maxHealth * rate * REGEN_INTERVAL) > 0 then
				local character = entry.player and entry.player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.Health = c.health
				end
			end
		end
	end
end

function CombatService.init(_self: typeof(CombatService))
	local folder = Instance.new("Folder")
	folder.Name = Tuning.FOLDER_NAME
	folder.Parent = ReplicatedStorage

	CharacterService.characterSpawned:connect(onCharacterSpawned)

	-- Team kill counts for the HUD score strip (players and bots only, not minions), reset each
	-- round.
	CombatService.killed:connect(function(victimId: number, killerId: number, _assists: { number }, victim: Entry)
		if Minions.networkId(victimId) ~= nil or victim.scoresKill == false then
			return
		end
		local killer = entries[killerId]
		if killer == nil or killer.scoresKill == false then
			-- Kills by guardians, Titans and other monsters do not score for a team.
			return
		end
		local team = killer.combatant.team
		if team then
			local instance = TeamService.teamInstance(team)
			instance:SetAttribute("Kills", ((instance:GetAttribute("Kills") :: number?) or 0) + 1)
		end
	end)
	RoundService.roundReset:connect(function()
		for team = 1, 2 do
			TeamService.teamInstance(team):SetAttribute("Kills", 0)
		end
	end)
	Net.onServerEvent(Remotes.CombatAttack, onAttack)
	Net.onServerEvent(Remotes.CombatDodge, function(player: Player)
		onDodge(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local entry = entries[player.UserId]
		if entry then
			knockbackChecks[entry] = nil
		end
		CombatService.unregister(player.UserId)
	end)

	local sinceSample = 0
	RunService.Heartbeat:Connect(function(dt: number)
		sinceSample += dt
		if sinceSample < 1 / HISTORY_HZ then
			return
		end
		sinceSample = 0
		local t = now()
		validateKnockbacks(t)
		for _, entry in entries do
			local p = entry.position()
			if p then
				History.record(entry.history, t, p.X, p.Y, p.Z)
				SpatialGrid.update(grid, entry.combatant.id, p.X, p.Z)
			end
		end
	end)
end

function CombatService.start(_self: typeof(CombatService))
	local map = workspace:WaitForChild("Map", 10)
	local walls = map and map:FindFirstChild("Walls")
	if walls then
		table.insert(CombatService.losBlockers, walls)
	end
	while true do
		task.wait(REGEN_INTERVAL)
		regenerate()
	end
end

return CombatService
