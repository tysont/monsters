--!strict
-- Data-driven NPCs: each NPC is a row of plain values on the server, with no Humanoid or physics.
-- Clients render them from packed snapshots (Shared.Combat.NpcCodec) at 10 Hz. Minions have their
-- own struct-of-arrays service (MinionService).
--
-- Kinds:
--   dummy    stands still; heals to full after 3 s without damage
--   weak     chases the nearest hostile and pokes it; dies in one to three hits
--   bot      a server-side bot with a team: walks to the nearest hostile and swings using the
--            same melee path as players
--   lanebot  load-harness bot that pushes a lane (Phase 5)
--   custom   a row driven by another service through `spawnCustom` (monsters: MonsterService).
--            Its `label` (the monster definition ID) is what clients see as the kind.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local LanePath = require(ReplicatedStorage.Shared.Map.LanePath)
local Map = require(ReplicatedStorage.Shared.Map)
local Melee = require(ReplicatedStorage.Shared.Combat.Melee)
local Minions = require(ReplicatedStorage.Shared.Combat.Minions)
local Net = require(ReplicatedStorage.Shared.Net)
local NpcCodec = require(ReplicatedStorage.Shared.Combat.NpcCodec)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Stats = require(ReplicatedStorage.Shared.Combat.Stats)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CombatService = require("./CombatService")
local GymService = require("./GymService")
local RoundService = require("./RoundService")

local TICK_HZ = 10
local SNAPSHOT_MAX_BYTES = 900
local KNOCKBACK_DECAY = 8
local DUMMY_RESET_SECONDS = 3
local BOT_AGGRO = 400
local BOT_ATTACK_RANGE = 5
local BOT_RESPAWN_SECONDS = 3
local BOT_RADIUS = 1.5
local BOT_SPEED = 16
local DESPAWN_DELAY = 0.5

local S = NpcCodec.States

export type Kind = "dummy" | "weak" | "bot" | "lanebot" | "custom"

