--!strict
-- Minion waves: spawning, lane movement, targeting, combat and replication.
--
--   Data model: struct-of-arrays indexed by slot, with free-list reuse. Each slot also owns one
--   reusable CombatService entry (created once per slot), so minion damage goes through the
--   shared damage pipeline and players hit minions through the same melee path as anything else.
--   Movement: a scalar distance along the lane path plus a lateral offset; no pathfinding.
--   Targeting: through the spatial grid; nearest enemy minion, then player or bot (guardians
--   from Phase 6).
--   Replication: per client, only minions within the interest radius; only those that changed
--   visibly since last sent, plus all of them once a second (keyframe). Packed with
--   MinionCodec, chunked under 900 bytes, unreliable, 10 Hz.
--   Waves spawn during the Active phase (or always while a load test forces them) and are
--   cleared on round reset.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local LanePath = require(ReplicatedStorage.Shared.Map.LanePath)
local Map = require(ReplicatedStorage.Shared.Map)
local MinionCodec = require(ReplicatedStorage.Shared.Combat.MinionCodec)
local Minions = require(ReplicatedStorage.Shared.Combat.Minions)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local SpatialGrid = require(ReplicatedStorage.Shared.Combat.SpatialGrid)

local CombatService = require("./CombatService")
local RoundService = require("./RoundService")

local TICK_HZ = 10
local SNAPSHOT_MAX_BYTES = 900
local RETARGET_SECONDS = 0.5
local DEAD_SECONDS = 1
local KNOCKBACK_DECAY = 8
-- Minions shrug off most player knockback so waves keep their shape.
local KNOCKBACK_SCALE = 0.4
local SEPARATION = 0.6
local SUMMARY_SECONDS = 1
local Y = 2.5

local S = MinionCodec.States

local MinionService = {
	name = "MinionService",
	dependencies = { "CombatService", "RoundService" },
	-- Average seconds per server frame for the minion tick and snapshots (perf report).
	tickCost = 0,
	snapshotCost = 0,
	-- Worst single-frame minion tick over the last second, in seconds.
	tickMax = 0,
	-- The Titan minions attack once they reach the end of their lane (set by MonsterService).
	siegeTarget = function(_team: number): CombatService.Entry?
		return nil
	end,
}

-- Struct of arrays -------------------------------------------------------------------------

local capacity = 0
local free: { number } = {}
local used: { [number]: boolean } = {}
local netId: { number } = {}
local kindOf: { number } = {}
local teamOf: { number } = {}
local laneOf: { MapLaneId } = {}
local distanceOf: { number } = {}
local lateralOf: { number } = {}
local xOf: { number } = {}
local zOf: { number } = {}
local yawOf: { number } = {}
local stateOf: { number } = {}
local targetOf: { number } = {}
local retargetAt: { number } = {}
local lastAttackOf: { number } = {}
local vxOf: { number } = {}
local vzOf: { number } = {}
local deadAt: { number } = {}
local lastTickOf: { number } = {}
local entryOf: { CombatService.Entry } = {}

type MapLaneId = Map.LaneId

-- Network ID -> slot, and the next network ID to try.
local slotByNet: { [number]: number } = {}
local nextNet = 1

-- Grid of every used slot (alive or dying) for interest management.
local interestGrid = SpatialGrid.new(32)

-- Waves.
type Pending = { at: number, lane: MapLaneId, team: number, kind: string, index: number, count: number }
local pending: { Pending } = {}
local nextWaveAt = math.huge
local forceWaves = false
local waveScale = 1
local intervalOverride: number? = nil

