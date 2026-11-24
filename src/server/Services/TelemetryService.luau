--!strict
-- Telemetry (Phase 11, Appendix B; rules in Shared.Telemetry).
--
--   Every event goes into the current round's log. Player events also go to Roblox analytics
--   (AnalyticsService:LogCustomEvent; nothing is recorded from Studio). When a round ends its log
--   becomes one round record, saved to the custom sink: a DataStore (`<prefix>telemetry_v1`,
--   key "rounds") holding the last rounds, one write per round. `dashboard()` turns the stored
--   records into the balance dashboard.
--   Lane control (from the minion fronts) and team sizes are sampled every few seconds; server
--   frame time every half minute.
--
-- Telemetry costs nothing per frame: it only reacts to signals and samples on slow timers.

local AnalyticsService = game:GetService("AnalyticsService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Round = require(ReplicatedStorage.Shared.Round)
local Telemetry = require(ReplicatedStorage.Shared.Telemetry)

local BalanceService = require("./BalanceService")
local CampService = require("./CampService")
local CombatService = require("./CombatService")
local EggService = require("./EggService")
local JungleBossService = require("./JungleBossService")
local MinionService = require("./MinionService")
local MonsterService = require("./MonsterService")
local ProgressionService = require("./ProgressionService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

local CONTROL_SECONDS = 10
local PERF_SECONDS = 30
local KEEP_ROUNDS = 200
local STORE_NAME = "telemetry_v1"
local STORE_KEY = "rounds"

local TelemetryService = {
	name = "TelemetryService",
	dependencies = {
		"BalanceService",
		"CampService",
		"CombatService",
		"EggService",
		"JungleBossService",
		"MinionService",
		"MonsterService",
		"ProgressionService",
		"RoundService",
		"TeamService",
	},
}

local log = Telemetry.newRound(0)
-- Records from this server (also the fallback when the DataStore is unavailable).
local records: { Telemetry.RoundRecord } = {}
local sessionStart: { [Player]: number } = {}
local frameTotal, frameCount = 0, 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function store(): DataStore?
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(Config.get().data.storePrefix .. STORE_NAME)
	end)
	return if ok then ds else nil
end

local function classOf(player: Player?): string
	local c = player and player:GetAttribute("ActiveClass")
	return if type(c) == "string" then c else "none"
end

local function levelOf(player: Player?): number
	local l = player and player:GetAttribute("ClassLevel")
	return if type(l) == "number" then l else 1
end

-- Logs an event (and sends player events to Roblox analytics).
function TelemetryService.log(name: string, fields: Telemetry.Fields, player: Player?)
	if not Telemetry.known(name) then
		warn(`[Telemetry] unknown event {name}`)
		return
	end
	local event: Telemetry.Event = { name = name, at = RoundService.activeSeconds(), fields = fields }
	Telemetry.record(log, event)
	if player and player.Parent then
		local eventName, value, custom = Telemetry.analytics(event)
		if eventName then
			local keys = Enum.AnalyticsCustomFieldKeys
			local map: { [string]: string } = {}
			local names = { keys.CustomField01.Name, keys.CustomField02.Name, keys.CustomField03.Name }
			local values: { string } = custom or {}
			for i, v in values do
				map[names[i]] = v
			end
			pcall(function()
				AnalyticsService:LogCustomEvent(player, eventName, value or 1, map)
			end)
		end
	end
end

-- Round records -------------------------------------------------------------------------------

local function save(record: Telemetry.RoundRecord)
	table.insert(records, record)
	while #records > KEEP_ROUNDS do
		table.remove(records, 1)
	end
	local ds = store()
	if ds == nil then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			(ds :: DataStore):UpdateAsync(STORE_KEY, function(old: any)
				local list = if type(old) == "table" then old else {}
				table.insert(list, record)
				while #list > KEEP_ROUNDS do
					table.remove(list, 1)
				end
				return list
			end)
		end)
		if not ok then
			warn(`[Telemetry] could not save the round record: {err}`)
		end
	end)