export type Row = {
	id: number,
	kind: Kind,
	-- What clients see as the kind (custom rows: the monster definition ID).
	label: string,
	team: number?,
	x: number,
	z: number,
	yaw: number,
	-- Knockback velocity, decaying.
	vx: number,
	vz: number,
	state: number,
	stateEndsAt: number,
	lastAttackAt: number?,
	entry: CombatService.Entry,
	speed: number,
	-- Pushed by knockback.
	pushable: boolean,
	-- Extra 0 to 1 value replicated in snapshots (a monster's stagger bar).
	aux: number,
	-- Body size multiplier for clients.
	scale: number?,
	-- Survives NpcService.clear() (structures).
	persistent: boolean,
	-- Custom rows: called at 10 Hz while the round allows input.
	tick: ((row: Row, t: number, dt: number) -> ())?,
	-- Where a bot respawns.
	home: Vector3,
	spawnedAt: number,
	firstHitAt: number?,
	hits: number,
	alive: boolean,
	-- Lane bots (load harness): the lane they push, their distance along it, next dodge time.
	lane: Map.LaneId?,
	distance: number,
	nextDodgeAt: number,
}

export type CustomSpawn = {
	label: string,
	position: Vector3,
	team: number?,
	maxHealth: number,
	radius: number,
	speed: number,
	damage: number,
	defence: number,
	pushable: boolean,
	persistent: boolean,
	-- Body size multiplier for clients (nil for 1).
	scale: number?,
	tick: (row: Row, t: number, dt: number) -> (),
	-- Called after the row takes a hit (after the shared knockback handling).
	onHit: ((row: Row, result: Damage.Result) -> ())?,
}

local NpcService = {
	name = "NpcService",
	dependencies = { "CombatService", "GymService", "RoundService" },
	-- Average seconds per server frame spent ticking and snapshotting NPCs over the last second
	-- (DebugStatsService reports it).
	averageCost = 0,
}

local rows: { [number]: Row } = {}
-- Bumped by clear() so pending bot respawns from before the clear are dropped.
local clearGeneration = 0
local nextId = 1
local tickCost = 0
local tickFrames = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function enemyConfig(kind: Kind): Config.EnemyConfig
	local enemies = Config.get().combat.enemies :: any
	return enemies[kind]
end

local function spawnEvent(row: Row): Remotes.NpcSpawnEvent
	return {
		id = row.id,
		kind = row.label,
		team = row.team,
		maxHealth = row.entry.combatant.maxHealth,
		radius = row.entry.radius,
		scale = row.scale,
	}
end

local despawn: (id: number) -> ()

local function reportKill(row: Row, killerId: number)
	local killer = CombatService.entry(killerId)
	local player = killer and killer.player
	if player == nil or not DebugAccess.canView(player) or row.kind == "bot" or row.persistent then
		return
	end
	local seconds = if row.firstHitAt then now() - (row.firstHitAt :: number) else 0
	Net.fireClient(
		Remotes.DevMessage,
		player,
		`TTK {row.label}: {row.hits} hit(s), {string.format("%.2f", seconds)} s from first hit`
	)
end

local function allocateId(): number
	for _ = 1, 65535 do
		local id = nextId
		nextId = nextId % 65535 + 1
		if rows[id] == nil then
			return id
		end
	end
	error("no free NPC IDs")
end

type Stats = { maxHealth: number, damage: number, radius: number, speed: number, power: number, defence: number }

local function create(
	kind: Kind,
	label: string,
	position: Vector3,
	team: number?,
	stats: Stats,
	pushable: boolean,
	persistent: boolean
): Row
	local id = allocateId()
	local row: Row
	local combatant = Damage.newCombatant(-id, team, stats.maxHealth, stats.defence)
	local entry: CombatService.Entry = {
		combatant = combatant,
		kind = "npc",
		player = nil,
		radius = stats.radius,
		damage = stats.damage,
		power = stats.power,
		history = CombatService.newHistory(),
		position = function(): Vector3?
			return Vector3.new(row.x, 2.5, row.z)
		end,
		onHit = function(_result: Damage.Result, knockback: Vector3)
			row.hits += 1
			row.firstHitAt = row.firstHitAt or now()
			if row.pushable then
				row.vx += knockback.X
				row.vz += knockback.Z
			end
		end,
	}
	row = {
		id = id,
		kind = kind,
		label = label,
		team = team,
		x = position.X,
		z = position.Z,
		yaw = 0,
		vx = 0,
		vz = 0,
		state = S.idle,
		stateEndsAt = 0,
		lastAttackAt = nil,
		entry = entry,
		speed = stats.speed,
		pushable = pushable,
		aux = 0,
		persistent = persistent,
		scale = nil,
		tick = nil,
		home = position,
		spawnedAt = now(),
		firstHitAt = nil,
		hits = 0,
		alive = true,
		lane = nil,
		distance = 0,
		nextDodgeAt = 0,
	}
	rows[id] = row
	return row
end

local function publish(row: Row)
	CombatService.register(row.entry)
	Net.fireAllClients(Remotes.NpcSpawn, spawnEvent(row))
end

-- Spawns an NPC at a world position. `team` is nil for monsters.
function NpcService.spawn(kind: Kind, position: Vector3, team: number?): number
	local stats: Stats
	if kind == "bot" or kind == "lanebot" then
		local s = Stats.compute(Config.get().combat.knight, 1)
		stats = {
			maxHealth = s.maxHealth,
			damage = s.damage,
			radius = BOT_RADIUS,
			speed = BOT_SPEED,
			power = s.power,
			defence = 0,
		}
	else
		local c = enemyConfig(kind)
		stats = {
			maxHealth = math.max(1, math.floor(c.maxHealth * Tuning.get("enemyHealthScale") + 0.5)),
			damage = c.damage,
			radius = c.radius,
			speed = c.speed,
			power = 1,
			defence = 0,
		}
	end
	-- Stationary NPCs (the target dummy) are not pushed around.
	local row = create(kind, kind, position, team, stats, stats.speed > 0, false)
	publish(row)
	return row.id
end

-- Spawns a row driven by another service. Returns the row.
function NpcService.spawnCustom(options: CustomSpawn): Row
	local row = create("custom", options.label, options.position, options.team, {
		maxHealth = options.maxHealth,
		damage = options.damage,
		radius = options.radius,
		speed = options.speed,
		power = 1,
		defence = options.defence,
	}, options.pushable, options.persistent)
	row.tick = options.tick
	row.scale = options.scale
	local onHit = options.onHit
	if onHit then
		local shared = row.entry.onHit :: (Damage.Result, Vector3) -> ()
		row.entry.onHit = function(result: Damage.Result, knockback: Vector3)
			shared(result, knockback)
			onHit(row, result)
		end
	end
	publish(row)
	return row
end

function NpcService.row(id: number): Row?
	return rows[id]
end

despawn = function(id: number)
	local row = rows[id]
	if row == nil then
		return
	end
	rows[id] = nil
	CombatService.unregister(-id)
	Net.fireAllClients(Remotes.NpcDespawn, id)
end

function NpcService.despawn(id: number)
	despawn(id)
end

-- Removes every NPC except persistent ones (structures). Returns how many were removed.
function NpcService.clear(): number
	clearGeneration += 1
	local count = 0
	for id, row in rows do
		if not row.persistent then
			despawn(id)
			count += 1
		end
	end
	return count
end

function NpcService.count(kind: Kind?): number
	local n = 0
	for _, row in rows do
		if kind == nil or row.kind == kind then
			n += 1
		end
	end
	return n
end

local function face(row: Row, tx: number, tz: number)
	local dx, dz = tx - row.x, tz - row.z
	if dx * dx + dz * dz > 1e-4 then
		-- Yaw 0 faces -z (Roblox forward).
		row.yaw = math.atan2(-dx, -dz)
	end
end

local function facing(row: Row): Vector3
	return Vector3.new(-math.sin(row.yaw), 0, -math.cos(row.yaw))
end

local function moveToward(row: Row, tx: number, tz: number, stopAt: number, dt: number)
	local dx, dz = tx - row.x, tz - row.z
	local d = math.sqrt(dx * dx + dz * dz)
	face(row, tx, tz)
	if d > stopAt then
		local step = math.min(row.speed * dt, d - stopAt)
		row.x += dx / d * step
		row.z += dz / d * step
		row.state = S.move
	elseif row.state == S.move then
		row.state = S.idle
	end
end

local function targetPosition(target: CombatService.Entry): Vector3?
	return target.position()
end

local function tickWeak(row: Row, t: number, dt: number)
	local c = enemyConfig("weak")
	local target, distance = CombatService.nearestHostile(row.entry, c.aggroRange)
	if target == nil then
		row.state = S.idle
		return
	end
	local p = targetPosition(target) :: Vector3
	moveToward(row, p.X, p.Z, c.attackRange * 0.8, dt)
	if distance - target.radius <= c.attackRange and Melee.cooldownReady(row.lastAttackAt, t, c.attackCooldown, 0) then
		row.lastAttackAt = t
		row.state = S.attack
		local away = Vector3.new(p.X - row.x, 0, p.Z - row.z)
		local push = if away.Magnitude > 1e-3 then away.Unit * 10 else Vector3.zero
		CombatService.applyHit(row.entry.combatant.id, target.combatant.id, c.damage, "melee", push)
	end
end

local function tickBot(row: Row, t: number, dt: number)
	local target, distance = CombatService.nearestHostile(row.entry, BOT_AGGRO)
	if target == nil then
		row.state = S.idle
		return
	end
	local p = targetPosition(target) :: Vector3
	moveToward(row, p.X, p.Z, BOT_ATTACK_RANGE * 0.7, dt)
	-- A little random delay so 40 bots do not all swing on the same frame.
	local cooldown = Tuning.get("attackCooldown") + math.random() * 0.2
	if distance - target.radius <= BOT_ATTACK_RANGE and Melee.cooldownReady(row.lastAttackAt, t, cooldown, 0) then
		row.lastAttackAt = t
		row.state = S.attack
		CombatService.meleeSwing(row.entry, facing(row), 0, t)
		-- Clients play the swing on the bot's model.
		Net.fireAllClients(Remotes.CombatSwing, row.entry.combatant.id)
	end
end

-- Load-harness bot: pushes its lane like a minion, fights anything hostile nearby with the
-- player melee path, and dodges now and then through the player dodge path.
local LANEBOT_AGGRO = 22
local LANEBOT_DODGE_EVERY = 4

local function tickLaneBot(row: Row, t: number, dt: number)
	local path = Map.get().laneById[row.lane :: Map.LaneId]
	local team = row.team :: number
	local target, distance = CombatService.nearestHostile(row.entry, LANEBOT_AGGRO)
	if target then
		local p = targetPosition(target) :: Vector3
		moveToward(row, p.X, p.Z, BOT_ATTACK_RANGE * 0.7, dt)
		local cooldown = Tuning.get("attackCooldown") + math.random() * 0.2
		if distance - target.radius <= BOT_ATTACK_RANGE and Melee.cooldownReady(row.lastAttackAt, t, cooldown, 0) then
			row.lastAttackAt = t
			row.state = S.attack
			CombatService.meleeSwing(row.entry, facing(row), 0, t)
		end
		if t >= row.nextDodgeAt then
			row.nextDodgeAt = t + LANEBOT_DODGE_EVERY * (0.5 + math.random())
			CombatService.dodge(row.entry, t)
		end
		row.distance = LanePath.project(path, { x = row.x, z = row.z })
		return
	end
	local dir = Minions.direction(team)
	row.distance = math.clamp(row.distance + dir * row.speed * 0.6 * dt, 0, path.length)
	if Minions.reachedEnd(row.distance, path.length, team) then
		-- Past the lane: march on the enemy Titan.
		local base = Map.get().bases[3 - team].center
		moveToward(row, base.x, base.z, 8, dt)
		return
	end
	local p = LanePath.pointAt(path, row.distance)
	moveToward(row, p.x, p.z, 0.5, dt)
end

local function laneStart(lane: Map.LaneId, team: number): Vector3
	local path = Map.get().laneById[lane]
	local d = Minions.startDistance(path.length, team, 0.02)
	local p = LanePath.pointAt(path, d)
	return Vector3.new(p.x, 0, p.z)
end

-- Spawns a load-harness bot at the start of `lane` for `team`. Respawns there when defeated.
function NpcService.spawnLaneBot(team: number, lane: Map.LaneId): number
	local id = NpcService.spawn("lanebot", laneStart(lane, team), team)
	local row = rows[id]
	row.lane = lane
	local path = Map.get().laneById[lane]
	row.distance = Minions.startDistance(path.length, team, 0.02)
	return id
end

-- Pushes overlapping NPCs apart. Rows that cannot be pushed (monsters, the dummy) take no part:
-- other NPCs pass through them, as players do (monster models do not collide).
local function separate(list: { Row })
	for i = 1, #list do
		local a = list[i]
		if a.pushable then
			for j = i + 1, #list do
				local b = list[j]
				local dx, dz = b.x - a.x, b.z - a.z
				local min = a.entry.radius + b.entry.radius
				local d2 = dx * dx + dz * dz
				if b.pushable and d2 < min * min and d2 > 1e-6 then
					local d = math.sqrt(d2)
					local push = (min - d) / 2
					a.x -= dx / d * push
					a.z -= dz / d * push
					b.x += dx / d * push
					b.z += dz / d * push
				end
			end
		end
	end
end

local function inGym(row: Row): boolean
	local x, z = GymService.clamp(row.home.X, row.home.Z, 0)
	return x == row.home.X and z == row.home.Z
end

local function tick(dt: number)
	local t = now()
	local paused = not Round.inputAllowed(RoundService.state().phase)
	local list: { Row } = {}
	for _, row in rows do
		if row.alive then
			table.insert(list, row)
			if not paused then
				if row.kind == "weak" then
					tickWeak(row, t, dt)
				elseif row.kind == "custom" then
					(row.tick :: (Row, number, number) -> ())(row, t, dt)
				elseif row.kind == "bot" then
					tickBot(row, t, dt)
				elseif row.kind == "lanebot" then
					tickLaneBot(row, t, dt)
				elseif row.kind == "dummy" then
					local c = row.entry.combatant
					if c.health < c.maxHealth and t - c.lastDamagedAt >= DUMMY_RESET_SECONDS then
						c.health = c.maxHealth
						row.firstHitAt, row.hits = nil, 0
					end
				end
			end
			-- Knockback, decaying.
			row.x += row.vx * dt
			row.z += row.vz * dt
			local decay = math.max(0, 1 - KNOCKBACK_DECAY * dt)
			row.vx *= decay
			row.vz *= decay
		end
	end
	separate(list)
	if GymService.enabled() then
		for _, row in list do
			if row.lane == nil and inGym(row) then
				row.x, row.z = GymService.clamp(row.x, row.z, row.entry.radius)
			end
		end
	end
end

-- Each client gets only the NPCs within the interest radius of its character (like minions);
-- NPCs further away keep their last position on that client until they come back into range.
local function snapshot()
	local entities: { NpcCodec.Entity } = {}
	for _, row in rows do
		local c = row.entry.combatant
		table.insert(entities, {
			id = row.id,
			x = row.x,
			z = row.z,
			yaw = row.yaw,
			health = c.health / c.maxHealth,
			state = row.state,
			aux = row.aux,
		})
	end
	local t = now()
	local radius = Config.get().minions.interestRadius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local px, pz = root.Position.X, root.Position.Z
			local near: { NpcCodec.Entity } = {}
			for _, e in entities do
				local dx, dz = e.x - px, e.z - pz
				if dx * dx + dz * dz <= radius * radius then
					table.insert(near, e)
				end
			end
			for _, chunk in NpcCodec.pack(t, near, SNAPSHOT_MAX_BYTES) do
				Net.fireClient(Remotes.NpcSnapshot, player, chunk)
			end
		end
	end
end

function NpcService.init(_self: typeof(NpcService))
	Net.onServerEvent(Remotes.NpcReady, function(player: Player)
		for _, row in rows do
			Net.fireClient(Remotes.NpcSpawn, player, spawnEvent(row))
		end
	end)

	CombatService.killed:connect(function(victimId: number, killerId: number)
		if victimId >= 0 then
			return
		end
		local row = rows[-victimId]
		if row == nil then
			return
		end
		row.alive = false
		reportKill(row, killerId)
		local generation = clearGeneration
		task.delay(DESPAWN_DELAY, function()
			despawn(row.id)
			if row.kind == "bot" or row.kind == "lanebot" then
				task.delay(BOT_RESPAWN_SECONDS, function()
					-- Skip if NPCs were cleared meanwhile.
					if clearGeneration ~= generation then
						return
					end
					if row.kind == "lanebot" then
						NpcService.spawnLaneBot(row.team :: number, row.lane :: Map.LaneId)
					else
						NpcService.spawn("bot", row.home, row.team)
					end
				end)
			end
		end)
	end)

	local accumulator = 0
	local frames = 0
	local window = 0
	RunService.Heartbeat:Connect(function(dt: number)
		frames += 1
		window += dt
		accumulator += dt
		if accumulator >= 1 / TICK_HZ then
			local started = os.clock()
			tick(accumulator)
			snapshot()
			tickCost += os.clock() - started
			accumulator = 0
		end
		if window >= 1 then
			tickFrames = frames
			NpcService.averageCost = if tickFrames > 0 then tickCost / tickFrames else 0
			tickCost, frames, window = 0, 0, 0
		end
	end)
end

return NpcService
