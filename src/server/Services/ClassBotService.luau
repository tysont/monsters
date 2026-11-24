--!strict
-- Dev-only class bots for the Phase 10 balance pass and performance gate. Each bot plays one
-- class the way a sensible player would, through the real ability path (AbilityService.cast):
--
--   Knight  closes in, charges from range, rallies (taunt and shield) when a fight starts, bashes
--           up close, swings the sword.
--   Hunter  keeps 20 to 30 studs away: arrows, volley up close, a trap under the target, marks.
--   Mage    keeps about 20 studs away: bolts, fireballs on the target, frost nova when crowded,
--           prison on the target.
--   Healer  stays near the group: mends the most hurt ally, sanctuary when several are hurt,
--           barrier in a fight, smites otherwise.
--
-- Every bot dodges telegraphs that cover it (reaction time, then a dodge through the impact),
-- respects stuns and slows, and casts at most once per BOT_GCD. Their XP is tallied in
-- ProgressionService's bot ledger (as if they were players).
--
--   groupClear  four bots clear a jungle camp; reports the time, deaths and each bot's XP.
--   skirmish    two teams of mixed bots fight around the middle lane with minion waves on for a
--               while; reports XP by class (healer versus damage classes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Classes = require(ReplicatedStorage.Shared.Classes)
local Config = require(ReplicatedStorage.Shared.Config)
local Map = require(ReplicatedStorage.Shared.Map)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Stats = require(ReplicatedStorage.Shared.Combat.Stats)
local Status = require(ReplicatedStorage.Shared.Combat.Status)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local AbilityService = require("./AbilityService")
local AvoidTestService = require("./AvoidTestService")
local CampService = require("./CampService")
local GymService = require("./GymService")
local CombatService = require("./CombatService")
local MinionService = require("./MinionService")
local MonsterService = require("./MonsterService")
local NpcService = require("./NpcService")
local ProgressionService = require("./ProgressionService")

local BOT_RADIUS = 1.5
local BOT_GCD = 0.35
local REACTION = 0.25
-- Like people, bots sometimes react too late to a telegraph.
local MISS_CHANCE = 0.25
local RESPAWN_SECONDS = 8
local SIGHT = 80

type Entry = CombatService.Entry

-- One bot across its lives (each life is a new NPC row).
export type Bot = {
	classId: string,
	level: number,
	-- Pet power multiplier (1 = no pet, 1.2 = a maxed pet).
	pet: number,
	team: number,
	home: Vector3,
	row: NpcService.Row?,
	group: { Bot },
	-- Movement override (dodges) until this time.
	moveUntil: number,
	vx: number,
	vz: number,
	nextCastAt: number,
	-- Bots use the player dodge, with its cooldown.
	lastDodgeAt: number,
	deaths: number,
	xp: number,
	xpBy: { [string]: number },
	-- Damage taken and dealt across lives.
	taken: number,
	dealt: number,
	-- Where it should hang around when it has nothing to fight (skirmish), or nil.
	anchor: Vector3?,
	-- Whether it comes back after dying (skirmish). In a camp clear a death means respawning at
	-- base and walking back, which takes longer than the fight: the bot is out.
	respawns: boolean,
	active: boolean,
}

local ClassBotService = {
	name = "ClassBotService",
	dependencies = {
		"AbilityService",
		"AvoidTestService",
		"CampService",
		"CombatService",
		"GymService",
		"MinionService",
		"MonsterService",
		"NpcService",
		"ProgressionService",
	},
}

local bots: { Bot } = {}
local byRow: { [number]: Bot } = {}
local running = false

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rules(): Status.Rules
	return Config.get().classes.status
end

local function entryOf(bot: Bot): Entry?
	local row = bot.row
	return if row and row.alive then row.entry else nil
end

local function distance2(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	return math.sqrt(dx * dx + dz * dz)
end

-- Moves a row towards (gx, gz) until it is `stop` away, at `speed`.
local function walk(row: NpcService.Row, gx: number, gz: number, stop: number, speed: number, dt: number)
	local dx, dz = gx - row.x, gz - row.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d > stop and d > 0.3 then
		local step = math.min(speed * dt, d - stop)
		row.x += dx / d * step
		row.z += dz / d * step
	end
end

-- Keeps a distance band from a point: closer than `near` backs off, farther than `far` closes.
local function keepBand(
	row: NpcService.Row,
	px: number,
	pz: number,
	near: number,
	far: number,
	speed: number,
	dt: number
)
	local d = distance2(row.x, row.z, px, pz)
	if d < near then
		local dx, dz = row.x - px, row.z - pz
		local len = math.max(1e-3, math.sqrt(dx * dx + dz * dz))
		row.x += dx / len * speed * dt
		row.z += dz / len * speed * dt
	elseif d > far then
		walk(row, px, pz, far, speed, dt)
	end
end

local function face(row: NpcService.Row, px: number, pz: number)
	local fx, fz = px - row.x, pz - row.z
	if fx * fx + fz * fz > 1e-6 then
		row.yaw = math.atan2(-fx, -fz)
	end
end

local function cast(bot: Bot, slot: number, direction: Vector3, point: Vector3?): boolean
	local entry = entryOf(bot)
	local t = now()
	if entry == nil or t < bot.nextCastAt then
		return false
	end
	local reason = AbilityService.cast(entry, slot, { direction = direction, point = point })
	if reason == nil then
		bot.nextCastAt = t + BOT_GCD
		return true
	end
	return false
end

local function dirTo(row: NpcService.Row, p: Vector3): Vector3
	local d = Vector3.new(p.X - row.x, 0, p.Z - row.z)
	return if d.Magnitude > 1e-3 then d.Unit else Vector3.new(0, 0, -1)
end

-- The most hurt living ally in the bot's group (by health fraction), and its fraction.
local function mostHurt(bot: Bot): (Entry?, number)
	local best: Entry? = nil
	local bestFraction = 1
	for _, other in bot.group do
		local e = entryOf(other)
		if e then
			local c = e.combatant
			local f = c.health / c.maxHealth
			if f < bestFraction then
				best, bestFraction = e, f
			end
		end
	end
	return best, bestFraction
end

local function hurtCount(bot: Bot, below: number): number
	local n = 0
	for _, other in bot.group do
		local e = entryOf(other)
		if e and e.combatant.health / e.combatant.maxHealth < below then
			n += 1
		end
	end
	return n
end

-- The centre of the bot's living group and how many are within 12 studs of it.
local function groupCentre(bot: Bot): (number, number, number)
	local sx, sz, n = 0, 0, 0
	local points: { Vector3 } = {}
	for _, other in bot.group do
		local e = entryOf(other)
		local p = e and e.position()
		if p then
			sx += p.X
			sz += p.Z
			n += 1
			table.insert(points, p)
		end
	end
	if n == 0 then
		return 0, 0, 0
	end
	local cx, cz = sx / n, sz / n
	local near = 0
	for _, p in points do
		if distance2(cx, cz, p.X, p.Z) <= 12 then
			near += 1
		end
	end
	return cx, cz, near
end

local function alliesWithin(bot: Bot, row: NpcService.Row, range: number): number
	local n = 0
	for _, other in bot.group do
		local e = entryOf(other)
		local p = e and e.position()
		if p and distance2(row.x, row.z, p.X, p.Z) <= range then
			n += 1
		end
	end
	return n
end

-- A living ally that deals damage (not a healer) and is not empowered, if any.
local function unblessedDealer(bot: Bot): Entry?
	local t = now()
	for _, other in bot.group do
		local e = entryOf(other)
		if e and other.classId ~= "healer" and not Status.has(e.combatant.statuses, "empower", t) then
			return e
		end
	end
	return nil
end

local function slotReady(bot: Bot, slot: number): boolean
	local class = Classes[bot.classId]
	local ability = if slot == 0 then class.basic else class.abilities[slot]
	return ability ~= nil and bot.level >= ability.unlockLevel
end

-- Class behaviour for one tick with a target in sight.
local function fight(bot: Bot, row: NpcService.Row, target: Entry, speed: number, dt: number)
	local p = target.position() :: Vector3
	local d = distance2(row.x, row.z, p.X, p.Z) - target.radius
	local dir = dirTo(row, p)
	face(row, p.X, p.Z)
	local id = bot.classId
	if id == "knight" then
		local reach = Tuning.get("attackRange") - 1
		if d > 8 and d < 22 and slotReady(bot, 1) and cast(bot, 1, dir) then
			return
		end
		walk(row, p.X, p.Z, target.radius + BOT_RADIUS + reach * 0.6, speed, dt)
		if d < 14 and slotReady(bot, 2) and cast(bot, 2, dir) then
			return
		end
		if d < 8 and slotReady(bot, 3) and cast(bot, 3, dir) then
			return
		end
		if d <= reach then
			cast(bot, 0, dir)
		end
	elseif id == "hunter" then
		keepBand(row, p.X, p.Z, 16 + target.radius, 28 + target.radius, speed, dt)
		if slotReady(bot, 3) and d < 55 and cast(bot, 3, dir) then
			return
		end
		if slotReady(bot, 2) and d < 26 and cast(bot, 2, dir, p) then
			return
		end
		if slotReady(bot, 1) and d < 28 and cast(bot, 1, dir) then
			return
		end
		if d < 42 then
			cast(bot, 0, dir)
		end
	elseif id == "mage" then
		keepBand(row, p.X, p.Z, 14 + target.radius, 24 + target.radius, speed, dt)
		if slotReady(bot, 3) and d < 33 and cast(bot, 3, dir, p) then
			return
		end
		if slotReady(bot, 2) and d < 9 and cast(bot, 2, dir) then
			return
		end
		if slotReady(bot, 1) and d < 38 and cast(bot, 1, dir, p) then
			return
		end
		if d < 34 then
			cast(bot, 0, dir)
		end
	else
		-- Healer: heal first, fight second; stay with the group.
		local hurt, fraction = mostHurt(bot)
		if hurt and fraction < 0.7 then
			local hp = hurt.position()
			if hp then
				walk(row, hp.X, hp.Z, 18, speed, dt)
				if cast(bot, 1, dirTo(row, hp)) then
					return
				end
			end
		end
		-- Sanctuary on the group when several are hurt or bunched up in the fight.
		local cx, cz, near = groupCentre(bot)
		if slotReady(bot, 2) and (hurtCount(bot, 0.85) >= 2 or near >= 3) then
			if cast(bot, 2, dirTo(row, Vector3.new(cx, 0, cz)), Vector3.new(cx, 0, cz)) then
				return
			end
		end
		-- Barrier whenever allies are around in a fight (shield and blessing).
		if slotReady(bot, 3) and alliesWithin(bot, row, 16) >= 2 and cast(bot, 3, dir) then
			return
		end
		-- Keep the blessing up: mend a damage dealer who is not empowered.
		local unblessed = unblessedDealer(bot)
		local up = unblessed and unblessed.position()
		if up then
			walk(row, up.X, up.Z, 22, speed, dt)
			if cast(bot, 1, dirTo(row, up)) then
				return
			end
		end
		keepBand(row, p.X, p.Z, 16 + target.radius, 26 + target.radius, speed, dt)
		if d < 32 then
			cast(bot, 0, dir)
		end
	end
end

local spawnLife: (bot: Bot) -> ()

local function tick(bot: Bot, row: NpcService.Row, t: number, dt: number)
	local entry = row.entry
	local statuses = entry.combatant.statuses
	if Status.stunned(statuses, t) then
		return
	end
	local speed = Map.get().walkSpeed * Status.speedMultiplier(statuses, t, rules())
	if t < bot.moveUntil then
		row.x += bot.vx * dt
		row.z += bot.vz * dt
		return
	end
	local target = CombatService.nearestHostile(entry, SIGHT)
	if target and target.kind == "minion" and bot.anchor == nil then
		target = nil
	end
	if target then
		fight(bot, row, target, speed, dt)
		return
	end
	-- Nothing to fight: healers top the group up, everyone heads for the anchor or the group.
	if bot.classId == "healer" then
		local hurt, fraction = mostHurt(bot)
		local hp = hurt and hurt.position()
		if hurt and hp and fraction < 0.9 then
			walk(row, hp.X, hp.Z, 18, speed, dt)
			cast(bot, 1, dirTo(row, hp))
			return
		end
	end
	local anchor = bot.anchor or bot.home
	walk(row, anchor.X, anchor.Z, 4, speed, dt)
end

local function dodge(bot: Bot, e: Remotes.MonsterActionEvent)
	local row = bot.row
	if row == nil or not row.alive then
		return
	end
	local inside, ex, ez = AvoidTestService.covers(e, row.x, row.z)
	if not inside then
		return
	end
	if math.random() < MISS_CHANCE then
		return
	end
	local dx, dz = row.x - e.x, row.z - e.z
	local arrive = if e.speed > 0 then math.sqrt(dx * dx + dz * dz) / e.speed else 0
	local at = e.endsAt + arrive - Tuning.get("iframes") / 2
	bot.moveUntil, bot.vx, bot.vz = at, 0, 0
	task.delay(math.max(REACTION, at - now()), function()
		local entry = entryOf(bot)
		if entry == nil then
			return
		end
		if now() - bot.lastDodgeAt < Tuning.get("dodgeCooldown") then
			-- Still on cooldown: no dodge this time.
			bot.moveUntil = 0
			return
		end
		bot.lastDodgeAt = now()
		CombatService.dodge(entry, now())
		local duration = Config.get().combat.dodgeDuration
		bot.moveUntil = now() + duration
		local s = Tuning.get("dodgeDistance") / duration
		bot.vx, bot.vz = ex * s, ez * s
	end)
end

spawnLife = function(bot: Bot)
	if not bot.active then
		return
	end
	local class = Classes[bot.classId]
	local stats = Stats.compute(class.stats, bot.level, bot.pet)
	local row = NpcService.spawnCustom({
		label = "bot",
		position = bot.home,
		team = bot.team,
		maxHealth = stats.maxHealth,
		radius = BOT_RADIUS,
		speed = Map.get().walkSpeed,
		damage = stats.damage,
		defence = stats.defence,
		pushable = true,
		persistent = false,
		tick = function(r: NpcService.Row, t: number, dt: number)
			tick(bot, r, t, dt)
		end,
	})
	row.entry.classId = class.id
	row.entry.level = bot.level
	row.entry.power = stats.power
	bot.row = row
	bot.moveUntil = 0
	byRow[row.id] = bot
	ProgressionService.trackBot(row.entry.combatant.id)
end

-- Folds a life's XP into the bot's totals.
local function settle(bot: Bot)
	local row = bot.row
	if row == nil then
		return
	end
	local ledger = ProgressionService.untrackBot(row.entry.combatant.id)
	if ledger then
		bot.xp += ledger.total
		for reason, amount in ledger.byReason do
			bot.xpBy[reason] = (bot.xpBy[reason] or 0) + amount
		end
	end
	byRow[row.id] = nil
end

function ClassBotService.spawn(
	classId: string,
	level: number,
	team: number,
	home: Vector3,
	group: { Bot }?,
	pet: number?
): Bot
	local bot: Bot = {
		classId = classId,
		level = level,
		pet = pet or 1,
		team = team,
		home = home,
		row = nil,
		group = group or {},
		moveUntil = 0,
		vx = 0,
		vz = 0,
		nextCastAt = 0,
		lastDodgeAt = -math.huge,
		deaths = 0,
		xp = 0,
		xpBy = {},
		taken = 0,
		dealt = 0,
		anchor = nil,
		respawns = true,
		active = true,
	}
	table.insert(bot.group, bot)
	table.insert(bots, bot)
	spawnLife(bot)
	return bot
end

-- Removes every class bot. Returns how many there were.
function ClassBotService.clear(): number
	local n = #bots
	for _, bot in bots do
		bot.active = false
		settle(bot)
		local row = bot.row
		if row then
			NpcService.despawn(row.id)
		end
	end
	table.clear(bots)
	table.clear(byRow)
	return n
end

function ClassBotService.count(): number
	return #bots
end

local function xpLine(bot: Bot): string
	local parts = {}
	for reason, amount in bot.xpBy do
		table.insert(parts, `{reason} {math.floor(amount)}`)
	end
	table.sort(parts)
	return `{bot.classId} {math.floor(bot.xp)} XP ({table.concat(parts, ", ")}), dealt {math.floor(bot.dealt)}, took {math.floor(
		bot.taken
	)}, {bot.deaths} death(s)`
end

-- Four bots (one per class in `classes`) clear camp `index`. Reports when done.
function ClassBotService.groupClear(
	index: number,
	level: number,
	classes: { string },
	timeout: number,
	report: (string) -> ()
): string
	if running then
		return "A class bot test is already running."
	end
	local campPosition = CampService.position(index)
	if campPosition == nil then
		return `No camp {index}.`
	end
	for _, id in classes do
		if Classes[id] == nil then
			return `Unknown class {id}.`
		end
	end
	running = true
	ClassBotService.clear()
	local group: { Bot } = {}
	for i, id in classes do
		local offset = Vector3.new((i - 2.5) * 4, 0, 40)
		local bot = ClassBotService.spawn(id, level, 1, campPosition + offset, group)
		bot.respawns = false
	end
	local startedAt = now()
	local done = false
	local function finish(message: string)
		if done then
			return
		end
		done = true
		running = false
		local lines = { message }
		for _, bot in group do
			settle(bot)
			table.insert(lines, "  " .. xpLine(bot))
		end
		ClassBotService.clear()
		report(table.concat(lines, "\n"))
	end
	local disconnect: () -> ()
	disconnect = CampService.cleared:connect(function(cleared: number, _killer: number, seconds: number)
		if cleared == index then
			disconnect()
			-- Let the kill's XP land in the ledgers first.
			task.delay(0.2, function()
				finish(
					`Camp {index} ({table.concat(classes, ", ")}, level {level}) cleared in {string.format(
						"%.1f",
						seconds
					)} s from the first hit.`
				)
			end)
		end
	end)
	task.spawn(function()
		while not done do
			task.wait(0.5)
			local alive = 0
			for _, bot in group do
				if entryOf(bot) then
					alive += 1
				end
			end
			if alive == 0 then
				disconnect()
				finish(
					`Camp {index}: the group ({table.concat(classes, ", ")}) was wiped out after {math.floor(
						now() - startedAt
					)} s.`
				)
			elseif now() - startedAt > timeout then
				disconnect()
				finish(`Camp {index} not cleared within {timeout} s ({table.concat(classes, ", ")}).`)
			end
		end
	end)
	return `Group clear started at camp {index}: {table.concat(classes, ", ")} at level {level}.`
end

-- Two teams of `perTeam` bots (classes in rotation) fight around the middle of the middle lane
-- with minion waves on, for `seconds`. Reports XP per class.
function ClassBotService.skirmish(perTeam: number, level: number, seconds: number, report: (string) -> ()): string
	if running then
		return "A class bot test is already running."
	end
	running = true
	ClassBotService.clear()
	local order = { "knight", "hunter", "mage", "healer" }
	local groups: { { Bot } } = { {}, {} }
	for team = 1, 2 do
		local side = if team == 1 then -1 else 1
		for i = 1, perTeam do
			local home = Vector3.new(side * 70, 0, (i - perTeam / 2) * 5)
			local bot = ClassBotService.spawn(order[(i - 1) % #order + 1], level, team, home, groups[team])
			bot.anchor = Vector3.new(side * 10, 0, (i - perTeam / 2) * 3)
		end
	end
	MinionService.setForceWaves(true)
	task.delay(seconds, function()
		MinionService.setForceWaves(false)
		local totals: { [string]: { xp: number, n: number, deaths: number } } = {}
		local lines = { `Skirmish {perTeam}v{perTeam}, level {level}, {seconds} s: XP per bot by class` }
		for _, bot in bots do
			settle(bot)
			local t = totals[bot.classId] or { xp = 0, n = 0, deaths = 0 }
			t.xp += bot.xp
			t.n += 1
			t.deaths += bot.deaths
			totals[bot.classId] = t
		end
		for _, id in order do
			local t = totals[id]
			if t then
				table.insert(
					lines,
					`  {id}: {math.floor(t.xp / t.n)} XP per bot, {t.deaths} death(s) over {t.n} bot(s)`
				)
			end
		end
		local healerDetail = nil
		for _, bot in bots do
			if bot.classId == "healer" then
				healerDetail = xpLine(bot)
				break
			end
		end
		if healerDetail then
			table.insert(lines, "  e.g. " .. healerDetail)
		end
		ClassBotService.clear()
		running = false
		report(table.concat(lines, "\n"))
	end)
	return `Skirmish started: {perTeam} per team at level {level} for {seconds} s. Results in chat.`
end

-- Phase 11 acceptance: `count` new players (level 1, no pet) of `newClasses` against one maxed
-- player (level 500 with a maxed pet: power 1.5) of `maxClass`, in the combat gym. Reports who is
-- left standing.
function ClassBotService.duel(newClasses: { string }, maxClass: string, timeout: number, report: (string) -> ()): string
	if running then
		return "A class bot test is already running."
	end
	if Classes[maxClass] == nil then
		return `Unknown class {maxClass}.`
	end
	for _, id in newClasses do
		if Classes[id] == nil then
			return `Unknown class {id}.`
		end
	end
	running = true
	ClassBotService.clear()
	local newGroup: { Bot } = {}
	local maxGroup: { Bot } = {}
	for i, id in newClasses do
		local bot = ClassBotService.spawn(id, 1, 1, GymService.point(-25, (i - 2) * 6), newGroup)
		bot.respawns = false
		bot.anchor = GymService.point(0, 0)
	end
	local champion = ClassBotService.spawn(maxClass, 500, 2, GymService.point(25, 0), maxGroup, 1.2)
	champion.respawns = false
	champion.anchor = GymService.point(0, 0)
	local startedAt = now()
	local done = false
	local function alive(group: { Bot }): number
		local n = 0
		for _, bot in group do
			if entryOf(bot) then
				n += 1
			end
		end
		return n
	end
	task.spawn(function()
		while not done do
			task.wait(0.25)
			local newAlive, maxAlive = alive(newGroup), alive(maxGroup)
			local elapsed = now() - startedAt
			local message: string? = nil
			if maxAlive == 0 then
				message =
					`The {#newClasses} new players ({table.concat(newClasses, ", ")}) beat the maxed {maxClass} in {string.format(
						"%.1f",
						elapsed
					)} s with {newAlive} standing.`
			elseif newAlive == 0 then
				local e = entryOf(champion)
				local health = if e then math.floor(e.combatant.health / e.combatant.maxHealth * 100) else 0
				message =
					`The maxed {maxClass} beat the {#newClasses} new players in {string.format("%.1f", elapsed)} s with {health}% health left.`
			elseif elapsed > timeout then
				message = `No result within {timeout} s ({newAlive} new, {maxAlive} maxed standing).`
			end
			if message then
				done = true
				ClassBotService.clear()
				running = false
				report(message)
			end
		end
	end)
	return `Duel started: {table.concat(newClasses, ", ")} (level 1) against a maxed {maxClass}.`
end

-- Load: `perTeam` bots per team skirmishing indefinitely (until /classbots clear).
function ClassBotService.load(perTeam: number, level: number): string
	ClassBotService.clear()
	local order = { "knight", "hunter", "mage", "healer" }
	for team = 1, 2 do
		local group: { Bot } = {}
		local side = if team == 1 then -1 else 1
		for i = 1, perTeam do
			local lane = (i - 1) % 3
			local z = (lane - 1) * 280 + ((i - 1) // 3 - perTeam / 6) * 4
			local home = Vector3.new(side * 90, 0, z)
			local bot = ClassBotService.spawn(order[(i - 1) % #order + 1], level, team, home, group)
			bot.anchor = Vector3.new(side * 8, 0, z)
		end
	end
	return `{perTeam * 2} class bots fighting across the middle (clear with /classbots clear).`
end

function ClassBotService.init(_self: typeof(ClassBotService))
	MonsterService.telegraphed:connect(function(e: Remotes.MonsterActionEvent)
		for _, bot in bots do
			dodge(bot, e)
		end
	end)
	CombatService.damaged:connect(function(targetId: number, sourceId: number, amount: number)
		local target = if targetId < 0 then byRow[-targetId] else nil
		if target then
			target.taken += amount
		end
		local source = if sourceId < 0 then byRow[-sourceId] else nil
		if source then
			source.dealt += amount
		end
	end)
	CombatService.killed:connect(function(victimId: number)
		if victimId >= 0 then
			return
		end
		local bot = byRow[-victimId]
		if bot == nil then
			return
		end
		bot.deaths += 1
		-- Let kill and assist XP for this death land first.
		task.defer(function()
			settle(bot)
			bot.row = nil
			if bot.respawns then
				task.delay(RESPAWN_SECONDS, function()
					spawnLife(bot)
				end)
			end
		end)
	end)
end

return ClassBotService
