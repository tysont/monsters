--!strict
-- Phase 11 balance on the server (rules in Shared.Balance):
--
--   Equalisers   every few seconds, from TeamService.balance(): the weaker (or short-handed) team
--                gets stronger minion waves, shorter respawns and a little more XP.
--   Behind       the team that has lost more structures gets stronger waves (capped).
--   Escalation   waves strengthen as the round goes on; siege minions join later.
--   Comeback     the Titan defenders' faster respawn fades over the round.
--   Jungle boss  its killer's team gets stronger waves for a while (JungleBossService).
--   Team fill    ties for joiners go to the team that is behind (more structures lost).
--   Bounties     strong players and kill streaks carry a bounty (player attribute `Bounty`), paid
--                in XP to whoever defeats them.
--   Payout       end-of-round XP from contribution, result, round length and closeness, and
--                staying to the end (replaces the flat win/loss XP).
--   Idle         no movement or combat for a while: `Idle` attribute, left out of team strength;
--                removed after longer (not in Studio).
--   Leavers      when teams end up two or more apart, the next player to die on the bigger team
--                respawns on the smaller one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Balance = require(ReplicatedStorage.Shared.Balance)
local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Structures = require(ReplicatedStorage.Shared.Combat.Structures)
local Map = require(ReplicatedStorage.Shared.Map)

local AbilityService = require("./AbilityService")
local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local JungleBossService = require("./JungleBossService")
local MinionService = require("./MinionService")
local MonsterService = require("./MonsterService")
local ProgressionService = require("./ProgressionService")
local RoundService = require("./RoundService")
local RoundStatsService = require("./RoundStatsService")
local TeamService = require("./TeamService")

local REFRESH_SECONDS = 2
local IDLE_CHECK_SECONDS = 2
local MOVE_EPSILON = 1

local BalanceService = {
	name = "BalanceService",
	dependencies = {
		"AbilityService",
		"CharacterService",
		"CombatService",
		"JungleBossService",
		"MinionService",
		"MonsterService",
		"ProgressionService",
		"RoundService",
		"RoundStatsService",
		"TeamService",
	},
	-- (player, amount) after a round payout.
	paid = Signal.new() :: Signal.Signal<Player, number>,
	-- (killerId, victimId, amount) when a bounty is claimed.
	bountyClaimed = Signal.new() :: Signal.Signal<number, number, number>,
}

local equalisers: { Balance.Equaliser } = {}
local streaks: { [number]: number } = {}
local lastInputAt: { [Player]: number } = {}
local lastPosition: { [Player]: Vector3 } = {}
local joinedAt: { [Player]: number } = {}
-- When teams are uneven after someone left: the team to move a player from on their next death.
local moveFrom: number? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function cfg(): Balance.BalanceConfig
	return Config.get().balance
end

local function minutes(): number
	return RoundService.activeSeconds() / 60
end

local function announce(players: { Player }?, text: string, kind: string)
	local event = { text = text, kind = kind }
	if players then
		Net.fireClients(Remotes.Announce, players, event)
	else
		Net.fireAllClients(Remotes.Announce, event)
	end
end

-- Equalisers ----------------------------------------------------------------------------------

local function refresh()
	local balance = TeamService.balance()
	for team = 1, 2 do
		equalisers[team] = Balance.equaliser(team, balance.strength, balance.counts, cfg())
	end
end

function BalanceService.equaliser(team: number): Balance.Equaliser
	return equalisers[team] or Balance.equaliser(team, { 1, 1 }, { 0, 0 }, cfg())
end

-- Structures each team has lost this round.
local function lost(): { number }
	local destroyed = RoundStatsService.structuresDestroyed()
	-- Team 1 has lost what team 2 destroyed.
	return { destroyed[2], destroyed[1] }
end

-- Minion wave strength for a team right now: equaliser x escalation x behind bonus x jungle
-- boss buff.
function BalanceService.waveStrength(team: number): number
	local l = lost()
	return BalanceService.equaliser(team).waveStrength
		* Balance.escalation(minutes(), cfg())
		* Balance.behindBonus(l[team] - l[3 - team], cfg())
		* JungleBossService.waveBuff(team)
end

-- The team that is behind: more structures lost (nil when level).
local function behindTeam(): number?
	local destroyed = RoundStatsService.structuresDestroyed()
	-- Team 1 has lost what team 2 destroyed.
	local lost1, lost2 = destroyed[2], destroyed[1]
	if lost1 > lost2 then
		return 1
	elseif lost2 > lost1 then
		return 2
	end
	return nil
end

-- Bounties ----------------------------------------------------------------------------------