end

local function endRound(state: Round.State)
	local activeSince = state.activeSince
	local minutes = if activeSince then (state.phaseStartedAt - activeSince) / 60 else 0
	local classes: { { class: string, won: boolean } } = {}
	for _, player in Players:GetPlayers() do
		local team = TeamService.teamOf(player)
		if team then
			table.insert(classes, { class = classOf(player), won = team == state.winner })
		end
	end
	TelemetryService.log("round_end", {
		round = state.round,
		minutes = minutes,
		winner = state.winner or 0,
	})
	save(Telemetry.summarise(log, minutes, state.winner or 0, classes))
end

-- Stored records (all servers), falling back to this server's.
function TelemetryService.records(): { Telemetry.RoundRecord }
	local ds = store()
	if ds then
		local ok, list = pcall(function()
			return (ds :: DataStore):GetAsync(STORE_KEY)
		end)
		if ok and type(list) == "table" then
			return list :: any
		end
	end
	return records
end

function TelemetryService.dashboard(): { string }
	return Telemetry.format(Telemetry.dashboard(TelemetryService.records()))
end

-- The current round's log (dev).
function TelemetryService.current(): Telemetry.RoundLog
	return log
end

-- Sampling ------------------------------------------------------------------------------------

local function sampleControl()
	if RoundService.state().phase ~= "Active" then
		return
	end
	local fronts: { [string]: { number } } = {}
	for _, info in MinionService.waveInfo() do
		local f = fronts[info.lane] or { 0, 0 }
		f[info.team] = info.front
		fronts[info.lane] = f
	end
	for lane, f in fronts do
		Telemetry.sampleControl(log, lane, Telemetry.laneControl(f[1], f[2]))
	end
	table.insert(log.sizes, TeamService.balance().counts)
end

local function samplePerformance()
	if frameCount == 0 then
		return
	end
	local frameMs = frameTotal / frameCount * 1000
	frameTotal, frameCount = 0, 0
	if RoundService.state().phase == "Active" then
		table.insert(log.frameMs, frameMs)
	end
	TelemetryService.log("performance_sample", {
		frameMs = math.floor(frameMs * 100) / 100,
		players = #Players:GetPlayers(),
		minions = MinionService.count(),
	})
end

-- Wiring --------------------------------------------------------------------------------------

