--!strict
-- Data-driven NPCs: each NPC is a row of plain values on the server, with no Humanoid or physics.
-- Clients render them from packed snapshots (Shared.Combat.NpcCodec) at 10 Hz. Phase 5 extends
-- this to minions (struct-of-arrays, spatial grid, interest management); Phase 6 replaces the
-- throwaway slammer state machine with the monster behaviour framework.
--
-- Kinds (Phase 3 combat gym):
--   dummy    stands still; heals to full after 3 s without damage
--   weak     chases the nearest hostile and pokes it; dies in one to three hits
--   slammer  walks up, telegraphs a ground slam (circle), slams, recovers
--   bot      a server-side bot with a team: walks to the nearest hostile and swings using the
--            same melee path as players

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local Melee = require(ReplicatedStorage.Shared.Combat.Melee)
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

export type Kind = "dummy" | "weak" | "slammer" | "bot"

type Row = {
	id: number,
	kind: Kind,
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
	-- Where a bot respawns.
	home: Vector3,
	spawnedAt: number,
	firstHitAt: number?,
	hits: number,
	alive: boolean,
}

local NpcService = {
	name = "NpcService",
	dependencies = { "CombatService", "GymService", "RoundService" },
	-- Average seconds per server frame spent ticking and snapshotting NPCs over the last second
	-- (DebugStatsService reports it).
	averageCost = 0,
}

local rows: { [number]: Row } = {}
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
		kind = row.kind,
		team = row.team,
		maxHealth = row.entry.combatant.maxHealth,
		radius = row.entry.radius,
	}
end

local despawn: (id: number) -> ()

local function reportKill(row: Row, killerId: number)
	local killer = CombatService.entry(killerId)
	local player = killer and killer.player
	if player == nil or not DebugAccess.canView(player) or row.kind == "bot" then
		return
	end
	local seconds = if row.firstHitAt then now() - (row.firstHitAt :: number) else 0
	Net.fireClient(
		Remotes.DevMessage,
		player,
		`TTK {row.kind}: {row.hits} hit(s), {string.format("%.2f", seconds)} s from first hit`
	)
end

-- Spawns an NPC at a world position. `team` is nil for monsters.
function NpcService.spawn(kind: Kind, position: Vector3, team: number?): number
	local id = nextId
	nextId = nextId % 65535 + 1
	local maxHealth, damage, radius, speed, power
	if kind == "bot" then
		local stats = Stats.compute(Config.get().combat.knight, 1)
		maxHealth, damage, radius, speed, power = stats.maxHealth, stats.damage, BOT_RADIUS, BOT_SPEED, stats.power
	else
		local c = enemyConfig(kind)
		maxHealth = math.max(1, math.floor(c.maxHealth * Tuning.get("enemyHealthScale") + 0.5))
		damage, radius, speed, power = c.damage, c.radius, c.speed, 1
	end

	local row: Row
	local combatant = Damage.newCombatant(-id, team, maxHealth, 0)
	local entry: CombatService.Entry = {
		combatant = combatant,
		kind = "npc",
		player = nil,
		radius = radius,
		damage = damage,
		power = power,
		history = CombatService.newHistory(),
		position = function(): Vector3?
			return Vector3.new(row.x, 2.5, row.z)
		end,
		onHit = function(_result: Damage.Result, knockback: Vector3)
			row.hits += 1
			row.firstHitAt = row.firstHitAt or now()
			-- Stationary NPCs (the target dummy) are not pushed around.
			if row.speed > 0 then
				row.vx += knockback.X
				row.vz += knockback.Z
			end
		end,
	}
	row = {
		id = id,
		kind = kind,
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
		speed = speed,
		home = position,
		spawnedAt = now(),
		firstHitAt = nil,
		hits = 0,
		alive = true,
	}
	rows[id] = row
	CombatService.register(entry)
	Net.fireAllClients(Remotes.NpcSpawn, spawnEvent(row))
	return id
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

-- Removes every NPC. Returns how many were removed.
function NpcService.clear(): number
	local count = 0
	for id in rows do
		despawn(id)
		count += 1
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

local function tickSlammer(row: Row, t: number, dt: number)
	local c = Config.get().combat.enemies.slammer
	if row.state == S.telegraph then
		if t >= row.stateEndsAt then
			local impactAt = row.stateEndsAt
			local center = Vector3.new(row.x, 0, row.z)
			Net.fireAllClients(Remotes.NpcAction, {
				id = row.id,
				action = "impact",
				x = row.x,
				z = row.z,
				radius = c.slamRadius,
				duration = 0,
			})
			row.state = S.recover
			row.stateEndsAt = t + c.recoverSeconds
			row.lastAttackAt = t
			-- Resolve after a short delay so a dodge sent just before impact still counts.
			task.delay(Config.get().combat.hitResolveDelay, function()
				if row.alive then
					CombatService.areaHit(row.entry, center, c.slamRadius, c.damage, impactAt)
				end
			end)
		end
		return
	end
	if row.state == S.recover then
		if t >= row.stateEndsAt then
			row.state = S.idle
		end
		return
	end
	local target, distance = CombatService.nearestHostile(row.entry, c.aggroRange)
	if target == nil then
		row.state = S.idle
		return
	end
	local p = targetPosition(target) :: Vector3
	if distance <= c.attackRange and Melee.cooldownReady(row.lastAttackAt, t, c.attackCooldown, 0) then
		face(row, p.X, p.Z)
		row.state = S.telegraph
		row.stateEndsAt = t + c.telegraphSeconds
		Net.fireAllClients(Remotes.NpcAction, {
			id = row.id,
			action = "telegraph",
			x = row.x,
			z = row.z,
			radius = c.slamRadius,
			duration = c.telegraphSeconds,
		})
	else
		moveToward(row, p.X, p.Z, c.attackRange * 0.6, dt)
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

local function separate(list: { Row })
	for i = 1, #list do
		local a = list[i]
		for j = i + 1, #list do
			local b = list[j]
			local dx, dz = b.x - a.x, b.z - a.z
			local min = a.entry.radius + b.entry.radius
			local d2 = dx * dx + dz * dz
			if d2 < min * min and d2 > 1e-6 then
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
				elseif row.kind == "slammer" then
					tickSlammer(row, t, dt)
				elseif row.kind == "bot" then
					tickBot(row, t, dt)
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
			row.x, row.z = GymService.clamp(row.x, row.z, row.entry.radius)
		end
	end
end

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
		})
	end
	for _, chunk in NpcCodec.pack(now(), entities, SNAPSHOT_MAX_BYTES) do
		Net.fireAllClients(Remotes.NpcSnapshot, chunk)
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
		task.delay(DESPAWN_DELAY, function()
			despawn(row.id)
			if row.kind == "bot" then
				task.delay(BOT_RESPAWN_SECONDS, function()
					NpcService.spawn("bot", row.home, row.team)
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
