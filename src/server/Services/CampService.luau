--!strict
-- Jungle camps: 12 camps (Shared.Combat.Camps), each one monster of a jungle type at a tier set by
-- its distance from the centre line.
--
--   Spawning: the camp monster gets the tier's health and damage scale and belongs to the camp;
--     summons and split pieces join the camp too.
--   Leash: camp monsters walk home past their leash (MonsterService); a damaged camp with no
--     hostile nearby for a few seconds resets to fresh.
--   Group scaling: while a camp is fought, its health grows mildly with the number of distinct
--     attackers (never shrinks until reset).
--   Clear: when every member is dead the camp drops an egg of its type (rarity by tier) and
--     respawns after the tier's timer.
--   Sleep: the monsters sleep on their own (MonsterService); the camp itself ticks once a second.
-- Each camp's state replicates as an attribute on ReplicatedStorage.Camps: 0 while alive,
-- otherwise the server time it respawns (minimap).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Camps = require(ReplicatedStorage.Shared.Combat.Camps)
local CombatService = require("./CombatService")
local Config = require(ReplicatedStorage.Shared.Config)
local Map = require(ReplicatedStorage.Shared.Map)
local Signal = require(ReplicatedStorage.Shared.Signal)

local EggService = require("./EggService")
local MonsterService = require("./MonsterService")
local RoundService = require("./RoundService")

local TICK_SECONDS = 1
-- Damage within this many seconds makes someone an attacker for group scaling.
local ATTACKER_WINDOW = 6

type CampState = {
	camp: Camps.Camp,
	members: { MonsterService.Monster },
	-- Server time it respawns, or 0 while alive.
	respawnAt: number,
	groupScale: number,
	-- Last time a hostile was near.
	lastNearAt: number,
	clearStartedAt: number?,
}

local CampService = {
	name = "CampService",
	dependencies = { "CombatService", "EggService", "MonsterService", "RoundService" },
	-- (camp index, killer combatant ID, seconds from first damage to clear)
	cleared = Signal.new() :: Signal.Signal<number, number, number>,
}

local states: { CampState } = {}
local folder: Folder

local function now(): number
	return workspace:GetServerTimeNow()
end

local function config(): Config.CampConfig
	return Config.get().camps
end

local function publish(state: CampState)
	if folder:GetAttribute(state.camp.key) ~= state.respawnAt then
		folder:SetAttribute(state.camp.key, state.respawnAt)
	end
end

local function spawnCamp(state: CampState)
	local camp = state.camp
	local tier = config().tiers[camp.tier]
	table.clear(state.members)
	state.respawnAt = 0
	state.groupScale = 1
	state.clearStartedAt = nil
	state.lastNearAt = now()
	-- MonsterService.spawned adds it (and later summons and pieces) to the members.
	local m = MonsterService.spawn(
		camp.monster,
		Vector3.new(camp.position.x, 0, camp.position.z),
		nil,
		{ camp = camp.index, healthScale = tier.healthScale, damageScale = tier.damageScale }
	)
	m.row.yaw = math.random() * 2 * math.pi
	publish(state)
end

local function despawnCamp(state: CampState)
	for _, m in state.members do
		if m.row.alive then
			MonsterService.remove(m)
		end
	end
	table.clear(state.members)
end

local function living(state: CampState): { MonsterService.Monster }
	local list: { MonsterService.Monster } = {}
	for _, m in state.members do
		if m.row.alive then
			table.insert(list, m)
		end
	end
	return list
end

local function hostileNear(state: CampState): boolean
	local range = config().leashRange + 10
	local p = state.camp.position
	local found = false
	CombatService.hostilesNear(nil, p.x, p.z, range, function(entry)
		-- Only players and bots count (not other monsters or minions passing by).
		if entry.kind ~= "minion" and entry.scoresKill ~= false then
			found = true
		end
	end)
	return found
end

