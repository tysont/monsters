--!strict
-- Monsters: every monster row (gym monsters, guardians, Titans; jungle monsters from Phase 7) is
-- driven by the shared behaviour state machine (Shared.Combat.MonsterBrain) with data-driven
-- definitions from Config.monsters.
--
--   Attacks: slam (circle on the monster or on its target), sweep (cone) and projectile (bolts).
--     A telegraph is broadcast when an attack is chosen; its aim is fixed then, so moving out or
--     dodging avoids it. Hits resolve at impact (circles and cones, a little late so a dodge sent
--     just before impact still counts) or as bolts fly (projectiles, simulated every frame).
--   Stagger: damage during recovery fills a bar; full opens a window of bonus damage.
--   Sleep: a monster with no hostile within its wake range runs no logic, only a 2 Hz check.
--   Structures: an outer and inner guardian per lane per team and a Titan per team, spawned at the
--     map markers each round. Lane gating makes inner guardians and Titans invulnerable until
--     opened. Guardians attack provokers (hostiles who hurt their team's players nearby) first,
--     then minions, then anyone. While a Titan is under attack its team respawns faster. A Titan's
--     death ends the round. Health and alerts replicate as attributes on
--     ReplicatedStorage.Structures for the HUD and minimap.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local LanePath = require(ReplicatedStorage.Shared.Map.LanePath)
local Map = require(ReplicatedStorage.Shared.Map)
local Minions = require(ReplicatedStorage.Shared.Combat.Minions)
local MonsterBrain = require(ReplicatedStorage.Shared.Combat.MonsterBrain)
local Net = require(ReplicatedStorage.Shared.Net)
local NpcCodec = require(ReplicatedStorage.Shared.Combat.NpcCodec)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Shapes = require(ReplicatedStorage.Shared.Combat.Shapes)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Structures = require(ReplicatedStorage.Shared.Combat.Structures)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local MinionService = require("./MinionService")
local NpcService = require("./NpcService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

local RETARGET_SECONDS = 0.5
local WAKE_CHECK_SECONDS = 0.5
-- Awake monsters with nothing to fight for this long go back to sleep.
local SLEEP_AFTER = 3
-- Clients farther than this from a monster do not get its telegraphs.
local BROADCAST_RANGE = 400
local FOLDER_NAME = "Structures"

local S = NpcCodec.States

export type Monster = {
	row: NpcService.Row,
	id: string,
	def: Config.MonsterDefinition,
	brain: MonsterBrain.Brain,
	structure: Structures.Structure?,
	-- Combatant ID of the current target, 0 for none.
	target: number,
	retargetAt: number,
	awake: boolean,
	wakeCheckAt: number,
	-- Last time the monster had a target or acted.
	busyAt: number,
	-- Combatant ID -> server time until which it counts as a provoker.
	provokers: { [number]: number },
	-- Bumped for every telegraph; a pending impact only lands if it still matches.
	token: number,
	-- Aim of the current telegraph: origin and unit direction.
	ax: number,
	az: number,
	dx: number,
	dz: number,
	-- Jungle camp this monster belongs to (CampService), or nil.
	camp: number?,
	-- Multiplies the damage of its attacks (camp tier).
	damageScale: number,
	healthScale: number,
	-- Underground (burrow): hidden, untargetable and invulnerable.
	burrowed: boolean,
	-- Living monsters it summoned.
	summons: { Monster },
	-- Lane unit (unleashed from a hatchery): the lane it marches and how far along it is.
	lane: Map.LaneId?,
	laneDistance: number,
	ownerId: number?,
	follow: CombatService.Entry?,
	-- Length of the charge being telegraphed (clamped to the leash).
	chargeLength: number?,
}

-- Options for spawning a monster outside the structure system.
export type SpawnOptions = {
	camp: number?,
	healthScale: number?,
	damageScale: number?,
	-- Unleashed lane unit: marches this lane for its team.
	lane: Map.LaneId?,
	-- Player (user ID) credited with what an unleashed monster does.
	owner: number?,
	-- Pet: follows this combatant, fights hostiles near it, cannot be targeted.
	follow: CombatService.Entry?,
	-- Body size multiplier (pets are smaller).
	scale: number?,
}

-- A bolt, or a charging monster (carrier = true: moves the monster and passes through everything
-- it hits, once each).
type Projectile = {
	monster: Monster,
	attack: Config.MonsterAttack,
	x: number,
	z: number,
	dx: number,
	dz: number,
	travelled: number,
	radius: number,
	carrier: boolean,
	hit: { [number]: boolean },
}

local MonsterService = {
	name = "MonsterService",
	dependencies = {
		"CharacterService",
		"CombatService",
		"MinionService",
		"NpcService",
		"RoundService",
		"TeamService",
	},
	-- (structure, killerId, assistIds)
	structureDestroyed = Signal.new() :: Signal.Signal<Structures.Structure, number, { number }>,
	-- Every telegraph as broadcast, with the attacking monster's team (dev avoid test).
	telegraphed = Signal.new() :: Signal.Signal<Remotes.MonsterActionEvent, number?>,
	-- Every monster spawned (including summons and split pieces), and every monster defeated
	-- (with the killer's combatant ID). CampService tracks camp members with these.
	spawned = Signal.new() :: Signal.Signal<Monster>,
	died = Signal.new() :: Signal.Signal<Monster, number>,
	-- Average seconds per frame spent on projectiles over the last second (perf report).
	projectileCost = 0,
}

-- By NPC row ID.
local monsters: { [number]: Monster } = {}
-- Structure key -> monster, for the current round.
local structures: { [string]: Monster } = {}
local dead: { [string]: boolean } = {}
local alertUntil: { [number]: number } = { [1] = 0, [2] = 0 }
local projectiles: { Projectile } = {}
local folder: Folder
local healthScaleOverride: number? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function config()
	return Config.get()
end

local function action(m: Monster, kind: string): Remotes.MonsterActionEvent
	return {
		id = m.row.id,
		action = kind,
		shape = "none",
		x = m.row.x,
		z = m.row.z,
		dx = 0,
		dz = 0,
		radius = 0,
		reach = 0,
		arc = 0,
		count = 0,
		spread = 0,
		speed = 0,
		startsAt = now(),
		endsAt = now(),
		value = 0,
	}
end

local function broadcast(m: Monster, event: Remotes.MonsterActionEvent)
	local recipients: { Player } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local dx, dz = root.Position.X - m.row.x, root.Position.Z - m.row.z
			if dx * dx + dz * dz <= BROADCAST_RANGE * BROADCAST_RANGE then
				table.insert(recipients, player)
			end
		end
	end
	if #recipients > 0 then
		Net.fireClients(Remotes.MonsterAction, recipients, event)
	end
end

-- Structures ---------------------------------------------------------------------------------

local function setHealthAttribute(m: Monster)
	local s = m.structure
	if s == nil then
		return
	end
	local c = m.row.entry.combatant
	local fraction = if c.alive then math.max(0.01, math.floor(c.health / c.maxHealth * 100 + 0.5) / 100) else 0
	if folder:GetAttribute(s.key) ~= fraction then
		folder:SetAttribute(s.key, fraction)
	end
end

local function updateGating()
	for _, m in structures do
		local s = m.structure :: Structures.Structure
		-- Outside the Active phase every structure is locked, so nothing is decided before a round
		-- starts.
		local gated = RoundService.state().phase ~= "Active" or not Structures.vulnerable(s.kind, s.team, s.lane, dead)
		m.row.entry.gated = gated
		m.row.entry.combatant.protected = gated
	end
end

-- Monster logic ------------------------------------------------------------------------------

local function stateCode(m: Monster, moving: boolean): number
	local state = m.brain.state
	if m.burrowed then
		return S.hidden
	elseif state == "telegraph" then
		return S.telegraph
	elseif state == "attack" then
		return S.attack
	elseif state == "recover" then
		return S.recover
	elseif state == "stagger" then
		return S.stagger
	end
	return if moving then S.move else S.idle
end

local function face(m: Monster, tx: number, tz: number)
	local dx, dz = tx - m.row.x, tz - m.row.z
	if dx * dx + dz * dz > 1e-4 then
		m.row.yaw = math.atan2(-dx, -dz)
	end
end

local function anyHostileNear(m: Monster, range: number): boolean
	local found = false
	CombatService.hostilesNear(m.row.team, m.row.x, m.row.z, range + m.def.radius, function(entry)
		if entry ~= m.row.entry then
			found = true
		end
	end)
	return found
end

-- Pets fight within this range of their owner.
local PET_RANGE = 22
-- Pets move at least this fast (players walk at 16) and catch up instantly beyond PET_TELEPORT.
local PET_SPEED = 19
local PET_TELEPORT = 60

-- Where a monster looks for targets, and how far: around itself, or around its owner for pets.
local function searchCenter(m: Monster): (number, number, number)
	local follow = m.follow
	local p = if follow and follow.combatant.alive then follow.position() else nil
	if p then
		return p.X, p.Z, PET_RANGE
	end
	return m.row.x, m.row.z, m.def.aggroRange + m.def.radius
end

local function chooseTarget(m: Monster, t: number): number
	local candidates: { Structures.Candidate } = {}
	-- Pets look around their owner instead of themselves.
	local cx, cz, range = searchCenter(m)
	CombatService.hostilesNear(m.row.team, cx, cz, range, function(entry, d)
		if entry ~= m.row.entry and not entry.gated then
			table.insert(candidates, {
				id = entry.combatant.id,
				distance = d - entry.radius,
				isMinion = entry.kind == "minion",
				provoked = (m.provokers[entry.combatant.id] or 0) > t,
			})
		end
	end)
	if m.structure then
		return Structures.chooseTarget(candidates) or 0
	end
	-- Other monsters: nearest.
	local best, bestDistance = 0, math.huge
	for _, c in candidates do
		if c.distance < bestDistance then
			best, bestDistance = c.id, c.distance
		end
	end
	return best
end

local function currentTarget(m: Monster, t: number): CombatService.Entry?
	local entry = if m.target ~= 0 then CombatService.entry(m.target) else nil
	if entry == nil or not entry.combatant.alive or entry.gated or t >= m.retargetAt then
		m.target = chooseTarget(m, t)
		m.retargetAt = t + RETARGET_SECONDS * (0.8 + math.random() * 0.4)
		entry = if m.target ~= 0 then CombatService.entry(m.target) else nil
	end
	if entry then
		local p = entry.position()
		if p then
			-- Lost it out of range (measured from where the monster searches).
			local cx, cz, searchRange = searchCenter(m)
			local dx, dz = p.X - cx, p.Z - cz
			local range = searchRange + entry.radius + 4
			if dx * dx + dz * dz > range * range then
				m.target = 0
				return nil
			end
		end
	end
	return entry
end

local handle: (m: Monster, event: MonsterBrain.Event?, target: CombatService.Entry?) -> ()

local function healthFraction(m: Monster): number
	local c = m.row.entry.combatant
	return c.health / c.maxHealth
end

-- Advances the brain now (used at the exact end of a telegraph).
local function step(m: Monster)
	if not m.row.alive or not Round.inputAllowed(RoundService.state().phase) then
		return
	end
	local t = now()
	local event =
		MonsterBrain.update(m.brain, m.def, t, { distance = nil, healthFraction = healthFraction(m) }, math.random)
	handle(m, event, nil)
	m.row.state = stateCode(m, false)
end

local spawnMonster: (
	id: string,
	position: Vector3,
	team: number?,
	structure: Structures.Structure?,
	options: SpawnOptions?
) -> Monster

local function setBurrowed(m: Monster, burrowed: boolean)
	m.burrowed = burrowed
	m.row.entry.gated = burrowed or m.follow ~= nil
	m.row.entry.combatant.protected = burrowed or m.follow ~= nil
end

-- Keeps a point within the monster's leash of home (burrows and charges do not leave the camp).
local function leashed(m: Monster, x: number, z: number): (number, number)
	local leash = m.def.leashRange
	if leash <= 0 or m.lane ~= nil or m.follow ~= nil then
		return x, z
	end
	local hx, hz = x - m.row.home.X, z - m.row.home.Z
	local d = math.sqrt(hx * hx + hz * hz)
	if d <= leash then
		return x, z
	end
	return m.row.home.X + hx / d * leash, m.row.home.Z + hz / d * leash
end

local function resolveShape(m: Monster, attack: Config.MonsterAttack, at: number)
	local source = m.row.entry
	local heavy = attack.heavy == true
	local damage = attack.damage * m.damageScale
	if attack.primitive == "slam" or attack.primitive == "burrow" then
		local radius = attack.radius or 0
		local cx, cz = m.ax, m.az
		CombatService.shapeHit(source, cx, cz, radius, function(x: number, z: number, r: number): boolean
			return Shapes.inCircle(cx, cz, radius, x, z, r)
		end, damage, attack.knockback, heavy, at)
	elseif attack.primitive == "sweep" then
		local reach, arc = attack.reach or 0, attack.arc or 0
		local ox, oz, dx, dz = m.ax, m.az, m.dx, m.dz
		CombatService.shapeHit(source, ox, oz, reach, function(x: number, z: number, r: number): boolean
			return Shapes.inCone(ox, oz, dx, dz, reach, arc, x, z, r)
		end, damage, attack.knockback, heavy, at)
	elseif attack.primitive == "grab" then
		-- Only the body nearest the centre is grabbed, then thrown away from the monster.
		local radius = attack.radius or 0
		local best: CombatService.Entry? = nil
		local bestDistance = math.huge
		CombatService.hostilesNear(source.combatant.team, m.ax, m.az, radius, function(entry, d)
			if entry ~= source and not entry.gated and d <= radius + entry.radius and d < bestDistance then
				best, bestDistance = entry, d
			end
		end)
		if best then
			local p = best.position() :: Vector3
			local away = Vector3.new(p.X - m.row.x, 0, p.Z - m.row.z)
			local push = if away.Magnitude > 1e-3 then away.Unit * attack.knockback else Vector3.zero
			CombatService.applyHit(source.combatant.id, best.combatant.id, damage, "monster", push, at, heavy)
		end
	end
end

local function summon(m: Monster, attack: Config.MonsterAttack)
	local spec = attack.summon
	-- Pets do not summon (their summons would be wild monsters on the owner's team).
	if spec == nil or m.follow ~= nil then
		return
	end
	-- Forget summons that died.
	local alive: { Monster } = {}
	for _, s in m.summons do
		if s.row.alive then
			table.insert(alive, s)
		end
	end
	m.summons = alive
	for i = 1, spec.count do
		if #m.summons >= spec.max then
			break
		end
		local angle = math.random() * 2 * math.pi + i
		local r = m.def.radius + 3
		local x, z = m.row.x + math.cos(angle) * r, m.row.z + math.sin(angle) * r
		local child = spawnMonster(spec.id, Vector3.new(x, 0, z), m.row.team, nil, {
			camp = m.camp,
			healthScale = m.healthScale,
			damageScale = m.damageScale,
		})
		child.row.home = m.row.home
		child.awake = true
		table.insert(m.summons, child)
	end
end

handle = function(m: Monster, event: MonsterBrain.Event?, target: CombatService.Entry?)
	if event == nil then
		return
	end
	local t = now()
	if event.kind == "telegraph" then
		local attack = event.attack :: Config.MonsterAttack
		local endsAt = event.endsAt :: number
		-- Fix the aim now.
		local tp = if target then target.position() else nil
		local tx = if tp then tp.X else m.row.x - math.sin(m.row.yaw)
		local tz = if tp then tp.Z else m.row.z - math.cos(m.row.yaw)
		face(m, tx, tz)
		local dx, dz = tx - m.row.x, tz - m.row.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < 1e-3 then
			dx, dz, d = -math.sin(m.row.yaw), -math.cos(m.row.yaw), 1
		end
		m.dx, m.dz = dx / d, dz / d
		local primitive = attack.primitive
		if attack.origin == "target" then
			m.ax, m.az = leashed(m, tx, tz)
		else
			m.ax, m.az = m.row.x, m.row.z
		end

		local e = action(m, "telegraph")
		e.x, e.z, e.dx, e.dz = m.ax, m.az, m.dx, m.dz
		e.endsAt = endsAt
		if primitive == "slam" or primitive == "grab" or primitive == "burrow" or primitive == "summon" then
			e.shape, e.radius = "circle", attack.radius or 0
		elseif primitive == "sweep" then
			e.shape, e.reach, e.arc = "cone", attack.reach or 0, attack.arc or 0
		elseif primitive == "charge" then
			-- The charge path: as wide as the monster, ending inside its leash.
			local ex, ez = leashed(m, m.row.x + m.dx * (attack.reach or 0), m.row.z + m.dz * (attack.reach or 0))
			local length = math.sqrt((ex - m.row.x) ^ 2 + (ez - m.row.z) ^ 2)
			e.shape, e.reach, e.radius, e.count = "line", length, m.def.radius, 1
		else
			e.shape, e.reach, e.radius = "line", attack.reach or 0, attack.radius or 0
			e.count, e.spread, e.speed = attack.count or 1, attack.spread or 0, attack.speed or 0
		end
		broadcast(m, e)
		MonsterService.telegraphed:fire(e, m.row.team)
		if primitive == "burrow" then
			setBurrowed(m, true)
		end

		m.token += 1
		local token = m.token
		local reach = e.reach
		task.delay(math.max(0, endsAt - t), function()
			if m.token == token then
				step(m)
			end
		end)
		-- Remember the charge length (clamped to the leash) for the impact.
		if primitive == "charge" then
			m.ax, m.az = m.row.x, m.row.z
			m.chargeLength = reach
		end
	elseif event.kind == "impact" then
		local attack = event.attack :: Config.MonsterAttack
		local primitive = attack.primitive
		local impactAt = t
		if primitive == "projectile" then
			local e = action(m, "projectile")
			e.shape = "line"
			e.x, e.z, e.dx, e.dz = m.ax, m.az, m.dx, m.dz
			e.reach, e.radius, e.speed = attack.reach or 0, attack.radius or 0, attack.speed or 0
			e.count, e.spread = attack.count or 1, attack.spread or 0
			broadcast(m, e)
			for _, dir in Shapes.fan(m.dx, m.dz, attack.count or 1, attack.spread or 0) do
				table.insert(projectiles, {
					monster = m,
					attack = attack,
					x = m.ax,
					z = m.az,
					dx = dir.x,
					dz = dir.z,
					travelled = 0,
					radius = attack.radius or 0,
					carrier = false,
					hit = {},
				})
			end
		elseif primitive == "charge" then
			local e = action(m, "impact")
			broadcast(m, e)
			table.insert(projectiles, {
				monster = m,
				attack = attack,
				x = m.row.x,
				z = m.row.z,
				dx = m.dx,
				dz = m.dz,
				travelled = (attack.reach or 0) - (m.chargeLength or attack.reach or 0),
				radius = m.def.radius,
				carrier = true,
				hit = {},
			})
		elseif primitive == "summon" then
			local e = action(m, "impact")
			e.shape, e.radius = "circle", attack.radius or 0
			broadcast(m, e)
			summon(m, attack)
		else
			if primitive == "burrow" then
				-- Erupt where the target stood.
				m.row.x, m.row.z = m.ax, m.az
				setBurrowed(m, false)
				CombatService.moved(m.row.entry)
			end
			local e = action(m, "impact")
			e.x, e.z, e.dx, e.dz = m.ax, m.az, m.dx, m.dz
			e.shape = if primitive == "sweep" then "cone" else "circle"
			e.radius, e.reach, e.arc = attack.radius or 0, attack.reach or 0, attack.arc or 0
			broadcast(m, e)
			task.delay(config().combat.hitResolveDelay, function()
				if m.row.alive then
					resolveShape(m, attack, impactAt)
				end
			end)
		end
	elseif event.kind == "phase" then
		local e = action(m, "phase")
		e.value = event.phase :: number
		broadcast(m, e)
	end
end

local function tickMonster(m: Monster, t: number, dt: number)
	local row = m.row
	local def = m.def
	if not m.awake then
		if t < m.wakeCheckAt then
			return
		end
		m.wakeCheckAt = t + WAKE_CHECK_SECONDS
		if not anyHostileNear(m, def.wakeRange) then
			return
		end
		m.awake = true
		m.busyAt = t
	end

	local target = currentTarget(m, t)
	local distance: number? = nil
	local tp: Vector3? = nil
	if target then
		tp = target.position()
		if tp then
			local dx, dz = tp.X - row.x, tp.Z - row.z
			distance = math.max(0, math.sqrt(dx * dx + dz * dz) - def.radius - target.radius)
			m.busyAt = t
		end
	end

	-- Mobile monsters walk into reach, and home when they have nothing to do or strayed too far.
	-- Lane units (unleashed monsters) have no home: with nothing to fight they march their lane,
	-- and at its end they besiege the enemy Titan.
	local moving = false
	if def.speed > 0 and m.brain.state == "idle" then
		local gx, gz, stop = row.home.X, row.home.Z, 0.5
		local speed = def.speed
		local lane = m.lane
		local follow = m.follow
		if follow then
			-- Pet: fight near the owner, otherwise trot at heel; snap back if left far behind.
			m.busyAt = t
			speed = math.max(def.speed, PET_SPEED)
			local op = if follow.combatant.alive then follow.position() else nil
			if op and tp and distance and not MonsterBrain.inReach(m.brain, def, distance) then
				gx, gz, stop = tp.X, tp.Z, 0
			elseif op and tp == nil then
				local ox, oz = op.X - row.x, op.Z - row.z
				if ox * ox + oz * oz > PET_TELEPORT * PET_TELEPORT then
					row.x, row.z = op.X + 3, op.Z + 3
					CombatService.moved(row.entry)
				end
				gx, gz, stop = op.X, op.Z, def.radius + 4
			else
				-- In reach of its target, or the owner is gone: stay put.
				gx, gz, stop = row.x, row.z, math.huge
			end
		elseif lane then
			m.busyAt = t
			if tp == nil then
				local path = Map.get().laneById[lane :: Map.LaneId]
				local team = row.team :: number
				local dir = Minions.direction(team)
				m.laneDistance = LanePath.project(path, { x = row.x, z = row.z })
				if Minions.reachedEnd(m.laneDistance + dir * 6, path.length, team) then
					local base = Map.get().bases[3 - team].center
					gx, gz, stop = base.x, base.z, def.radius + 6
				else
					local ahead = LanePath.pointAt(path, m.laneDistance + dir * 8)
					gx, gz, stop = ahead.x, ahead.z, 0
				end
			elseif distance and not MonsterBrain.inReach(m.brain, def, distance) then
				gx, gz, stop = tp.X, tp.Z, 0
			else
				gx, gz, stop = row.x, row.z, math.huge
			end
		else
			local hx, hz = row.home.X - row.x, row.home.Z - row.z
			local fromHome = math.sqrt(hx * hx + hz * hz)
			if fromHome > def.leashRange then
				m.target, target, distance, tp = 0, nil, nil, nil
			end
			if tp and distance and not MonsterBrain.inReach(m.brain, def, distance) then
				gx, gz, stop = tp.X, tp.Z, 0
			elseif tp then
				gx, gz, stop = row.x, row.z, math.huge
			end
		end
		local mx, mz = gx - row.x, gz - row.z
		local md = math.sqrt(mx * mx + mz * mz)
		if md > stop and md > 0.5 then
			local stepLength = math.min(speed * dt, md)
			row.x += mx / md * stepLength
			row.z += mz / md * stepLength
			face(m, gx, gz)
			moving = true
			if target == nil then
				m.busyAt = t
			end
		end
	end
	if tp and m.brain.state == "idle" then
		face(m, tp.X, tp.Z)
	end

	local event =
		MonsterBrain.update(m.brain, def, t, { distance = distance, healthFraction = healthFraction(m) }, math.random)
	handle(m, event, target)
	if m.brain.state ~= "idle" then
		m.busyAt = t
	end

	row.state = stateCode(m, moving)
	row.aux = MonsterBrain.staggerFraction(m.brain, def, t)
	row.entry.vulnerability = MonsterBrain.vulnerability(m.brain, def)

	if t - m.busyAt > SLEEP_AFTER then
		m.awake = false
		m.wakeCheckAt = t + WAKE_CHECK_SECONDS
	end
end

local function onDamaged(m: Monster, result: Damage.Result)
	local t = now()
	m.awake = true
	m.busyAt = t
	if MonsterBrain.onDamaged(m.brain, m.def, result.amount, t) then
		m.token += 1
		local e = action(m, "stagger")
		e.endsAt = m.brain.stateEndsAt
		broadcast(m, e)
	end
	local s = m.structure
	if s then
		setHealthAttribute(m)
		if s.kind == "titan" then
			alertUntil[s.team] = t + config().structures.alertSeconds
		end
	end
end

-- Spawning -----------------------------------------------------------------------------------

-- Signature "armoredFront": hits from the front half do no damage.
local function armoredFront(m: Monster): (source: CombatService.Entry?) -> number
	return function(source: CombatService.Entry?): number
		local p = source and source.position()
		if p == nil then
			return 1
		end
		local fx, fz = -math.sin(m.row.yaw), -math.cos(m.row.yaw)
		local dx, dz = p.X - m.row.x, p.Z - m.row.z
		return if dx * fx + dz * fz > 0 then 0 else 1
	end
end

spawnMonster = function(
	id: string,
	position: Vector3,
	team: number?,
	structure: Structures.Structure?,
	options: SpawnOptions?
): Monster
	local def: Config.MonsterDefinition? = config().monsters[id]
	assert(def, `unknown monster {id}`)
	local opts: SpawnOptions = options or {}
	if opts.follow then
		-- Pets fight with their attacks but never summon.
		local petDef = table.clone(def)
		local attacks: { Config.MonsterAttack } = {}
		for _, attack in def.attacks do
			if attack.primitive ~= "summon" then
				table.insert(attacks, attack)
			end
		end
		petDef.attacks = attacks
		def = petDef
	end
	local scale: number = if structure
		then healthScaleOverride or config().structures.healthScale
		else (opts.healthScale or 1) * Tuning.get("enemyHealthScale")
	local m: Monster
	local row = NpcService.spawnCustom({
		label = id,
		position = position,
		team = team,
		maxHealth = math.max(1, math.floor(def.maxHealth * scale + 0.5)),
		radius = def.radius * (opts.scale or 1),
		scale = opts.scale,
		speed = def.speed,
		damage = 0,
		defence = def.defence,
		pushable = false,
		-- Structures and camp monsters survive /clearnpcs (camps and rounds manage them).
		persistent = structure ~= nil or opts.camp ~= nil,
		tick = function(_row: NpcService.Row, t: number, dt: number)
			tickMonster(m, t, dt)
		end,
		onHit = function(_row: NpcService.Row, result: Damage.Result)
			onDamaged(m, result)
		end,
	})
	row.entry.scoresKill = false
	-- Only structure kills go to the kill feed (not jungle monsters, summons or gym monsters).
	row.entry.announceKills = structure ~= nil
	if opts.follow then
		-- Pets are companions: never targeted, never damaged.
		row.entry.gated = true
		row.entry.combatant.protected = true
	end
	local t = now()
	m = {
		row = row,
		id = id,
		def = def,
		brain = MonsterBrain.new(t),
		structure = structure,
		target = 0,
		retargetAt = 0,
		-- Lane units never sleep (they march).
		awake = opts.lane ~= nil or opts.follow ~= nil,
		wakeCheckAt = t,
		busyAt = t,
		provokers = {},
		token = 0,
		ax = position.X,
		az = position.Z,
		dx = 0,
		dz = -1,
		camp = opts.camp,
		damageScale = opts.damageScale or 1,
		healthScale = opts.healthScale or 1,
		burrowed = false,
		summons = {},
		chargeLength = nil,
		lane = opts.lane,
		laneDistance = 0,
		ownerId = opts.owner,
		follow = opts.follow,
	}
	if def.signature == "armoredFront" then
		row.entry.damageFilter = armoredFront(m)
	end
	-- Face the enemy base.
	if team then
		row.yaw = if team == 1 then -math.pi / 2 else math.pi / 2
	end
	monsters[row.id] = m
	MonsterService.spawned:fire(m)
	return m
end

-- Spawns a monster by definition ID (gym, camps and dev use). Returns the monster.
function MonsterService.spawn(id: string, position: Vector3, team: number?, options: SpawnOptions?): Monster
	return spawnMonster(id, position, team, nil, options)
end

-- Removes a monster without it dying (camp resets, dev tools).
function MonsterService.remove(m: Monster)
	m.token += 1
	monsters[m.row.id] = nil
	NpcService.despawn(m.row.id)
end

function MonsterService.definitionIds(): { string }
	local ids = {}
	for id in config().monsters do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function MonsterService.monster(npcId: number): Monster?
	return monsters[npcId]
end

local function spawnStructures()
	for _, s in Structures.list(Map.get()) do
		local m = spawnMonster(s.kind, Vector3.new(s.position.x, 0, s.position.z), s.team, s)
		structures[s.key] = m
		setHealthAttribute(m)
	end
	updateGating()
end

-- Removes every structure and spawns fresh ones (round reset).
function MonsterService.resetStructures()
	for _, m in structures do
		m.token += 1
		monsters[m.row.id] = nil
		NpcService.despawn(m.row.id)
	end
	table.clear(structures)
	table.clear(dead)
	alertUntil[1], alertUntil[2] = 0, 0
	table.clear(projectiles)
	spawnStructures()
end

-- Dev: multiply structure health from the next reset (nil returns to Config).
function MonsterService.setStructureHealthScale(scale: number?)
	healthScaleOverride = if scale then math.clamp(scale, 0.01, 10) else nil
end

function MonsterService.structure(key: string): Monster?
	return structures[key]
end

function MonsterService.structureList(): { Monster }
	local list: { Monster } = {}
	for _, m in structures do
		table.insert(list, m)
	end
	table.sort(list, function(a: Monster, b: Monster): boolean
		return (a.structure :: Structures.Structure).key < (b.structure :: Structures.Structure).key
	end)
	return list
end

function MonsterService.isDead(key: string): boolean
	return dead[key] == true
end

-- How many monsters are awake (perf report).
function MonsterService.awakeCount(): (number, number)
	local awake, total = 0, 0
	for id, m in monsters do
		-- Removed without dying (dev despawns): forget it.
		if NpcService.row(id) ~= m.row then
			monsters[id] = nil
			continue
		end
		total += 1
		if m.awake then
			awake += 1
		end
	end
	return awake, total
end

-- Projectiles --------------------------------------------------------------------------------

local function tickProjectiles(dt: number)
	if #projectiles == 0 or not Round.inputAllowed(RoundService.state().phase) then
		return
	end
	local t = now()
	for i = #projectiles, 1, -1 do
		local p = projectiles[i]
		local m = p.monster
		local attack = p.attack
		local remove = false
		if not m.row.alive then
			-- The source is gone (its team would be unknown); the bolt fizzles.
			remove = true
		else
			local stepLength = math.max(0, math.min((attack.speed or 0) * dt, (attack.reach or 0) - p.travelled))
			local nx, nz = p.x + p.dx * stepLength, p.z + p.dz * stepLength
			local radius = p.radius
			-- Everything the segment touches this frame, nearest first.
			local touched: { { entry: CombatService.Entry, along: number } } = {}
			CombatService.hostilesNear(
				m.row.team,
				(p.x + nx) / 2,
				(p.z + nz) / 2,
				stepLength / 2 + radius,
				function(entry: CombatService.Entry)
					if entry == m.row.entry or entry.gated or p.hit[entry.combatant.id] then
						return
					end
					local q = entry.position() :: Vector3
					if Shapes.segmentDistance(p.x, p.z, nx, nz, q.X, q.Z) <= radius + entry.radius then
						table.insert(touched, { entry = entry, along = (q.X - p.x) * p.dx + (q.Z - p.z) * p.dz })
					end
				end
			)
			table.sort(touched, function(a, b)
				return a.along < b.along
			end)
			p.x, p.z = nx, nz
			p.travelled += stepLength
			if p.carrier then
				-- A charge carries its monster along the path.
				m.row.x, m.row.z = nx, nz
				CombatService.moved(m.row.entry)
			end
			for _, hit in touched do
				p.hit[hit.entry.combatant.id] = true
				local result = CombatService.applyHit(
					m.row.entry.combatant.id,
					hit.entry.combatant.id,
					attack.damage * m.damageScale,
					"monster",
					Vector3.new(p.dx, 0, p.dz) * attack.knockback,
					t,
					attack.heavy == true
				)
				-- A bolt stops at the first body it hurts (a dodged bolt flies on through); a
				-- charge goes through everything.
				if not p.carrier and result ~= nil and result.applied then
					remove = true
					break
				end
			end
			if p.travelled >= (attack.reach or 0) - 1e-6 then
				remove = true
			end
		end
		if remove then
			table.remove(projectiles, i)
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------

function MonsterService.init(_self: typeof(MonsterService))
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = ReplicatedStorage
	folder = f

	CombatService.killed:connect(function(victimId: number, killerId: number, assists: { number })
		if victimId >= 0 then
			return
		end
		local m = monsters[-victimId]
		if m == nil then
			return
		end
		MonsterBrain.kill(m.brain)
		m.token += 1
		m.row.state = S.idle
		m.row.aux = 0
		local npcId = m.row.id
		task.delay(1, function()
			if monsters[npcId] == m then
				monsters[npcId] = nil
			end
		end)
		-- Signature "splits": the pieces join the same camp before the death is reported, so the
		-- camp is not counted as cleared in between.
		local split = m.def.split
		if m.def.signature == "splits" and split then
			for i = 1, split.count do
				local angle = (i / split.count) * 2 * math.pi
				local r = m.def.radius
				local piece = spawnMonster(
					split.id,
					Vector3.new(m.row.x + math.cos(angle) * r, 0, m.row.z + math.sin(angle) * r),
					m.row.team,
					nil,
					{ camp = m.camp, healthScale = m.healthScale, damageScale = m.damageScale }
				)
				piece.row.home = m.row.home
				piece.awake = true
			end
		end
		MonsterService.died:fire(m, killerId)
		local s = m.structure
		if s == nil or structures[s.key] ~= m then
			return
		end
		dead[s.key] = true
		setHealthAttribute(m)
		updateGating()
		MonsterService.structureDestroyed:fire(s, killerId, assists)
		if s.kind == "titan" then
			RoundService.finish(3 - s.team)
		end
	end)

	-- Provocation: a hostile who hurts a guardian's teammate nearby becomes its first target.
	CombatService.damaged:connect(function(targetId: number, sourceId: number)
		local target = CombatService.entry(targetId)
		local source = CombatService.entry(sourceId)
		if target == nil or source == nil or target.kind == "minion" or source.kind == "minion" then
			return
		end
		if target.scoresKill == false or source.scoresKill == false then
			-- Structures and monsters do not provoke or get provoked on their behalf.
			return
		end
		local team = target.combatant.team
		local p = target.position()
		if team == nil or p == nil then
			return
		end
		local t = now()
		local range = config().structures.provokeRange
		for _, m in structures do
			if m.row.team == team and m.row.alive then
				local dx, dz = p.X - m.row.x, p.Z - m.row.z
				if dx * dx + dz * dz <= range * range then
					m.provokers[sourceId] = t + config().structures.provokeSeconds
					m.retargetAt = 0
					m.awake = true
				end
			end
		end
	end)

	MinionService.siegeTarget = function(team: number): CombatService.Entry?
		local m = structures[Structures.key("titan", team)]
		if m and m.row.alive then
			return m.row.entry
		end
		return nil
	end

	CharacterService.respawnScale = function(player: Player): number
		local team = TeamService.teamOf(player)
		if team and (alertUntil[team] or 0) > now() then
			return config().structures.defenderRespawnScale
		end
		return 1
	end

	RoundService.phaseChanged:connect(function()
		updateGating()
	end)
	RoundService.roundReset:connect(function()
		MonsterService.resetStructures()
		-- Unleashed monsters belong to the round that hatched them.
		for _, m in monsters do
			if m.lane and m.row.alive then
				MonsterService.remove(m)
			end
		end
	end)

	local window, frames, cost = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		local started = os.clock()
		tickProjectiles(dt)
		cost += os.clock() - started
		frames += 1
		window += dt
		if window >= 1 then
			MonsterService.projectileCost = cost / frames
			window, frames, cost = 0, 0, 0
		end
	end)
end

function MonsterService.start(_self: typeof(MonsterService))
	spawnStructures()
	-- Titan alerts for the HUD, once a second.
	while true do
		local t = now()
		for team = 1, 2 do
			local alert = alertUntil[team] > t
			local key = `T{team}_alert`
			if folder:GetAttribute(key) ~= alert then
				folder:SetAttribute(key, alert)
			end
		end
		task.wait(1)
	end
end

return MonsterService
