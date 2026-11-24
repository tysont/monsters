--!strict
-- Dev-only acceptance test: can every telegraphed attack be avoided by reacting to it?
--
-- `run` spawns a monster in the combat gym and a reactor bot next to it. The bot moves between
-- three distances from the monster (close, mid, far) so every attack gets used. Whenever a
-- telegraph covers it, it waits a human reaction time and then either walks straight out of the
-- shape at walking speed ("walk"), dodges through the impact with the player dodge path
-- ("dodge"), or does nothing ("stand", the control). The report counts telegraphs that covered
-- the bot and hits it took.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local Map = require(ReplicatedStorage.Shared.Map)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Shapes = require(ReplicatedStorage.Shared.Combat.Shapes)
local Stats = require(ReplicatedStorage.Shared.Combat.Stats)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CombatService = require("./CombatService")
local CampService = require("./CampService")
local GymService = require("./GymService")
local MonsterService = require("./MonsterService")
local NpcService = require("./NpcService")

local REACTION = 0.25
local BOT_RADIUS = 1.5
-- Seconds at each distance band before moving to the next.
local BAND_SECONDS = 6

export type Mode = "walk" | "dodge" | "stand"

local AvoidTestService = {
	name = "AvoidTestService",
	dependencies = { "CampService", "CombatService", "GymService", "MonsterService", "NpcService" },
}

local running = false

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Whether the telegraph covers (x, z), and which way to walk to leave it.
local function covers(e: Remotes.MonsterActionEvent, x: number, z: number): (boolean, number, number)
	if e.shape == "circle" then
		if not Shapes.inCircle(e.x, e.z, e.radius, x, z, BOT_RADIUS) then
			return false, 0, 0
		end
		local dx, dz = x - e.x, z - e.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < 1e-3 then
			return true, 1, 0
		end
		return true, dx / d, dz / d
	elseif e.shape == "cone" then
		if not Shapes.inCone(e.x, e.z, e.dx, e.dz, e.reach, e.arc, x, z, BOT_RADIUS) then
			return false, 0, 0
		end
		-- Shortest way out: straight across the nearest edge, or back out past the reach.
		local vx, vz = x - e.x, z - e.z
		local d = math.sqrt(vx * vx + vz * vz)
		local side = if (e.dx * vz - e.dz * vx) >= 0 then 1 else -1
		local ex, ez = Shapes.rotate(e.dx, e.dz, side * e.arc / 2)
		-- Outward normal of that edge.
		local nx, nz = Shapes.rotate(ex, ez, side * 90)
		local acrossEdge = math.max(0, -(vx * nx + vz * nz)) + BOT_RADIUS
		local backOut = e.reach + BOT_RADIUS - d
		if e.arc < 180 and acrossEdge <= backOut then
			return true, nx, nz
		end
		if d < 1e-3 then
			return true, e.dx, e.dz
		end
		return true, vx / d, vz / d
	else
		local inside = false
		for _, dir in Shapes.fan(e.dx, e.dz, math.max(1, e.count), e.spread) do
			local bx, bz = e.x + dir.x * e.reach, e.z + dir.z * e.reach
			if Shapes.segmentDistance(e.x, e.z, bx, bz, x, z) <= e.radius + BOT_RADIUS then
				inside = true
			end
		end
		if not inside then
			return false, 0, 0
		end
	end
	-- Cones and lines: step sideways off the centre line, on the side we are already on.
	local vx, vz = x - e.x, z - e.z
	local side = if (e.dx * vz - e.dz * vx) >= 0 then 1 else -1
	return true, -e.dz * side, e.dx * side
end

-- Shared with the class bots (ClassBotService).
AvoidTestService.covers = covers

local function breakdown(coveredBy: { [string]: number }, hitsBy: { [string]: number }): string
	local parts = {}
	for _, shape in { "circle", "cone", "line" } do
		if coveredBy[shape] then
			table.insert(parts, `{shape} {hitsBy[shape] or 0}/{coveredBy[shape]}`)
		end
	end
	return if #parts > 0 then " Hits/covered: " .. table.concat(parts, ", ") .. "." else ""
end