-- Replication bookkeeping per player.
type ClientState = { pos: { [number]: number }, rest: { [number]: number }, keyframeAt: number, bytes: number }
local clients: { [Player]: ClientState } = {}
local bytesPerSecond: { [Player]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function config(): Config.MinionConfig
	return Config.get().minions
end

local function kindConfig(kind: number): Config.MinionKindConfig
	local name = Minions.KIND_NAMES[kind]
	return (config().kinds :: any)[name]
end

local function pathOf(slot: number): LanePath.Path
	return Map.get().laneById[laneOf[slot]]
end

local function allocateNet(): number
	for _ = 1, 65535 do
		local candidate = nextNet
		nextNet = nextNet % 65535 + 1
		if slotByNet[candidate] == nil then
			return candidate
		end
	end
	error("no free minion network IDs")
end

local function newSlot(): number
	local slot = table.remove(free)
	if slot then
		return slot
	end
	capacity += 1
	local s: number = capacity
	-- One entry per slot, reused for every minion that occupies it.
	entryOf[s] = {
		combatant = Damage.newCombatant(0, nil, 1, 0),
		kind = "minion",
		player = nil,
		radius = 1,
		damage = 0,
		power = 1,
		history = CombatService.newHistory(),
		position = function(): Vector3?
			return Vector3.new(xOf[s], Y, zOf[s])
		end,
		onHit = function(_result: Damage.Result, knockback: Vector3)
			vxOf[s] += knockback.X * KNOCKBACK_SCALE
			vzOf[s] += knockback.Z * KNOCKBACK_SCALE
		end,
		announceKills = false,
	}
	return s
end

local function spawnMinion(lane: MapLaneId, team: number, kindName: string, lateral: number)
	local kind = Minions.KIND_INDEX[kindName]
	local cfg = kindConfig(kind)
	local slot = newSlot()
	local id = allocateNet()
	local path = Map.get().laneById[lane]
	local distance = Minions.startDistance(path.length, team, 0.01)
	local p = LanePath.pointAt(path, distance, lateral)

	used[slot] = true
	netId[slot] = id
	slotByNet[id] = slot
	kindOf[slot] = kind
	teamOf[slot] = team
	laneOf[slot] = lane
	distanceOf[slot] = distance
	lateralOf[slot] = lateral
	xOf[slot], zOf[slot] = p.x, p.z
	local tangent = LanePath.tangentAt(path, distance)
	local dir = Minions.direction(team)
	yawOf[slot] = math.atan2(-tangent.x * dir, -tangent.z * dir)
	stateOf[slot] = S.walk
	targetOf[slot] = 0
	retargetAt[slot] = 0
	lastAttackOf[slot] = -math.huge
	vxOf[slot], vzOf[slot] = 0, 0
	deadAt[slot] = 0
	lastTickOf[slot] = now()

	local entry = entryOf[slot]
	local combatant = entry.combatant
	combatant.id = Minions.combatantId(id)
	combatant.team = team
	combatant.maxHealth = cfg.maxHealth
	combatant.health = cfg.maxHealth
	combatant.defence = 0
	combatant.alive = true
	combatant.invulnerableUntil = -math.huge
	combatant.protected = false
	combatant.lastDamagedAt = -math.huge
	table.clear(combatant.contributors)
	entry.radius = cfg.radius
	entry.damage = cfg.damage
	entry.history.count = 0
	CombatService.register(entry)
	SpatialGrid.update(interestGrid, id, p.x, p.z)
end

local function release(slot: number)
	local id = netId[slot]
	used[slot] = nil
	slotByNet[id] = nil
	SpatialGrid.remove(interestGrid, id)
	CombatService.unregister(entryOf[slot].combatant.id)
	for _, state in clients do
		state.pos[id] = nil
		state.rest[id] = nil
	end
	table.insert(free, slot)
end

-- Removes every minion. Returns how many were removed.
function MinionService.clear(): number
	local count = 0
	for slot in used do
		release(slot)
		count += 1
	end
	table.clear(pending)
	return count
end

function MinionService.count(): number
	local n = 0
	for slot in used do
		if stateOf[slot] ~= S.dead then
			n += 1
		end
	end
	return n
end

-- Waves --------------------------------------------------------------------------------------

local function interval(): number
	return intervalOverride or config().waveInterval
end

-- Queues one wave on every lane for both teams, starting now.
function MinionService.spawnWave()
	local t = now()
	local plan = Minions.wavePlan(config().composition, waveScale)
	local stagger = config().spawnStagger
	-- Big load-test waves come out in rows of up to 6 abreast.
	local perRow = math.min(#plan, 6)
	for _, lane in Map.get().lanes do
		for team = 1, 2 do
			for i, kind in plan do
				local row = (i - 1) // perRow
				table.insert(pending, {
					at = t + row * stagger,
					lane = lane.id,
					team = team,
					kind = kind,
					index = (i - 1) % perRow + 1,
					count = perRow,
				})
			end
		end
	end
end

function MinionService.setForceWaves(on: boolean)
	forceWaves = on
	if on then
		nextWaveAt = now()
	end
end

function MinionService.setScale(scale: number)
	waveScale = math.clamp(scale, 0.1, 20)
end

function MinionService.setInterval(seconds: number?)
	intervalOverride = if seconds then math.clamp(seconds, 2, 600) else nil
end

function MinionService.settings(): (boolean, number, number)
	return forceWaves, waveScale, interval()
end

local function wavesActive(): boolean
	return forceWaves or RoundService.state().phase == "Active"
end

-- Simulation ---------------------------------------------------------------------------------

local function retarget(slot: number, t: number)
	local x, z = xOf[slot], zOf[slot]
	local candidates: { Minions.Candidate } = {}
	CombatService.hostilesNear(teamOf[slot], x, z, config().aggroRange, function(entry, d)
		if not entry.gated then
			table.insert(candidates, { id = entry.combatant.id, distance = d, isMinion = entry.kind == "minion" })
		end
	end)
	targetOf[slot] = Minions.chooseTarget(candidates) or 0
	retargetAt[slot] = t + RETARGET_SECONDS * (0.75 + math.random() * 0.5)
end

local function face(slot: number, dx: number, dz: number)
	if dx * dx + dz * dz > 1e-4 then
		yawOf[slot] = math.atan2(-dx, -dz)
	end
end

local function tickSlot(slot: number, t: number, dt: number)
	local cfg = kindConfig(kindOf[slot])
	local entry = entryOf[slot]

	-- Current target, re-chosen every half second or when it disappears.
	local target = if targetOf[slot] ~= 0 then CombatService.entry(targetOf[slot]) else nil
	if target == nil or not target.combatant.alive or t >= retargetAt[slot] then
		retarget(slot, t)
		target = if targetOf[slot] ~= 0 then CombatService.entry(targetOf[slot]) else nil
		if target == nil and Minions.reachedEnd(distanceOf[slot], pathOf(slot).length, teamOf[slot]) then
			target = MinionService.siegeTarget(3 - teamOf[slot])
			targetOf[slot] = if target then target.combatant.id else 0
		end
	end

	local x, z = xOf[slot], zOf[slot]
	if target then
		local p = target.position()
		if p then
			local dx, dz = p.X - x, p.Z - z
			local d = math.sqrt(dx * dx + dz * dz)
			face(slot, dx, dz)
			local gap = d - target.radius - entry.radius
			if gap > cfg.attackRange then
				local step = math.min(cfg.speed * dt, gap - cfg.attackRange * 0.8)
				xOf[slot] = x + dx / d * step
				zOf[slot] = z + dz / d * step
				stateOf[slot] = S.walk
			else
				stateOf[slot] = S.fight
				if t - lastAttackOf[slot] >= cfg.attackCooldown then
					lastAttackOf[slot] = t
					CombatService.applyHit(entry.combatant.id, target.combatant.id, cfg.damage, "minion", nil, t)
				end
			end
			return
		end
	end

	-- No target: walk the lane, rejoining it after a chase.
	stateOf[slot] = S.walk
	local path = pathOf(slot)
	local team = teamOf[slot]
	local dir = Minions.direction(team)
	local onLane = LanePath.pointAt(path, distanceOf[slot], lateralOf[slot])
	local ox, oz = onLane.x - x, onLane.z - z
	local off = math.sqrt(ox * ox + oz * oz)
	if off > 3 then
		-- Pushed or chased away: walk back towards the lane, picking up from where we are.
		local along = LanePath.project(path, { x = x, z = z })
		distanceOf[slot] = along
		local back = LanePath.pointAt(path, along + dir * 4, lateralOf[slot])
		local bx, bz = back.x - x, back.z - z
		local bd = math.sqrt(bx * bx + bz * bz)
		if bd > 1e-3 then
			local step = math.min(cfg.speed * dt, bd)
			xOf[slot] = x + bx / bd * step
			zOf[slot] = z + bz / bd * step
			face(slot, bx, bz)
		end
		return
	end
	distanceOf[slot] += dir * cfg.speed * dt
	if Minions.reachedEnd(distanceOf[slot], path.length, team) then
		-- Past the lane end: besiege the enemy Titan, or leave if there is none.
		distanceOf[slot] = if dir > 0 then path.length else 0
		if MinionService.siegeTarget(3 - team) == nil then
			release(slot)
		end
		return
	end
	local p = LanePath.pointAt(path, distanceOf[slot], lateralOf[slot])
	face(slot, p.x - x, p.z - z)
	xOf[slot], zOf[slot] = p.x, p.z
end

local function separate(slot: number)
	local x, z = xOf[slot], zOf[slot]
	local r = entryOf[slot].radius
	CombatService.allNear(x, z, 4, function(other)
		if other.kind == "minion" and other ~= entryOf[slot] then
			local p = other.position() :: Vector3
			local dx, dz = x - p.X, z - p.Z
			local min = r + other.radius
			local d2 = dx * dx + dz * dz
			if d2 < min * min and d2 > 1e-6 then
				local d = math.sqrt(d2)
				local push = (min - d) * SEPARATION * 0.5
				xOf[slot] += dx / d * push
				zOf[slot] += dz / d * push
			end
		end
	end)
end

-- Minions are ticked in BUCKETS groups, one group per server frame, so each minion still runs
-- at about 10 Hz but the work is spread evenly instead of landing on one frame.
local BUCKETS = 6
local bucket = 0

local function tick()
	local t = now()
	local paused = not Round.inputAllowed(RoundService.state().phase)
	bucket = (bucket + 1) % BUCKETS

	-- Waves.
	if wavesActive() then
		if t >= nextWaveAt then
			MinionService.spawnWave()
			nextWaveAt = t + interval()
		end
	end
	if #pending > 0 then
		local remaining: { Pending } = {}
		for _, p in pending do
			if t >= p.at then
				spawnMinion(p.lane, p.team, p.kind, Minions.lateralFor(p.index, p.count, config().formationWidth))
			else
				table.insert(remaining, p)
			end
		end
		pending = remaining
	end

	for slot in used do
		if slot % BUCKETS ~= bucket then
			continue
		end
		-- Each minion integrates over the time since it last ticked.
		local dt = math.min(t - lastTickOf[slot], 0.5)
		lastTickOf[slot] = t
		if stateOf[slot] == S.dead then
			if t - deadAt[slot] >= DEAD_SECONDS then
				release(slot)
			end
		elseif not paused then
			tickSlot(slot, t, dt)
			if used[slot] then
				separate(slot)
				-- Knockback, decaying.
				xOf[slot] += vxOf[slot] * dt
				zOf[slot] += vzOf[slot] * dt
				local decay = math.max(0, 1 - KNOCKBACK_DECAY * dt)
				vxOf[slot] *= decay
				vzOf[slot] *= decay
			end
		end
		if used[slot] then
			SpatialGrid.update(interestGrid, netId[slot], xOf[slot], zOf[slot])
		end
	end
end

-- Replication --------------------------------------------------------------------------------

local function clientState(player: Player): ClientState
	local state = clients[player]
	if state == nil then
		state = { pos = {}, rest = {}, keyframeAt = 0, bytes = 0 }
		clients[player] = state
	end
	return state
end

local function snapshot()
	local t = now()
	local radius = config().interestRadius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local state = clientState(player)
			local keyframe = t >= state.keyframeAt
			if keyframe then
				state.keyframeAt = t + config().keyframeSeconds
			end
			local entities: { MinionCodec.Entity } = {}
			local px, pz = root.Position.X, root.Position.Z
			-- The grid visits cell by cell, so chunks group minions by area.
			SpatialGrid.query(interestGrid, px, pz, radius, function(id)
				local slot = slotByNet[id]
				if slot == nil then
					return
				end
				local dx, dz = xOf[slot] - px, zOf[slot] - pz
				if dx * dx + dz * dz > radius * radius then
					return
				end
				local c = entryOf[slot].combatant
				local e: MinionCodec.Entity = {
					id = id,
					x = xOf[slot],
					z = zOf[slot],
					yaw = yawOf[slot],
					health = if c.maxHealth > 0 then c.health / c.maxHealth else 0,
					state = stateOf[slot],
					kind = kindOf[slot],
					team = teamOf[slot],
				}
				local qx, qz, qyaw, qhealth, qstate = MinionCodec.quantize(e)
				local posKey = qx * 65536 + qz
				local restKey = qyaw * 65536 + qhealth * 256 + qstate
				if keyframe or state.pos[id] ~= posKey or state.rest[id] ~= restKey then
					state.pos[id] = posKey
					state.rest[id] = restKey
					table.insert(entities, e)
				end
			end)
			for _, chunk in MinionCodec.pack(t, entities, SNAPSHOT_MAX_BYTES) do
				Net.fireClient(Remotes.MinionSnapshot, player, chunk)
				state.bytes += buffer.len(chunk)
			end
		end
	end
end

local function summary()
	local map = Map.get()
	local infos: { Remotes.WaveInfo } = {}
	local index: { [string]: Remotes.WaveInfo } = {}
	for _, lane in map.lanes do
		for team = 1, 2 do
			local info: Remotes.WaveInfo = { lane = lane.id, team = team, count = 0, front = 0 }
			index[lane.id .. team] = info
			table.insert(infos, info)
		end
	end
	for slot in used do
		if stateOf[slot] ~= S.dead then
			local info = index[laneOf[slot] .. teamOf[slot]]
			info.count += 1
			local path = pathOf(slot)
			local progress = distanceOf[slot] / path.length
			if teamOf[slot] == 2 then
				progress = 1 - progress
			end
			info.front = math.max(info.front, math.clamp(progress, 0, 1))
		end
	end
	Net.fireAllClients(Remotes.WaveSummary, infos)
end

-- Bytes of minion snapshots sent to `player` over the last second.
function MinionService.bytesPerSecond(player: Player): number
	return bytesPerSecond[player] or 0
end

-- Lifecycle ----------------------------------------------------------------------------------

function MinionService.init(_self: typeof(MinionService))
	CombatService.killed:connect(function(victimId: number)
		local id = Minions.networkId(victimId)
		local slot = if id then slotByNet[id] else nil
		if slot == nil then
			return
		end
		stateOf[slot] = S.dead
		deadAt[slot] = now()
		-- Proximity credit: hostile players nearby (no last-hit needed).
		local credit = config().creditRadius
		local team = teamOf[slot]
		for _, player in Players:GetPlayers() do
			local entry = CombatService.entry(player.UserId)
			local p = entry and entry.position()
			if entry and p and Damage.hostile(team, entry.combatant.team) then
				local dx, dz = p.X - xOf[slot], p.Z - zOf[slot]
				if dx * dx + dz * dz <= credit * credit then
					CombatService.credited:fire(player, "minion", 1)
					player:SetAttribute("MinionCredits", ((player:GetAttribute("MinionCredits") :: number?) or 0) + 1)
				end
			end
		end
	end)

	RoundService.phaseChanged:connect(function(state: Round.State)
		if state.phase == "Active" then
			nextWaveAt = now() + config().firstWaveDelay
		end
	end)
	RoundService.roundReset:connect(function()
		MinionService.clear()
		nextWaveAt = math.huge
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		clients[player] = nil
		bytesPerSecond[player] = nil
	end)

	local accumulator = 0
	local summaryAt = 0
	local frames = 0
	local window = 0
	local tickTime, snapshotTime = 0, 0
	local tickPeak = 0
	RunService.Heartbeat:Connect(function(dt: number)
		frames += 1
		window += dt
		accumulator += dt
		local started = os.clock()
		tick()
		local spent = os.clock() - started
		tickTime += spent
		tickPeak = math.max(tickPeak, spent)
		if accumulator >= 1 / TICK_HZ then
			local snapStarted = os.clock()
			snapshot()
			snapshotTime += os.clock() - snapStarted
			accumulator = 0
		end
		local t = now()
		if t >= summaryAt then
			summaryAt = t + SUMMARY_SECONDS
			summary()
		end
		if window >= 1 then
			MinionService.tickCost = tickTime / frames
			MinionService.snapshotCost = snapshotTime / frames
			MinionService.tickMax = tickPeak
			tickPeak = 0
			for player, state in clients do
				bytesPerSecond[player] = state.bytes / window
				state.bytes = 0
			end
			tickTime, snapshotTime, frames, window = 0, 0, 0, 0
		end
	end)
end

function MinionService.start(_self: typeof(MinionService))
	-- If the server starts mid-round (Studio), pick up the Active phase.
	if RoundService.state().phase == "Active" then
		nextWaveAt = now() + config().firstWaveDelay
	end
end

return MinionService
