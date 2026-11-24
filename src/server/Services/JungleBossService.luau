--!strict
-- The neutral jungle boss (Phase 11): a planned swing moment. During the Active round the Warden
-- appears in one of the two jungle pits between the centre walls (alternating) at a set time,
-- and again a while after it dies. The team that lands the killing blow gets stronger minion
-- waves for a while (MinionService.strengthOf via BalanceService) and XP for everyone of that
-- team nearby. Everyone is told when it appears and who killed it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Balance = require(ReplicatedStorage.Shared.Balance)
local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Signal = require(ReplicatedStorage.Shared.Signal)

local CombatService = require("./CombatService")
local MonsterService = require("./MonsterService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

local JungleBossService = {
	name = "JungleBossService",
	dependencies = { "CombatService", "MonsterService", "RoundService", "TeamService" },
	-- (team that killed it, or nil)
	killed = Signal.new() :: Signal.Signal<number?>,
	spawned = Signal.new() :: Signal.Signal<Vector3>,
}

local boss: MonsterService.Monster? = nil
-- Round-active seconds at which the next boss appears.
local nextAtSeconds = 0
local spot = 1
local buffUntil: { number } = { 0, 0 }

local function now(): number
	return workspace:GetServerTimeNow()
end

local function cfg(): Balance.BalanceConfig
	return Config.get().balance
end

local function announce(text: string, kind: string)
	Net.fireAllClients(Remotes.Announce, { text = text, kind = kind })
end

local function reset()
	local b = boss
	if b and b.row.alive then
		MonsterService.remove(b)
	end
	boss = nil
	nextAtSeconds = cfg().boss.firstMinutes * 60
	buffUntil[1], buffUntil[2] = 0, 0
end

-- Spawns the boss now (dev or on schedule). Returns where.
function JungleBossService.spawn(): Vector3?
	if boss and (boss :: MonsterService.Monster).row.alive then
		return nil
	end
	local positions = cfg().boss.positions
	local p = positions[(spot - 1) % #positions + 1]
	spot += 1
	local position = Vector3.new(p.x, 0, p.z)
	local m = MonsterService.spawn("warden", position, nil, {})
	boss = m
	announce(`The Warden has awoken in the {if p.z < 0 then "north" else "south"} jungle!`, "warning")
	JungleBossService.spawned:fire(position)
	return position
end

-- Wave strength multiplier from the boss buff for `team`.
function JungleBossService.waveBuff(team: number): number
	return if now() < (buffUntil[team] or 0) then 1 + cfg().boss.waveBuff else 1
end

function JungleBossService.alive(): boolean
	local b = boss
	return b ~= nil and b.row.alive
end

function JungleBossService.init(_self: typeof(JungleBossService))
	reset()
	RoundService.roundReset:connect(reset)
	MonsterService.died:connect(function(m: MonsterService.Monster, killerId: number)
		if m ~= boss then
			return
		end
		boss = nil
		local b = cfg().boss
		nextAtSeconds = RoundService.activeSeconds() + b.respawnMinutes * 60
		local killer = CombatService.entry(killerId)
		local team = killer and killer.combatant.team
		if team == nil and killerId > 0 then
			local player = game:GetService("Players"):GetPlayerByUserId(killerId)
			team = if player then TeamService.teamOf(player) else nil
		end
		if team then
			buffUntil[team] = now() + b.buffSeconds
			local name = Config.get().teams[team].name
			announce(`{name} slew the Warden! Their minions are empowered for {b.buffSeconds} s.`, "success")
		end
		JungleBossService.killed:fire(team)
	end)
end

function JungleBossService.start(_self: typeof(JungleBossService))
	while true do
		task.wait(1)
		local phase = RoundService.state().phase
		if phase == "Active" and not JungleBossService.alive() and RoundService.activeSeconds() >= nextAtSeconds then
			JungleBossService.spawn()
		end
	end
end

return JungleBossService
