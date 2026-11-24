--!strict
-- Developer tools on the server. Every request is checked against DebugAccess.
--
-- Chat commands (type in chat; replies appear as system messages):
--   /endround [team]   end the Active round; the given team (default 1) wins
--   /switchteam        move yourself to the other team and respawn there
--   /addbot [count]    add bots (team slots that count towards balance)
--   /clearbots         remove all bots
--   /timescale [n]     divide round phase timers by n (1 to 100; 1 = normal)
--   /shutdowntest      show the shutdown message without shutting down
--   /gym  /base        go to the combat gym, or back to your base
--   /dummy  /slammer   spawn a target dummy or the slam test monster in the gym
--   /monster [id]      spawn any monster definition in the gym (no argument: list them)
--   /avoidtest id [walk|dodge|stand] [seconds] [health%]  telegraph avoidance test in the gym
--   /structures        health and gating of every guardian and Titan
--   /hitstructure key [n]   hit a structure for n damage as yourself (reports why it missed)
--   /killstructure key destroy a structure regardless of gating
--   /structurehp [x]   multiply structure health (no argument: Config) and reset them
--   /resetstructures   respawn every structure at full health
--   /siege             a stationary enemy target beside every structure (all of them fight)
--   /camps  /resetcamps   jungle camp states; respawn every camp fresh
--   /gocamp index      go to a jungle camp
--   /egg [kind] [rarity]  carry a new egg   /eggs  every egg and where it is
--   /gohatchery key    go to a hatchery (H1_top ...)   /hatchnow key  finish its incubation now
--   /unleash [n]       n unleashed monsters spread over every hatchery's lane
--   /profile  /wipeprofile  /savenow  /locktest   your profile; reset it; save now; second-server load
--   /setlevel n  /addxp n  /addpet kind [xp]  /maxprofile   progression test tools
--   /pets [n]          n pets following bots and players (load test)
--   /cleartest index [level] [timeout]  a level-N duelist bot clears a camp; reports the time
--   /class id          switch class anywhere   /statuses [range]  status effects near you
--   /classclear index [level] [classes] [timeout]  four class bots clear a camp (balance)
--   /classfight [perTeam] [level] [seconds]  mixed class bots skirmish mid lane; XP by class
--   /classbots perTeam [level] | clear  class bots fighting across the middle (load)
--   /balance  /dashboard   balance state (equalisers, escalation); telemetry dashboard
--   /boss  /idle  /roundskip minutes   spawn the jungle boss; mark yourself idle; age the round
--   /hurt amount [range]  hit the nearest hostile as yourself (dev damage)
--   /gold n            give yourself gold   /receipt id [userId]  run a dev receipt (product 1)
--   /classduel [classes] [maxClass]  three level-1 class bots against one maxed bot (balance)
--   /pack [n]          spawn a pack of weak enemies in the gym (default 5)
--   /botfight [n]      spawn n bots per team fighting in the gym (default 5)
--   /clearnpcs         remove every NPC
--   /heal              restore your health
--   /waves on|off      force minion waves regardless of round phase (on) or follow the round
--   /wave              spawn one wave on every lane now
--   /wavescale [n]     multiply wave size (load testing)
--   /waveinterval [s]  seconds between waves (no argument: back to Config)
--   /clearminions      remove every minion
--   /loadtest [bots] [scale]  Phase 5 load test: lane bots plus scaled waves
--   /lanebots team [n] spawn n lane bots for one team (one-sided pushes)
--   /perf              server performance report
-- The ` tuning panel sends DevSetTuning / DevResetTuning.
--   /devhelp           list these commands

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Config = require(ReplicatedStorage.Shared.Config)
local Status = require(ReplicatedStorage.Shared.Combat.Status)
local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Net = require(ReplicatedStorage.Shared.Net)
local Map = require(ReplicatedStorage.Shared.Map)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local GymService = require("./GymService")
local JungleBossService = require("./JungleBossService")
local AvoidTestService = require("./AvoidTestService")
local BalanceService = require("./BalanceService")
local CampService = require("./CampService")
local ClassBotService = require("./ClassBotService")
local ClassService = require("./ClassService")
local DataService = require("./DataService")
local EconomyService = require("./EconomyService")
local EggService = require("./EggService")
local MinionService = require("./MinionService")
local MonsterService = require("./MonsterService")
local NpcService = require("./NpcService")
local PetService = require("./PetService")
local ProgressionService = require("./ProgressionService")
local PurchaseService = require("./PurchaseService")
local RoundService = require("./RoundService")
local ShutdownService = require("./ShutdownService")
local TeamService = require("./TeamService")
local TelemetryService = require("./TelemetryService")

local DevService = {
	name = "DevService",
	dependencies = {
		"TeamService",
		"CharacterService",
		"RoundService",
		"ShutdownService",
		"CombatService",
		"GymService",
		"NpcService",
		"MinionService",
		"MonsterService",
		"AvoidTestService",
		"CampService",
		"DataService",
		"PetService",
		"ProgressionService",
		"EggService",
		"ClassBotService",
		"ClassService",
		"BalanceService",
		"JungleBossService",
		"TelemetryService",
		"EconomyService",
		"PurchaseService",
	},
}

type Command = {
	alias: string,
	usage: string,
	run: (player: Player, args: { string }) -> string,
}

local function reply(player: Player, message: string)
	Net.fireClient(Remotes.DevMessage, player, message)
end

local COMMANDS: { Command } = {
	{
		alias = "/endround",
		usage = "/endround [team]",
		run = function(_player: Player, args: { string }): string
			local winner = tonumber(args[1]) or 1
			if winner ~= 1 and winner ~= 2 then
				return "Team must be 1 or 2."
			end
			if RoundService.finish(winner) then
				return `Round ended; team {winner} wins.`
			end
			return `No Active round (phase is {RoundService.state().phase}).`
		end,
	},
	{
		alias = "/switchteam",
		usage = "/switchteam",
		run = function(player: Player, _args: { string }): string
			local team = TeamService.teamOf(player)
			if team == nil then
				return "You have no team yet."
			end
			local other = 3 - team
			TeamService.setTeam(TeamService.idOf(player), other)
			CharacterService.spawn(player)
			return `Moved to team {other}.`
		end,
	},
	{
		alias = "/addbot",
		usage = "/addbot [count]",
		run = function(_player: Player, args: { string }): string
			local count = math.clamp(math.floor(tonumber(args[1]) or 1), 1, 40)
			for _ = 1, count do
				TeamService.addBot()
			end
			local c = TeamService.counts()
			return `Added {count} bot(s). Teams: {c[1]} vs {c[2]}.`
		end,
	},
	{
		alias = "/clearbots",
		usage = "/clearbots",
		run = function(_player: Player, _args: { string }): string
			local removed = TeamService.clearBots()
			local c = TeamService.counts()
			return `Removed {removed} bot(s). Teams: {c[1]} vs {c[2]}.`
		end,
	},
	{
		alias = "/timescale",
		usage = "/timescale [n]",
		run = function(_player: Player, args: { string }): string
			local scale = tonumber(args[1]) or 1
			RoundService.setTimeScale(scale)
			return `Round timers divided by {math.clamp(scale, 1, 100)} from the next phase.`
		end,
	},
	{
		alias = "/shutdowntest",
		usage = "/shutdowntest",
		run = function(_player: Player, _args: { string }): string
			ShutdownService.notify("Shutdown test: this is the message players see during an update.")
			task.delay(5, function()
				ReplicatedStorage:SetAttribute("ShuttingDown", nil)
			end)
			return "Showing the shutdown message for 5 seconds."
		end,
	},
}

local function requireGym(): string?
	if not GymService.enabled() then
		return "The combat gym is disabled in this environment."
	end
	return nil
end

local GYM_COMMANDS: { Command } = {
	{
		alias = "/gym",
		usage = "/gym",
		run = function(player: Player, _args: { string }): string
			return requireGym() or (if GymService.teleport(player) then "Welcome to the gym." else "No character.")
		end,
	},
	{
		alias = "/base",
		usage = "/base",
		run = function(player: Player, _args: { string }): string
			CharacterService.spawn(player)
			return "Back at base."
		end,
	},
	{
		alias = "/dummy",
		usage = "/dummy",
		run = function(_player: Player, _args: { string }): string
			local blocked = requireGym()
			if blocked then
				return blocked
			end
			NpcService.spawn("dummy", GymService.point(0, 20), nil)
			return "Spawned a target dummy."
		end,
	},
	{
		alias = "/slammer",
		usage = "/slammer",
		run = function(_player: Player, _args: { string }): string
			local blocked = requireGym()
			if blocked then
				return blocked
			end
			MonsterService.spawn("slammer", GymService.point(30, -30), nil)
			return "Spawned the slam monster."
		end,
	},
	{
		alias = "/pack",
		usage = "/pack [n]",
		run = function(_player: Player, args: { string }): string
			local blocked = requireGym()
			if blocked then
				return blocked
			end
			local count = math.clamp(math.floor(tonumber(args[1]) or 5), 1, 30)
			for i = 1, count do
				local angle = i / count * 2 * math.pi
				NpcService.spawn("weak", GymService.point(math.cos(angle) * 12 - 40, math.sin(angle) * 12 + 30), nil)
			end
			return `Spawned {count} weak enemies.`
		end,
	},
	{
		alias = "/botfight",
		usage = "/botfight [n]",
		run = function(_player: Player, args: { string }): string
			local blocked = requireGym()
			if blocked then
				return blocked
			end
			local count = math.clamp(math.floor(tonumber(args[1]) or 5), 1, 30)
			for i = 1, count do
				local row = (i - 1) % 5
				local col = (i - 1) // 5
				NpcService.spawn("bot", GymService.point(-80 + col * 4, -60 + row * 8), 1)
				NpcService.spawn("bot", GymService.point(80 - col * 4, -60 + row * 8), 2)
			end
			return `Spawned {count} bots per team; they respawn when defeated (/clearnpcs to stop).`
		end,
	},
	{
		alias = "/clearnpcs",
		usage = "/clearnpcs",
		run = function(_player: Player, _args: { string }): string
			return `Removed {NpcService.clear()} NPC(s).`
		end,
	},
	{
		alias = "/heal",
		usage = "/heal",
		run = function(player: Player, _args: { string }): string
			local entry = CombatService.entry(player.UserId)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if entry == nil or humanoid == nil then
				return "No character."
			end
			entry.combatant.health = entry.combatant.maxHealth
			humanoid.Health = entry.combatant.health
			return "Healed."
		end,
	},
}

for _, command in GYM_COMMANDS do
	table.insert(COMMANDS, command)
end

local function waveSettings(): string
	local forced, scale, interval = MinionService.settings()
	return `waves {if forced then "forced" else "follow round"}, scale {scale}, every {interval} s, {MinionService.count()} alive`
end

local function perfReport(): string
	local players = Players:GetPlayers()
	local lines = {
		string.format(
			"minions %d, NPCs %d, combatants %d, players %d",
			MinionService.count(),
			NpcService.count(),
			(function()
				local n = 0
				for _ in CombatService.entries() do
					n += 1
				end
				return n
			end)(),
			#players
		),
		string.format(
			"per frame: minion tick %.3f ms (worst %.3f), minion snapshots %.3f ms, NPCs %.3f ms",
			MinionService.tickCost * 1000,
			MinionService.tickMax * 1000,
			MinionService.snapshotCost * 1000,
			NpcService.averageCost * 1000
		),
		(function(): string
			local awake, total = MonsterService.awakeCount()
			return string.format(
				"monsters %d (%d awake), projectiles %.3f ms",
				total,
				awake,
				MonsterService.projectileCost * 1000
			)
		end)(),
		string.format("server send %.1f KB/s total", game:GetService("Stats").DataSendKbps),
	}
	for _, player in players do
		table.insert(
			lines,
			string.format("%s: minion snapshots %.1f KB/s", player.Name, MinionService.bytesPerSecond(player) / 1024)
		)
	end
	return table.concat(lines, " | ")
end

local LOAD_COMMANDS: { Command } = {
	{
		alias = "/waves",
		usage = "/waves on|off",
		run = function(_player: Player, args: { string }): string
			MinionService.setForceWaves(args[1] ~= "off")
			return waveSettings()
		end,
	},
	{
		alias = "/wave",
		usage = "/wave",
		run = function(_player: Player, _args: { string }): string
			MinionService.spawnWave()
			return "Wave queued on every lane."
		end,
	},
	{
		alias = "/wavescale",
		usage = "/wavescale [n]",
		run = function(_player: Player, args: { string }): string
			MinionService.setScale(tonumber(args[1]) or 1)
			return waveSettings()
		end,
	},
	{
		alias = "/waveinterval",
		usage = "/waveinterval [s]",
		run = function(_player: Player, args: { string }): string
			MinionService.setInterval(tonumber(args[1]))
			return waveSettings()
		end,
	},
	{
		alias = "/clearminions",
		usage = "/clearminions",
		run = function(_player: Player, _args: { string }): string
			return `Removed {MinionService.clear()} minion(s).`
		end,
	},
	{
		alias = "/loadtest",
		usage = "/loadtest [bots] [scale]",
		run = function(_player: Player, args: { string }): string
			local bots = math.clamp(math.floor(tonumber(args[1]) or 40), 0, 80)
			local scale = tonumber(args[2]) or 4
			NpcService.clear()
			MinionService.clear()
			local lanes: { Map.LaneId } = { "top", "middle", "bottom" }
			for i = 1, bots do
				local team = (i - 1) % 2 + 1
				local lane = lanes[((i - 1) // 2) % 3 + 1]
				NpcService.spawnLaneBot(team, lane :: Map.LaneId)
			end
			MinionService.setScale(scale)
			MinionService.setInterval(12)
			MinionService.setForceWaves(true)
			return `Load test: {bots} lane bots, wave scale {scale}, waves every 12 s. Use /perf for numbers.`
		end,
	},
	{
		alias = "/lanebots",
		usage = "/lanebots team [count]",
		run = function(_player: Player, args: { string }): string
			local team = tonumber(args[1])
			if team ~= 1 and team ~= 2 then
				return "Team must be 1 or 2."
			end
			local count = math.clamp(math.floor(tonumber(args[2]) or 6), 1, 40)
			local lanes: { Map.LaneId } = { "top", "middle", "bottom" }
			for i = 1, count do
				NpcService.spawnLaneBot(team :: number, lanes[(i - 1) % 3 + 1] :: Map.LaneId)
			end
			return `Spawned {count} lane bots for team {team}.`
		end,
	},
	{
		alias = "/perf",
		usage = "/perf",
		run = function(_player: Player, _args: { string }): string
			return perfReport()
		end,
	},
}

for _, command in LOAD_COMMANDS do
	table.insert(COMMANDS, command)
end

local function structureLine(m: MonsterService.Monster): string
	local s = m.structure :: any
	local c = m.row.entry.combatant
	local status = if MonsterService.isDead(s.key) then "dead" elseif m.row.entry.gated then "locked" else "open"
	return `{s.key} {math.floor(c.health)}/{c.maxHealth} {status}`
end

local MONSTER_COMMANDS: { Command } = {
	{
		alias = "/monster",
		usage = "/monster [id]",
		run = function(_player: Player, args: { string }): string
			local ids = MonsterService.definitionIds()
			local id = args[1]
			if id == nil or not table.find(ids, id) then
				return "Monsters: " .. table.concat(ids, ", ")
			end
			local blocked = requireGym()
			if blocked then
				return blocked
			end
			MonsterService.spawn(id, GymService.point(0, -20), nil)
			return `Spawned {id} in the gym.`
		end,
	},
	{
		alias = "/avoidtest",
		usage = "/avoidtest id [walk|dodge|stand] [seconds] [health%]",
		run = function(player: Player, args: { string }): string
			local blocked = requireGym()
			if blocked then
				return blocked
			end
			local mode = args[2] or "walk"
			if mode ~= "walk" and mode ~= "dodge" and mode ~= "stand" then
				return "Mode must be walk, dodge or stand."
			end
			local seconds = math.clamp(tonumber(args[3]) or 60, 5, 600)
			local health = math.clamp((tonumber(args[4]) or 100) / 100, 0.01, 1)
			return AvoidTestService.run(args[1] or "outerGuardian", mode :: any, seconds, health, function(message)
				print(`[Dev] {message}`)
				reply(player, message)
			end)
		end,
	},
	{
		alias = "/structures",
		usage = "/structures",
		run = function(_player: Player, _args: { string }): string
			local lines = {}
			for _, m in MonsterService.structureList() do
				table.insert(lines, structureLine(m))
			end
			return table.concat(lines, " | ")
		end,
	},
	{
		alias = "/hitstructure",
		usage = "/hitstructure key [n]",
		run = function(player: Player, args: { string }): string
			local m = MonsterService.structure(args[1] or "")
			if m == nil then
				return "Unknown structure key (see /structures)."
			end
			local entry = CombatService.entry(player.UserId)
			if entry == nil then
				return "No character."
			end
			local amount = tonumber(args[2]) or 100
			local result = CombatService.applyHit(player.UserId, m.row.entry.combatant.id, amount, "dev")
			if result == nil then
				return "Not a combatant."
			end
			if not result.applied then
				return `Missed: {result.reason}. {structureLine(m)}`
			end
			return `Hit for {result.amount}. {structureLine(m)}`
		end,
	},
	{
		alias = "/killstructure",
		usage = "/killstructure key",
		run = function(player: Player, args: { string }): string
			local m = MonsterService.structure(args[1] or "")
			if m == nil then
				return "Unknown structure key (see /structures)."
			end
			local c = m.row.entry.combatant
			c.protected = false
			-- As yourself when hostile (kill credit), otherwise from no one (your own team's).
			local source = if TeamService.teamOf(player) ~= c.team then player.UserId else 0
			CombatService.applyHit(source, c.id, c.health * 10 + 1e6, "dev")
			return structureLine(m)
		end,
	},
	{
		alias = "/structurehp",
		usage = "/structurehp [x]",
		run = function(_player: Player, args: { string }): string
			MonsterService.setStructureHealthScale(tonumber(args[1]))
			MonsterService.resetStructures()
			return `Structure health x{tonumber(args[1]) or 1}; structures reset.`
		end,
	},
	{
		alias = "/siege",
		usage = "/siege",
		run = function(_player: Player, _args: { string }): string
			-- A sturdy, stationary enemy target beside every structure, so all of them wake and
			-- attack nonstop (performance gate). /clearnpcs removes them.
			local count = 0
			for _, m in MonsterService.structureList() do
				local s = m.structure :: any
				local side = if s.team == 1 then 1 else -1
				local row = NpcService.spawnCustom({
					label = "bot",
					position = Vector3.new(s.position.x + side * (m.def.radius + 10), 0, s.position.z + 4),
					team = 3 - s.team,
					maxHealth = 1e7,
					radius = 1.5,
					speed = 0,
					damage = 0,
					defence = 0,
					pushable = false,
					persistent = false,
					tick = function() end,
				})
				row.entry.scoresKill = false
				count += 1
			end
			-- And one at every jungle camp, so all 12 camps stay awake too.
			for i = 1, CampService.count() do
				local p = CampService.position(i) :: Vector3
				local row = NpcService.spawnCustom({
					label = "bot",
					position = p + Vector3.new(6, 0, 6),
					team = 1,
					maxHealth = 1e7,
					radius = 1.5,
					speed = 0,
					damage = 0,
					defence = 0,
					pushable = false,
					persistent = false,
					tick = function() end,
				})
				row.entry.scoresKill = false
				count += 1
			end
			return `Placed {count} siege targets. /clearnpcs removes them.`
		end,
	},
	{
		alias = "/camps",
		usage = "/camps",
		run = function(_player: Player, _args: { string }): string
			local lines = {}
			for i = 1, CampService.count() do
				table.insert(lines, CampService.describe(i) or "")
			end
			return table.concat(lines, " | ")
		end,
	},
	{
		alias = "/gocamp",
		usage = "/gocamp index",
		run = function(player: Player, args: { string }): string
			local p = CampService.position(tonumber(args[1]) or 1)
			local character = player.Character
			if p == nil or character == nil then
				return "No such camp, or no character."
			end
			character:PivotTo(CFrame.new(p + Vector3.new(0, 4, 30)))
			return CampService.describe(tonumber(args[1]) or 1) or ""
		end,
	},
	{
		alias = "/cleartest",
		usage = "/cleartest index [level] [timeout]",
		run = function(player: Player, args: { string }): string
			local index = tonumber(args[1]) or 1
			local level = math.clamp(tonumber(args[2]) or 20, 1, 200)
			local timeout = math.clamp(tonumber(args[3]) or 120, 10, 600)
			return AvoidTestService.clearTest(index, level, timeout, function(message)
				print(`[Dev] {message}`)
				reply(player, message)
			end)
		end,
	},
	{
		alias = "/class",
		usage = "/class id",
		run = function(player: Player, args: { string }): string
			local reason = ClassService.choose(player, args[1] or "", true)
			return reason or `You are now a {args[1]}.`
		end,
	},
	{
		alias = "/statuses",
		usage = "/statuses [range]",
		run = function(player: Player, args: { string }): string
			local me = CombatService.entry(player.UserId)
			local p = me and me.position()
			if p == nil then
				return "No character."
			end
			local range = tonumber(args[1]) or 40
			local t = workspace:GetServerTimeNow()
			local lines = {}
			CombatService.allNear(p.X, p.Z, range, function(entry)
				local s = entry.combatant.statuses
				local summary = Status.summary(s, t)
				if summary ~= "" then
					local c = entry.combatant
					table.insert(
						lines,
						`{entry.kind} {c.id}: {summary} (speed x{string.format(
							"%.2f",
							Status.speedMultiplier(s, t, Config.get().classes.status)
						)}, shield {math.floor(Status.shield(s, t))}, taunter {Status.taunter(s, t) or "-"}) hp {math.floor(
							c.health
						)}/{c.maxHealth}`
					)
				end
			end)
			return if #lines > 0 then table.concat(lines, "\n") else "No status effects nearby."
		end,
	},
	{
		alias = "/classclear",
		usage = "/classclear index [level] [classes,comma,separated] [timeout]",
		run = function(player: Player, args: { string }): string
			local index = tonumber(args[1]) or 1
			local level = math.clamp(tonumber(args[2]) or 20, 1, 200)
			local classes: { string } = {}
			for id in string.gmatch(args[3] or "knight,hunter,mage,healer", "[^,]+") do
				table.insert(classes, id)
			end
			local timeout = math.clamp(tonumber(args[4]) or 180, 10, 900)
			return ClassBotService.groupClear(index, level, classes, timeout, function(message)
				print(`[Dev] {message}`)
				reply(player, message)
			end)
		end,
	},
	{
		alias = "/classfight",
		usage = "/classfight [perTeam] [level] [seconds]",
		run = function(player: Player, args: { string }): string
			local perTeam = math.clamp(math.floor(tonumber(args[1]) or 4), 1, 20)
			local level = math.clamp(tonumber(args[2]) or 20, 1, 200)
			local seconds = math.clamp(tonumber(args[3]) or 300, 10, 3600)
			return ClassBotService.skirmish(perTeam, level, seconds, function(message)
				print(`[Dev] {message}`)
				reply(player, message)
			end)
		end,
	},
	{
		alias = "/classbots",
		usage = "/classbots perTeam [level] | clear",
		run = function(_player: Player, args: { string }): string
			if args[1] == "clear" then
				return `Removed {ClassBotService.clear()} class bot(s).`
			end
			local perTeam = math.clamp(math.floor(tonumber(args[1]) or 20), 1, 40)
			return ClassBotService.load(perTeam, math.clamp(tonumber(args[2]) or 20, 1, 200))
		end,
	},
	{
		alias = "/balance",
		usage = "/balance",
		run = function(_player: Player, _args: { string }): string
			return BalanceService.describe()
		end,
	},
	{
		alias = "/dashboard",
		usage = "/dashboard",
		run = function(_player: Player, _args: { string }): string
			return table.concat(TelemetryService.dashboard(), "\n")
		end,
	},
	{
		alias = "/boss",
		usage = "/boss",
		run = function(_player: Player, _args: { string }): string
			local p = JungleBossService.spawn()
			return if p
				then `The Warden appeared at ({math.floor(p.X)}, {math.floor(p.Z)}).`
				else "The Warden is already up."
		end,
	},
	{
		alias = "/idle",
		usage = "/idle",
		run = function(player: Player, _args: { string }): string
			BalanceService.forceIdle(player)
			return "You are now idle (move to clear it)."
		end,
	},
	{
		alias = "/roundskip",
		usage = "/roundskip minutes",
		run = function(_player: Player, args: { string }): string
			local minutes = tonumber(args[1]) or 5
			if not RoundService.skip(minutes * 60) then
				return "Only during an Active round."
			end
			return `Round clock moved forward {minutes} min.\n{BalanceService.describe()}`
		end,
	},
	{
		alias = "/classduel",
		usage = "/classduel [newClasses,comma,separated] [maxClass]",
		run = function(player: Player, args: { string }): string
			local classes: { string } = {}
			for id in string.gmatch(args[1] or "knight,knight,knight", "[^,]+") do
				table.insert(classes, id)
			end
			return ClassBotService.duel(classes, args[2] or "knight", 120, function(message)
				print(`[Dev] {message}`)
				reply(player, message)
			end)
		end,
	},
	{
		alias = "/hurt",
		usage = "/hurt amount [range]",
		run = function(player: Player, args: { string }): string
			local me = CombatService.entry(player.UserId)
			if me == nil then
				return "No character."
			end
			local target = CombatService.nearestHostile(me, tonumber(args[2]) or 80)
			if target == nil then
				return "Nothing hostile nearby."
			end
			local result = CombatService.applyHit(player.UserId, target.combatant.id, tonumber(args[1]) or 100, "dev")
			local c = target.combatant
			return `Hit {c.id} for {result and result.amount or 0}: {math.floor(c.health)}/{c.maxHealth}{if result
					and result.killed
				then " (killed)"
				else ""}.`
		end,
	},
	{
		alias = "/gold",
		usage = "/gold amount",
		run = function(player: Player, args: { string }): string
			EconomyService.grant(player, tonumber(args[1]) or 1000)
			return `Gold: {player:GetAttribute("Gold")}.`
		end,
	},
	{
		alias = "/receipt",
		usage = "/receipt purchaseId [userId]",
		run = function(player: Player, args: { string }): string
			local decision = PurchaseService.process({
				PlayerId = tonumber(args[2]) or player.UserId,
				ProductId = 1,
				PurchaseId = args[1] or "dev-receipt",
			})
			return `Receipt {args[1] or "dev-receipt"}: {decision.Name}. Gold: {player:GetAttribute("Gold")}.`
		end,
	},
	{
		alias = "/egg",
		usage = "/egg [kind] [rarity]",
		run = function(player: Player, args: { string }): string
			local kind = args[1] or "shellback"
			local rarity = args[2] or "common"
			if EggService.give(player, kind, rarity) then
				return `You are carrying a {rarity} {kind} egg.`
			end
			return "Could not give an egg (no character, or already carrying one)."
		end,
	},
	{
		alias = "/eggs",
		usage = "/eggs",
		run = function(_player: Player, _args: { string }): string
			return EggService.describe()
		end,
	},
	{
		alias = "/hatchnow",
		usage = "/hatchnow key",
		run = function(_player: Player, args: { string }): string
			local n = EggService.hatchNow(args[1] or "")
			return `Hatching {n} egg(s) in {args[1] or "?"} (keys like H1_top).`
		end,
	},
	{
		alias = "/unleash",
		usage = "/unleash [n]",
		run = function(_player: Player, args: { string }): string
			local count = math.clamp(math.floor(tonumber(args[1]) or 6), 1, 60)
			local keys = { "H1_top", "H2_top", "H1_middle", "H2_middle", "H1_bottom", "H2_bottom" }
			local kinds = Config.get().camps.types
			for i = 1, count do
				local h = EggService.hatchery(keys[(i - 1) % #keys + 1])
				if h then
					MonsterService.spawn(kinds[(i - 1) % #kinds + 1], h.position, h.team, { lane = h.lane })
				end
			end
			return `Unleashed {count} monster(s) across the hatcheries.`
		end,
	},
	{
		alias = "/gohatchery",
		usage = "/gohatchery key",
		run = function(player: Player, args: { string }): string
			local h = EggService.hatchery(args[1] or "")
			local character = player.Character
			if h == nil or character == nil then
				return "No such hatchery (keys like H1_top), or no character."
			end
			character:PivotTo(CFrame.new(h.position + Vector3.new(0, 4, 10)))
			return `At {h.key}.`
		end,
	},
	{
		alias = "/profile",
		usage = "/profile",
		run = function(player: Player, _args: { string }): string
			local data = DataService.get(player)
			if data == nil then
				return "Profile not loaded."
			end
			local pets = {}
			for _, pet in data.pets do
				table.insert(
					pets,
					`{pet.id}:{pet.kind} {math.floor(pet.xp)} xp{if pet.id == data.activePet then " (active)" else ""}`
				)
			end
			local class = data.classes[data.activeClass]
			return `{data.activeClass} level {class.level} ({math.floor(class.xp)} xp), account level {player:GetAttribute(
				"AccountLevel"
			)}, power {player:GetAttribute("Power")}, pets [{table.concat(pets, ", ")}], gold {data.gold}, rounds {data.stats.rounds}, wins {data.stats.wins}{if DataService.usingMemory
				then " (in-memory store: not persisted)"
				else ""}`
		end,
	},
	{
		alias = "/wipeprofile",
		usage = "/wipeprofile",
		run = function(player: Player, _args: { string }): string
			DataService.wipe(player)
			ProgressionService.refresh(player)
			return "Profile wiped (saved at the next save)."
		end,
	},
	{
		alias = "/setlevel",
		usage = "/setlevel n",
		run = function(player: Player, args: { string }): string
			ProgressionService.setLevel(player, tonumber(args[1]) or 1)
			return `Level set to {player:GetAttribute("ClassLevel")}; power {player:GetAttribute("Power")}.`
		end,
	},
	{
		alias = "/addxp",
		usage = "/addxp n",
		run = function(player: Player, args: { string }): string
			local gained = ProgressionService.award(player, tonumber(args[1]) or 100, "dev")
			return `Gained {math.floor(gained)} XP; level {player:GetAttribute("ClassLevel")}.`
		end,
	},
	{
		alias = "/addpet",
		usage = "/addpet kind [xp]",
		run = function(player: Player, args: { string }): string
			local kind = args[1] or "shellback"
			if not ProgressionService.claim(player, kind, nil) then
				return "No free pet slot (raise your account level or replace one through a hatch)."
			end
			local data = DataService.get(player)
			local xp = tonumber(args[2])
			if data and xp then
				data.pets[#data.pets].xp = xp
				ProgressionService.refresh(player)
			end
			return `Added a {kind} pet; power {player:GetAttribute("Power")}.`
		end,
	},
	{
		alias = "/maxprofile",
		usage = "/maxprofile",
		run = function(player: Player, _args: { string }): string
			local data = DataService.get(player)
			if data == nil then
				return "Profile not loaded."
			end
			data.classes[data.activeClass] = { level = 500, xp = 0 }
			for _, pet in data.pets do
				pet.xp = 1e7
			end
			if #data.pets == 0 then
				ProgressionService.claim(player, "shellback", nil)
				data.pets[1].xp = 1e7
			end
			ProgressionService.refresh(player)
			return `Maxed: level 500, pet XP 10,000,000; power {player:GetAttribute("Power")}.`
		end,
	},
	{
		alias = "/savenow",
		usage = "/savenow",
		run = function(player: Player, _args: { string }): string
			return if DataService.save(player) then "Saved." else "Save failed (see output)."
		end,
	},
	{
		alias = "/locktest",
		usage = "/locktest",
		run = function(player: Player, _args: { string }): string
			return `Second server loading your profile: {DataService.loadAsOtherServer(player)}`
		end,
	},
	{
		alias = "/petdebug",
		usage = "/petdebug",
		run = function(player: Player, _args: { string }): string
			local m = PetService.petOf(player)
			if m == nil then
				return "No pet."
			end
			local target = if m.target ~= 0 then CombatService.entry(m.target) else nil
			local tp = target and target.position()
			local follow = m.follow
			local op = follow and follow.position()
			return string.format(
				"pet %s at (%.0f, %.0f) state %s, target %d at %s, owner at %s, awake %s",
				m.id,
				m.row.x,
				m.row.z,
				m.brain.state,
				m.target,
				if tp then string.format("(%.0f, %.0f)", tp.X, tp.Z) else "-",
				if op then string.format("(%.0f, %.0f)", op.X, op.Z) else "-",
				tostring(m.awake)
			)
		end,
	},
	{
		alias = "/pets",
		usage = "/pets [n]",
		run = function(_player: Player, args: { string }): string
			-- Load test: pets following bots (and players).
			local count = math.clamp(math.floor(tonumber(args[1]) or 40), 1, 80)
			local kinds = Config.get().camps.types
			local spawned = 0
			for _, entry in CombatService.entries() do
				if spawned >= count then
					break
				end
				if
					(entry.kind == "npc" and entry.combatant.team ~= nil and entry.scoresKill ~= false)
					or entry.kind == "player"
				then
					spawned += 1
					PetService.spawnFor(entry, entry.combatant.team, kinds[spawned % #kinds + 1], 2000)
				end
			end
			return `Spawned {spawned} pet(s) following bots and players.`
		end,
	},
	{
		alias = "/resetcamps",
		usage = "/resetcamps",
		run = function(_player: Player, _args: { string }): string
			CampService.resetAll()
			return "Camps reset."
		end,
	},
	{
		alias = "/resetstructures",
		usage = "/resetstructures",
		run = function(_player: Player, _args: { string }): string
			MonsterService.resetStructures()
			return "Structures reset."
		end,
	},
}

for _, command in MONSTER_COMMANDS do
	table.insert(COMMANDS, command)
end

local function help(): string
	local usages = {}
	for _, command in COMMANDS do
		table.insert(usages, command.usage)
	end
	return "Dev commands: " .. table.concat(usages, ", ")
end

local function register(alias: string, run: (player: Player, args: { string }) -> string)
	local command = Instance.new("TextChatCommand")
	command.Name = "Dev" .. string.sub(alias, 2)
	command.PrimaryAlias = alias
	command.Triggered:Connect(function(source: TextSource, text: string)
		local player = Players:GetPlayerByUserId(source.UserId)
		if player == nil or not DebugAccess.canView(player) then
			return
		end
		local args = string.split(text, " ")
		table.remove(args, 1)
		local ok, result = pcall(run, player, args)
		local message = if ok then result else `Command failed: {result}`
		print(`[Dev] {player.Name}: {text} -> {message}`)
		reply(player, message)
	end)
	command.Parent = TextChatService
end

function DevService.init(_self: typeof(DevService))
	Net.onServerEvent(Remotes.DevSetSpeedMultiplier, function(player: Player, multiplier: number)
		if DebugAccess.canView(player) then
			CharacterService.setSpeedMultiplier(player, multiplier)
		end
	end)

	-- Live tuning (` panel): values are clamped to their definitions and stored as attributes
	-- on ReplicatedStorage.CombatTuning, which the server and every client read.
	Net.onServerEvent(Remotes.DevSetTuning, function(player: Player, request: Remotes.TuningRequest)
		local definition = Tuning.definition(request.key)
		local folder = ReplicatedStorage:FindFirstChild(Tuning.FOLDER_NAME)
		if definition == nil or folder == nil or not DebugAccess.canView(player) then
			return
		end
		local value = Tuning.clamp(definition, request.value)
		folder:SetAttribute(definition.key, value)
		print(`[Dev] {player.Name}: tuning {definition.key} = {value}`)
	end)
	Net.onServerEvent(Remotes.DevResetTuning, function(player: Player)
		local folder = ReplicatedStorage:FindFirstChild(Tuning.FOLDER_NAME)
		if folder == nil or not DebugAccess.canView(player) then
			return
		end
		for _, definition in Tuning.definitions do
			folder:SetAttribute(definition.key, nil)
		end
		reply(player, "Tuning reset to defaults.")
	end)

	for _, command in COMMANDS do
		register(command.alias, command.run)
	end
	register("/devhelp", function(_player: Player, _args: { string }): string
		return help()
	end)
	-- The client opens the gallery (UiController listens to this command's Triggered).
	register("/gallery", function(_player: Player, _args: { string }): string
		return "Toggled the component gallery."
	end)
end

return DevService