local function publishBounty(player: Player)
	local streak = streaks[player.UserId] or 0
	local entry = CombatService.entry(player.UserId)
	local power = if entry then entry.power else 1
	local bounty = Balance.bounty(power, streak, cfg())
	if player:GetAttribute("Bounty") ~= (if bounty > 0 then bounty else nil) then
		player:SetAttribute("Bounty", if bounty > 0 then bounty else nil)
	end
end

local function onKill(victimId: number, killerId: number, victim: CombatService.Entry)
	if victim.kind ~= "player" then
		return
	end
	local victimPlayer = victim.player
	local bounty = if victimPlayer then victimPlayer:GetAttribute("Bounty") else nil
	streaks[victimId] = 0
	if victimPlayer then
		publishBounty(victimPlayer)
	end
	local killer = if killerId > 0 then Players:GetPlayerByUserId(killerId) else nil
	if killer then
		streaks[killerId] = (streaks[killerId] or 0) + 1
		publishBounty(killer)
		if type(bounty) == "number" and bounty > 0 then
			ProgressionService.award(killer, bounty, "bounty")
			BalanceService.bountyClaimed:fire(killerId, victimId, bounty)
			local victimName = if victimPlayer then victimPlayer.DisplayName else "a player"
			announce(nil, `{killer.DisplayName} claimed the bounty on {victimName} (+{bounty} XP)`, "info")
		end
		local streak = streaks[killerId]
		if streak == cfg().bounty.streak then
			announce(nil, `{killer.DisplayName} is on a {streak} kill streak: bounty placed!`, "warning")
		end
	end
	-- Leaver handling: move this player to the smaller team before they respawn.
	if victimPlayer and moveFrom and TeamService.teamOf(victimPlayer) == moveFrom then
		local counts = TeamService.balance().counts
		local to = 3 - moveFrom
		if counts[moveFrom] - counts[to] >= 2 then
			TeamService.setTeam(TeamService.idOf(victimPlayer), to)
			announce({ victimPlayer }, `Teams were uneven: you will respawn on {Config.get().teams[to].name}.`, "info")
		end
		local after = TeamService.balance().counts
		if math.abs(after[1] - after[2]) < 2 then
			moveFrom = nil
		end
	end
end

-- Payout --------------------------------------------------------------------------------------

local function payout(state: Round.State)
	local activeSince = state.activeSince
	if activeSince == nil then
		return
	end
	local duration = state.phaseStartedAt - activeSince
	local teamLost = lost()
	local perTeam = #Structures.list(Map.get()) / 2
	local scored: { { player: Player, team: number, score: number } } = {}
	local total = 0
	for _, player in Players:GetPlayers() do
		local team = TeamService.teamOf(player)
		if team then
			local score = RoundStatsService.score(player)
			total += score
			table.insert(scored, { player = player, team = team, score = score })
		end
	end
	local average = if #scored > 0 then total / #scored else 0
	for _, s in scored do
		local stayed = (joinedAt[s.player] or 0) <= activeSince + duration / 2
		local amount = Balance.payout({
			won = s.team == state.winner,
			score = s.score,
			averageScore = average,
			minutes = duration / 60,
			lost = teamLost,
			structuresPerTeam = perTeam,
			stayed = stayed,
		}, cfg())
		ProgressionService.award(s.player, amount, "round")
		BalanceService.paid:fire(s.player, amount)
		announce({ s.player }, `+{amount} XP for the round`, "success")
	end
end

-- Idle ----------------------------------------------------------------------------------------

local function touch(player: Player)
	lastInputAt[player] = now()
	if player:GetAttribute("Idle") then
		player:SetAttribute("Idle", nil)
		TeamService.refresh()
	end
end

local function checkIdle()
	local t = now()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			local p = root.Position
			local last: Vector3? = lastPosition[player]
			if not last or (p - (last :: Vector3)).Magnitude > MOVE_EPSILON then
				lastPosition[player] = p
				touch(player)
			end
		else
			-- Dead or respawning time does not count as idle.
			touch(player)
		end
		local idle, remove = Balance.idle(lastInputAt[player] or t, t, cfg())
		if idle and not player:GetAttribute("Idle") then
			player:SetAttribute("Idle", true)
			TeamService.refresh()
			announce({ player }, "You are idle and no longer count towards your team.", "warning")
		end
		if remove and not RunService:IsStudio() then
			player:Kick("Removed for being idle.")
		end
	end
end

-- Dev: make a player idle now (for testing).
function BalanceService.forceIdle(player: Player)
	lastInputAt[player] = now() - cfg().idle.idleSeconds - 1
	checkIdle()
end