function TelemetryService.init(_self: typeof(TelemetryService))
	RoundService.phaseChanged:connect(function(state: Round.State)
		if state.phase == "Active" then
			log = Telemetry.newRound(state.round)
			local counts = TeamService.balance().counts
			TelemetryService.log("round_start", { round = state.round, team1 = counts[1], team2 = counts[2] })
		elseif state.phase == "Ending" then
			endRound(state)
		end
	end)
	MonsterService.structureDestroyed:connect(function(structure, killerId: number)
		local killer = CombatService.entry(killerId)
		TelemetryService.log("guardian_killed", {
			kind = structure.kind,
			lane = structure.lane or "base",
			team = structure.team,
			byTeam = if killer and killer.combatant.team then killer.combatant.team else 3 - structure.team,
			minute = RoundService.activeSeconds() / 60,
		})
	end)
	MonsterService.phased:connect(function(m: MonsterService.Monster, phase: number)
		local s = m.structure
		if s and s.kind == "titan" then
			TelemetryService.log(
				"titan_phase",
				{ team = s.team, phase = phase, minute = RoundService.activeSeconds() / 60 }
			)
		end
	end)
	Players.PlayerAdded:Connect(function(player: Player)
		sessionStart[player] = now()
		task.delay(5, function()
			if player.Parent then
				TelemetryService.log("player_join", {
					team = TeamService.teamOf(player) or 0,
					class = classOf(player),
					level = levelOf(player),
					roundMinute = RoundService.activeSeconds() / 60,
				}, player)
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local counts = TeamService.balance().counts
		TelemetryService.log("player_leave", {
			team = TeamService.teamOf(player) or 0,
			class = classOf(player),
			roundMinute = math.floor(RoundService.activeSeconds() / 60),
			sessionMinutes = math.floor((now() - (sessionStart[player] or now())) / 60),
			team1 = counts[1],
			team2 = counts[2],
		}, player)
		sessionStart[player] = nil
	end)
	CombatService.killed:connect(function(_victimId: number, killerId: number, assists: { number }, victim)
		if victim.kind ~= "player" then
			return
		end
		local killer = CombatService.entry(killerId)
		local killerPlayer = if killerId > 0 then Players:GetPlayerByUserId(killerId) else nil
		local victimPlayer = victim.player
		TelemetryService.log("player_kill", {
			killerClass = if killerPlayer then classOf(killerPlayer) else "monster",
			victimClass = classOf(victimPlayer),
			killerLevel = levelOf(killerPlayer),
			victimLevel = levelOf(victimPlayer),
			powerGap = if killer then math.floor((victim.power - killer.power) * 100) / 100 else 0,
			assists = #assists,
			bounty = if victimPlayer and victimPlayer:GetAttribute("Bounty") then "yes" else "no",
		}, killerPlayer)
	end)
	CampService.cleared:connect(function(index: number, killerId: number, seconds: number)
		local p = CampService.position(index)
		local group = 0
		if p then
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and (root.Position - p).Magnitude <= 60 then
					group += 1
				end
			end
		end
		local killer = if killerId > 0 then Players:GetPlayerByUserId(killerId) else nil
		TelemetryService.log("camp_cleared", {
			monster = CampService.monsterOf(index) or "unknown",
			groupSize = group,
			tier = CampService.tier(index),
			seconds = math.floor(seconds * 10) / 10,
		}, killer)
	end)
	local function eggEvent(action: string)
		return function(player: Player, egg)
			TelemetryService.log("egg_event", { action = action, kind = egg.kind, rarity = egg.rarity }, player)
		end
	end
	EggService.pickedUp:connect(eggEvent("picked up"))
	EggService.deposited:connect(eggEvent("deposited"))
	EggService.raided:connect(eggEvent("stolen"))
	EggService.hatched:connect(function(egg, choice: string)
		TelemetryService.log(
			"egg_event",
			{ action = `hatched: {choice}`, kind = egg.kind, rarity = egg.rarity },
			egg.owner
		)
	end)
	ProgressionService.leveledUp:connect(function(player: Player, level: number)
		TelemetryService.log("level_up", { class = classOf(player), level = level }, player)
	end)
	ProgressionService.petChanged:connect(function(player: Player)
		local power = player:GetAttribute("Power")
		TelemetryService.log(
			"pet_progress",
			{ kind = "active", xp = if type(power) == "number" then power else 1 },
			player
		)
	end)
	JungleBossService.killed:connect(function(team: number?)
		TelemetryService.log("boss_killed", { team = team or 0, minute = RoundService.activeSeconds() / 60 })
	end)
	BalanceService.bountyClaimed:connect(function(killerId: number, _victimId: number, amount: number)
		local killer = Players:GetPlayerByUserId(killerId)
		TelemetryService.log("bounty_claimed", { killerClass = classOf(killer), amount = amount }, killer)
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		frameTotal += dt
		frameCount += 1
	end)
end

function TelemetryService.start(_self: typeof(TelemetryService))
	local sinceControl, sincePerf = 0, 0
	while true do
		task.wait(1)
		sinceControl += 1
		sincePerf += 1
		if sinceControl >= CONTROL_SECONDS then
			sinceControl = 0
			sampleControl()
		end
		if sincePerf >= PERF_SECONDS then
			sincePerf = 0
			samplePerformance()
		end
	end
end

return TelemetryService
