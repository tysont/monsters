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
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)
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

export type Entry = {
	combatant: Damage.Combatant,
	kind: "player" | "npc",
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
}

local CombatService = {
	name = "CombatService",
	dependencies = { "TeamService", "CharacterService", "RoundService" },
	-- (victimId, killerId, assistIds)
	killed = Signal.new() :: Signal.Signal<number, number, { number }>,
	-- (targetId, sourceId, amount)
	damaged = Signal.new() :: Signal.Signal<number, number, number>,
	-- Class level of a player for the stat function. Phase 9 replaces this with real levels.
	classLevelOf = function(_player: Player): number
		return 1
	end,
	-- Folders whose parts block line of sight for melee (map walls, gym walls).
	losBlockers = {} :: { Instance },
}

local entries: { [number]: Entry } = {}
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
	end
end

function CombatService.unregister(id: number)
	entries[id] = nil
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

-- Applies one hit through the damage pipeline and tells clients about it.
function CombatService.applyHit(
	sourceId: number,
	targetId: number,
	amount: number,
	kind: string,
	knockback: Vector3?,
	at: number?
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
	end
	if target.onHit then
		target.onHit(result, push)
	end
	CombatService.damaged:fire(targetId, sourceId, result.amount)

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
	})

	if result.killed then
		CombatService.unregister(targetId)
		Net.fireAllClients(Remotes.CombatKill, { killer = sourceId, victim = targetId, assists = result.assists })
		CombatService.killed:fire(targetId, sourceId, result.assists)
	end
	return result
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
	for id, entry in entries do
		if
			id ~= attacker.combatant.id
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
	end
	local tolerance = if attacker.kind == "player" then config().rangeTolerance else 0
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

-- Damages every hostile within `radius` of `center` (monster area attacks). Positions are read
-- now; invulnerability is judged at `at` (the impact time).
function CombatService.areaHit(source: Entry, center: Vector3, radius: number, amount: number, at: number): { number }
	local hit: { number } = {}
	for id, entry in entries do
		if entry.combatant.alive and Damage.hostile(source.combatant.team, entry.combatant.team) then
			local p = entry.position()
			if p then
				local away = Vector3.new(p.X - center.X, 0, p.Z - center.Z)
				if away.Magnitude - entry.radius <= radius then
					local push = if away.Magnitude > 1e-3
						then away.Unit * Tuning.get("knockback") * 1.5
						else Vector3.zero
					local result = CombatService.applyHit(source.combatant.id, id, amount, "area", push, at)
					if result and result.applied then
						table.insert(hit, id)
					end
				end
			end
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
	local bestDistance = range
	for id, other in entries do
		if
			id ~= entry.combatant.id
			and other.combatant.alive
			and Damage.hostile(entry.combatant.team, other.combatant.team)
		then
			local p = other.position()
			if p then
				local d = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z).Magnitude
				if d <= bestDistance then
					best, bestDistance = other, d
				end
			end
		end
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

	local stats = Stats.compute(config().knight, CombatService.classLevelOf(player))
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
	if entry == nil or not entry.combatant.alive or not inputAllowed() then
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
	local entry = entries[player.UserId]
	if entry == nil or not entry.combatant.alive or not inputAllowed() then
		return
	end
	local t = now()
	if not Melee.cooldownReady(entry.lastDodgeAt, t, Tuning.get("dodgeCooldown"), config().cooldownTolerance) then
		return
	end
	entry.lastDodgeAt = t
	-- The dodge started on the client about half a ping before it arrived here.
	local started = t - math.clamp(player:GetNetworkPing() / 2, 0, config().maxRewind)
	entry.combatant.invulnerableUntil = started + Tuning.get("iframes")
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
	Net.onServerEvent(Remotes.CombatAttack, onAttack)
	Net.onServerEvent(Remotes.CombatDodge, function(player: Player)
		onDodge(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
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
		for _, entry in entries do
			local p = entry.position()
			if p then
				History.record(entry.history, t, p.X, p.Y, p.Z)
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