local function tickCamp(state: CampState, t: number)
	if state.respawnAt > 0 then
		if t >= state.respawnAt then
			spawnCamp(state)
		end
		return
	end
	local members = living(state)
	if hostileNear(state) then
		state.lastNearAt = t
	end
	local damaged = false
	local attackers: { [number]: boolean } = {}
	local count = 0
	for _, m in members do
		local c = m.row.entry.combatant
		if c.health < c.maxHealth then
			damaged = true
		end
		for id, at in c.contributors do
			if t - at <= ATTACKER_WINDOW and not attackers[id] then
				attackers[id] = true
				count += 1
			end
		end
	end
	if damaged and state.clearStartedAt == nil then
		state.clearStartedAt = t
	end
	-- Reset when everyone has left.
	if damaged and t - state.lastNearAt >= config().resetSeconds then
		despawnCamp(state)
		spawnCamp(state)
		return
	end
	-- Group scaling: grow with more attackers, never shrink mid-fight.
	local scale = Camps.groupScale(count, config())
	if scale > state.groupScale + 1e-6 then
		local ratio = scale / state.groupScale
		state.groupScale = scale
		for _, m in members do
			local c = m.row.entry.combatant
			c.maxHealth = math.floor(c.maxHealth * ratio + 0.5)
			c.health = math.min(c.maxHealth, c.health * ratio)
		end
	end
end

local function onDied(m: MonsterService.Monster, killerId: number)
	local index = m.camp
	local state = if index then states[index] else nil
	if state == nil or state.respawnAt > 0 then
		return
	end
	if #living(state) > 0 then
		return
	end
	-- Cleared.
	local camp = state.camp
	local tier = config().tiers[camp.tier]
	local seconds = if state.clearStartedAt then now() - (state.clearStartedAt :: number) else 0
	state.respawnAt = now() + tier.respawnSeconds
	table.clear(state.members)
	publish(state)
	local def = Config.get().monsters[camp.monster]
	if def and def.egg then
		EggService.drop(def.egg, tier.rarity, Vector3.new(camp.position.x, 0, camp.position.z))
	end
	CampService.cleared:fire(camp.index, killerId, seconds)
end

-- Respawns every camp fresh (round reset, dev).
function CampService.resetAll()
	for _, state in states do
		despawnCamp(state)
		spawnCamp(state)
	end
end

-- Dev: a camp's state for reports.
function CampService.describe(index: number): string?
	local state = states[index]
	if state == nil then
		return nil
	end
	local camp = state.camp
	local parts = {}
	for _, m in living(state) do
		local c = m.row.entry.combatant
		table.insert(parts, `{m.id} {math.floor(c.health)}/{c.maxHealth}`)
	end
	local status = if state.respawnAt > 0
		then `respawns in {math.ceil(state.respawnAt - now())} s`
		else table.concat(parts, ", ")
	return `C{camp.index} tier {camp.tier} {camp.monster} at ({math.floor(camp.position.x)}, {math.floor(
		camp.position.z
	)}): {status}`
end

function CampService.count(): number
	return #states
end

function CampService.tier(index: number): number
	local state = states[index]
	return if state then state.camp.tier else 1
end

function CampService.position(index: number): Vector3?
	local state = states[index]
	return if state then Vector3.new(state.camp.position.x, 0, state.camp.position.z) else nil
end

function CampService.init(_self: typeof(CampService))
	local f = Instance.new("Folder")
	f.Name = "Camps"
	f.Parent = ReplicatedStorage
	folder = f
	for _, camp in Camps.list(Map.get(), config()) do
		states[camp.index] = {
			camp = camp,
			members = {},
			respawnAt = 0,
			groupScale = 1,
			lastNearAt = 0,
			clearStartedAt = nil,
		}
	end
	MonsterService.spawned:connect(function(m: MonsterService.Monster)
		local index = m.camp
		local state = if index then states[index] else nil
		if state then
			table.insert(state.members, m)
		end
	end)
	MonsterService.died:connect(onDied)
	RoundService.roundReset:connect(function()
		CampService.resetAll()
	end)
end

function CampService.start(_self: typeof(CampService))
	for _, state in states do
		spawnCamp(state)
	end
	while true do
		task.wait(TICK_SECONDS)
		local t = now()
		for _, state in states do
			tickCamp(state, t)
		end
	end
end

return CampService