-- Runs the test for `seconds` and calls `report` with the result.
function AvoidTestService.run(
	monsterId: string,
	mode: Mode,
	seconds: number,
	healthFraction: number,
	report: (message: string) -> ()
): string
	if running then
		return "An avoid test is already running."
	end
	local def = Config.get().monsters[monsterId]
	if def == nil then
		return `Unknown monster {monsterId}.`
	end
	running = true
	local center = GymService.point(0, -20)
	local npcId = MonsterService.spawn(monsterId, center, nil).row.id
	local monster = MonsterService.monster(npcId)
	if monster and healthFraction < 1 then
		local c = monster.row.entry.combatant
		c.health = math.max(1, c.maxHealth * healthFraction)
	end

	local covered, hits, escapes = 0, 0, 0
	-- Per shape: telegraphs that covered the bot and hits taken, attributed to the last covering
	-- telegraph.
	local coveredBy: { [string]: number } = {}
	local hitsBy: { [string]: number } = {}
	local lastShape = "none"
	local moveUntil, vx, vz = 0, 0, 0
	local bands = { def.radius + 3, def.radius + 12, def.radius + 24 }
	local startedAt = now()
	local walk = Map.get().walkSpeed

	local bot = NpcService.spawnCustom({
		label = "bot",
		position = center + Vector3.new(0, 0, bands[1]),
		team = 1,
		maxHealth = 1e7,
		radius = BOT_RADIUS,
		speed = walk,
		damage = 0,
		defence = 0,
		pushable = true,
		persistent = false,
		tick = function(row: NpcService.Row, t: number, dt: number)
			if t < moveUntil then
				row.x += vx * dt
				row.z += vz * dt
				row.x, row.z = GymService.clamp(row.x, row.z, 2)
				return
			end
			-- Walk to the current band's standing spot.
			local band = bands[(math.floor((t - startedAt) / BAND_SECONDS) % #bands) + 1]
			local gx, gz = center.X, center.Z + band
			local dx, dz = gx - row.x, gz - row.z
			local d = math.sqrt(dx * dx + dz * dz)
			if d > 0.5 then
				local stepLength = math.min(walk * dt, d)
				row.x += dx / d * stepLength
				row.z += dz / d * stepLength
			end
		end,
		onHit = function(_row: NpcService.Row, result: Damage.Result)
			if result.applied then
				hits += 1
				hitsBy[lastShape] = (hitsBy[lastShape] or 0) + 1
			end
		end,
	})
	bot.entry.scoresKill = false

	local disconnect = MonsterService.telegraphed:connect(function(e: Remotes.MonsterActionEvent)
		if e.id ~= npcId or not bot.alive then
			return
		end
		local inside, ex, ez = covers(e, bot.x, bot.z)
		if not inside then
			return
		end
		covered += 1
		lastShape = e.shape
		coveredBy[e.shape] = (coveredBy[e.shape] or 0) + 1
		if mode == "walk" then
			task.delay(REACTION, function()
				-- Walk out until the shape lands (bolts: until they have flown past).
				local flight = if e.speed > 0 then e.reach / e.speed else 0
				moveUntil = math.max(e.endsAt + 0.15, now()) + flight * 0.5
				vx, vz = ex * walk, ez * walk
				escapes += 1
			end)
		elseif mode == "dodge" then
			-- Dodge just before impact so the invulnerability covers it (bolts: when they arrive).
			local dx, dz = bot.x - e.x, bot.z - e.z
			local arrive = if e.speed > 0 then math.sqrt(dx * dx + dz * dz) / e.speed else 0
			local at = e.endsAt + arrive - Tuning.get("iframes") / 2
			-- Hold still until the dodge, so the timing read off the telegraph stays right.
			moveUntil, vx, vz = at, 0, 0
			task.delay(math.max(REACTION, at - now()), function()
				CombatService.dodge(bot.entry, now())
				local duration = Config.get().combat.dodgeDuration
				moveUntil = now() + duration
				local speed = Tuning.get("dodgeDistance") / duration
				vx, vz = ex * speed, ez * speed
				escapes += 1
			end)
		end
	end)

	task.delay(seconds, function()
		disconnect()
		running = false
		NpcService.despawn(bot.id)
		NpcService.despawn(npcId)
		report(
			`Avoid test {monsterId} ({mode}, {seconds} s, health {math.floor(healthFraction * 100)}%): `
				.. `{covered} telegraph(s) covered the bot, {escapes} reaction(s), {hits} hit(s) taken.`
				.. breakdown(coveredBy, hitsBy)
		)
	end)
	return `Avoid test started: {monsterId}, mode {mode}, {seconds} s. Results in chat when done.`
end

-- Solo clear test: a duelist bot with Knight stats at `level` (the stubbed stat function) fights
-- camp `index` the way a careful player would: it closes in (behind armoured monsters), swings
-- with the player melee path, and dodges every telegraph that covers it. Reports how long the
-- clear took from the first hit, and the bot's health left.
function AvoidTestService.clearTest(
	index: number,
	level: number,
	timeout: number,
	report: (message: string) -> ()
): string
	if running then
		return "A test is already running."
	end
	local campPosition = CampService.position(index)
	if campPosition == nil then
		return `No camp {index} (1 to {CampService.count()}).`
	end
	running = true
	local stats = Stats.compute(Config.get().classDefinitions.knight.stats, level)
	local walk = Map.get().walkSpeed
	local moveUntil, vx, vz = 0, 0, 0
	local lastSwing = -math.huge
	local done = false
	local startedAt = now()

	local bot = NpcService.spawnCustom({
		label = "bot",
		position = campPosition + Vector3.new(0, 0, 40),
		team = 1,
		maxHealth = stats.maxHealth,
		radius = BOT_RADIUS,
		speed = walk,
		damage = stats.damage,
		defence = stats.defence,
		pushable = true,
		persistent = false,
		tick = function(row: NpcService.Row, t: number, dt: number)
			if t < moveUntil then
				row.x += vx * dt
				row.z += vz * dt
				return
			end
			local target = CombatService.nearestHostile(row.entry, 80)
			if target == nil then
				-- Walk to the camp.
				local dx, dz = campPosition.X - row.x, campPosition.Z - row.z
				local d = math.sqrt(dx * dx + dz * dz)
				if d > 3 then
					row.x += dx / d * math.min(walk * dt, d)
					row.z += dz / d * math.min(walk * dt, d)
				end
				return
			end
			local p = target.position() :: Vector3
			local monster = if target.combatant.id < 0 then MonsterService.monster(-target.combatant.id) else nil
			-- Where to stand: behind armoured monsters, otherwise just inside sword reach.
			local gx, gz
			local reach = target.radius + BOT_RADIUS + 2.5
			if monster and monster.def.signature == "armoredFront" then
				gx = p.X + math.sin(monster.row.yaw) * reach
				gz = p.Z + math.cos(monster.row.yaw) * reach
			else
				local ax, az = row.x - p.X, row.z - p.Z
				local ad = math.max(1e-3, math.sqrt(ax * ax + az * az))
				gx, gz = p.X + ax / ad * reach, p.Z + az / ad * reach
			end
			local mx, mz = gx - row.x, gz - row.z
			local md = math.sqrt(mx * mx + mz * mz)
			if md > 0.5 then
				local stepLength = math.min(walk * dt, md)
				row.x += mx / md * stepLength
				row.z += mz / md * stepLength
			end
			local fx, fz = p.X - row.x, p.Z - row.z
			local fd = math.sqrt(fx * fx + fz * fz)
			if fd > 1e-3 then
				row.yaw = math.atan2(-fx, -fz)
			end
			if t - lastSwing >= Tuning.get("attackCooldown") and fd - target.radius <= Tuning.get("attackRange") then
				lastSwing = t
				CombatService.meleeSwing(row.entry, Vector3.new(fx / fd, 0, fz / fd), 0, t)
			end
		end,
	})
	bot.entry.power = stats.power

	local disconnectTelegraph = MonsterService.telegraphed:connect(function(e: Remotes.MonsterActionEvent)
		if not bot.alive then
			return
		end
		local inside, ex, ez = covers(e, bot.x, bot.z)
		if not inside then
			return
		end
		local dx, dz = bot.x - e.x, bot.z - e.z
		local arrive = if e.speed > 0 then math.sqrt(dx * dx + dz * dz) / e.speed else 0
		local at = e.endsAt + arrive - Tuning.get("iframes") / 2
		moveUntil, vx, vz = at, 0, 0
		task.delay(math.max(REACTION, at - now()), function()
			CombatService.dodge(bot.entry, now())
			local duration = Config.get().combat.dodgeDuration
			moveUntil = now() + duration
			local speed = Tuning.get("dodgeDistance") / duration
			vx, vz = ex * speed, ez * speed
		end)
	end)

	local function finish(message: string)
		if done then
			return
		end
		done = true
		running = false
		disconnectTelegraph()
		local health = math.floor(bot.entry.combatant.health)
		NpcService.despawn(bot.id)
		report(`{message} Duelist level {level}: {health}/{stats.maxHealth} health left.`)
	end
	local disconnectCleared: () -> ()
	disconnectCleared = CampService.cleared:connect(function(cleared: number, _killer: number, seconds: number)
		if cleared == index then
			disconnectCleared()
			finish(`Camp {index} cleared in {string.format("%.1f", seconds)} s from the first hit.`)
		end
	end)
	task.spawn(function()
		while not done do
			task.wait(0.5)
			if not bot.alive then
				disconnectCleared()
				finish(`The duelist was defeated at camp {index} after {math.floor(now() - startedAt)} s.`)
			elseif now() - startedAt > timeout then
				disconnectCleared()
				finish(`Camp {index} not cleared within {timeout} s.`)
			end
		end
	end)
	return `Clear test started at camp {index} with a level {level} duelist.`
end

return AvoidTestService
