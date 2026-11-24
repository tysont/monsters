--!strict
-- Per-player stats for the current round (kills, deaths, assists, damage, structure damage,
-- minion credit, structures destroyed). When a round ends every player gets a RoundSummary with
-- the result and their own numbers; stats reset with the round.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)

local CombatService = require("./CombatService")
local MonsterService = require("./MonsterService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

export type PlayerStats = {
	kills: number,
	deaths: number,
	assists: number,
	damage: number,
	structureDamage: number,
	minions: number,
	structuresDestroyed: number,
}

local RoundStatsService = {
	name = "RoundStatsService",
	dependencies = { "CombatService", "MonsterService", "RoundService", "TeamService" },
}

local stats: { [number]: PlayerStats } = {}
local teamStructures = { 0, 0 }

local function statsOf(userId: number): PlayerStats
	local s = stats[userId]
	if s == nil then
		s = {
			kills = 0,
			deaths = 0,
			assists = 0,
			damage = 0,
			structureDamage = 0,
			minions = 0,
			structuresDestroyed = 0,
		}
		stats[userId] = s
	end
	return s
end

-- Score for the MVP pick.
local function score(s: PlayerStats): number
	return s.kills * 3 + s.assists + s.structuresDestroyed * 5 + s.structureDamage / 200 + s.minions * 0.2
end

function RoundStatsService.stats(player: Player): PlayerStats
	return statsOf(player.UserId)
end

local function sendSummaries(state: Round.State)
	local duration = if state.activeSince then state.phaseStartedAt - (state.activeSince :: number) else 0
	local teamKills = { 0, 0 }
	for team = 1, 2 do
		local kills = TeamService.teamInstance(team):GetAttribute("Kills")
		teamKills[team] = if type(kills) == "number" then kills else 0
	end
	local mvp, best = "", 0
	for _, player in Players:GetPlayers() do
		local s = score(statsOf(player.UserId))
		if s > best then
			mvp, best = player.DisplayName, s
		end
	end
	for _, player in Players:GetPlayers() do
		local s = statsOf(player.UserId)
		Net.fireClient(Remotes.RoundSummary, player, {
			round = state.round,
			winner = state.winner or 0,
			duration = duration,
			myTeam = TeamService.teamOf(player) or 0,
			kills = s.kills,
			deaths = s.deaths,
			assists = s.assists,
			damage = math.floor(s.damage + 0.5),
			structureDamage = math.floor(s.structureDamage + 0.5),
			minions = s.minions,
			structuresDestroyed = s.structuresDestroyed,
			teamKills = teamKills,
			teamStructures = table.clone(teamStructures),
			mvp = mvp,
		})
	end
end

function RoundStatsService.init(_self: typeof(RoundStatsService))
	CombatService.damaged:connect(function(targetId: number, sourceId: number, amount: number)
		if sourceId <= 0 then
			return
		end
		local s = statsOf(sourceId)
		s.damage += amount
		local target = CombatService.entry(targetId)
		local monster = if targetId < 0 then MonsterService.monster(-targetId) else nil
		if target and monster and monster.structure then
			s.structureDamage += amount
		end
	end)
	CombatService.killed:connect(
		function(victimId: number, killerId: number, assists: { number }, victim: CombatService.Entry)
			if victimId > 0 then
				statsOf(victimId).deaths += 1
			end
			if victim.scoresKill == false or victim.kind == "minion" then
				return
			end
			if killerId > 0 then
				statsOf(killerId).kills += 1
			end
			for _, id in assists do
				if id > 0 then
					statsOf(id).assists += 1
				end
			end
		end
	)
	CombatService.credited:connect(function(player: Player, kind: string)
		if kind == "minion" then
			statsOf(player.UserId).minions += 1
		end
	end)
	MonsterService.structureDestroyed:connect(function(structure, killerId: number, assists: { number })
		teamStructures[3 - structure.team] += 1
		for _, id in { killerId, table.unpack(assists) } do
			if id > 0 then
				statsOf(id).structuresDestroyed += 1
			end
		end
	end)
	RoundService.phaseChanged:connect(function(state: Round.State)
		if state.phase == "Ending" then
			sendSummaries(state)
		end
	end)
	RoundService.roundReset:connect(function()
		table.clear(stats)
		teamStructures[1], teamStructures[2] = 0, 0
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		stats[player.UserId] = nil
	end)
end

return RoundStatsService