-- Dev: a description of the current balance state.
function BalanceService.describe(): string
	local balance = TeamService.balance()
	local lines = {
		`minute {string.format("%.1f", minutes())}: escalation x{string.format(
			"%.2f",
			Balance.escalation(minutes(), cfg())
		)}, siege {Balance.siegeCount(minutes(), cfg())}/wave, defender respawn x{string.format(
			"%.2f",
			Balance.defenderRespawnScale(minutes(), cfg())
		)}`,
		`strength {string.format("%.2f", balance.strength[1])} v {string.format("%.2f", balance.strength[2])}, counts {balance.counts[1]} v {balance.counts[2]}, behind {behindTeam() or "-"}`,
	}
	for team = 1, 2 do
		local e = BalanceService.equaliser(team)
		table.insert(
			lines,
			`team {team}: waves x{string.format("%.2f", BalanceService.waveStrength(team))} (equaliser x{string.format(
				"%.2f",
				e.waveStrength
			)}, boss x{JungleBossService.waveBuff(team)}), respawn x{string.format("%.2f", e.respawnScale)}, XP x{string.format(
				"%.2f",
				e.rewardScale
			)}`
		)
	end
	return table.concat(lines, "\n")
end

-- Wiring --------------------------------------------------------------------------------------

function BalanceService.init(_self: typeof(BalanceService))
	refresh()
	MinionService.strengthOf = BalanceService.waveStrength
	MinionService.siegeCount = function(): number
		return Balance.siegeCount(minutes(), cfg())
	end
	MonsterService.defenderRespawnScale = function(): number
		return Balance.defenderRespawnScale(minutes(), cfg())
	end
	TeamService.behindTeam = behindTeam

	-- Equaliser respawn on top of any other respawn scaling (Titan defenders).
	local baseRespawn = CharacterService.respawnScale
	CharacterService.respawnScale = function(player: Player): number
		local team = TeamService.teamOf(player)
		local scale = if team then BalanceService.equaliser(team).respawnScale else 1
		return baseRespawn(player) * scale
	end
	ProgressionService.rewardScale = function(player: Player): number
		local team = TeamService.teamOf(player)
		return if team then BalanceService.equaliser(team).rewardScale else 1
	end
	-- Idle players do not count towards team strength.
	local basePower = TeamService.powerOf
	TeamService.powerOf = function(id: string): number
		local userId = tonumber(string.match(id, "^player:(%d+)$"))
		local player = if userId then Players:GetPlayerByUserId(userId) else nil
		if player and player:GetAttribute("Idle") then
			return 0
		end
		return basePower(id)
	end

	CombatService.killed:connect(function(victimId: number, killerId: number, _assists: { number }, victim)
		onKill(victimId, killerId, victim)
	end)
	CombatService.damaged:connect(function(_targetId: number, sourceId: number)
		if sourceId > 0 then
			local player = Players:GetPlayerByUserId(sourceId)
			if player then
				touch(player)
			end
		end
	end)
	AbilityService.casted:connect(function(caster: CombatService.Entry)
		if caster.player then
			touch(caster.player)
		end
	end)
	CharacterService.characterSpawned:connect(function(player: Player)
		touch(player)
		publishBounty(player)
	end)
	JungleBossService.killed:connect(function(team: number?)
		if team then
			local boss = cfg().boss
			-- XP for the killing team near the pit it died in.
			for _, p in boss.positions do
				ProgressionService.awardNear(Vector3.new(p.x, 0, p.z), team, boss.xpRange, boss.killXp, "boss")
			end
		end
	end)
	RoundService.phaseChanged:connect(function(state: Round.State)
		if state.phase == "Ending" then
			payout(state)
		end
	end)
	RoundService.roundReset:connect(function()
		table.clear(streaks)
		moveFrom = nil
		for _, player in Players:GetPlayers() do
			joinedAt[player] = 0
			publishBounty(player)
		end
	end)
	Players.PlayerAdded:Connect(function(player: Player)
		joinedAt[player] = now()
		lastInputAt[player] = now()
	end)
	for _, player in Players:GetPlayers() do
		joinedAt[player] = now()
		lastInputAt[player] = now()
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		joinedAt[player] = nil
		lastInputAt[player] = nil
		lastPosition[player] = nil
		streaks[player.UserId] = nil
		-- After they are gone, check whether the teams are now two or more apart.
		task.defer(function()
			local counts = TeamService.balance().counts
			if math.abs(counts[1] - counts[2]) >= 2 then
				moveFrom = if counts[1] > counts[2] then 1 else 2
			end
		end)
	end)
end

function BalanceService.start(_self: typeof(BalanceService))
	local sinceIdle = 0
	while true do
		task.wait(REFRESH_SECONDS)
		refresh()
		sinceIdle += REFRESH_SECONDS
		if sinceIdle >= IDLE_CHECK_SECONDS then
			sinceIdle = 0
			checkIdle()
		end
	end
end

return BalanceService
