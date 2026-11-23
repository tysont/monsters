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
--   /pack [n]          spawn a pack of weak enemies in the gym (default 5)
--   /botfight [n]      spawn n bots per team fighting in the gym (default 5)
--   /clearnpcs         remove every NPC
--   /heal              restore your health
-- The ` tuning panel sends DevSetTuning / DevResetTuning.
--   /devhelp           list these commands

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local GymService = require("./GymService")
local NpcService = require("./NpcService")
local RoundService = require("./RoundService")
local ShutdownService = require("./ShutdownService")
local TeamService = require("./TeamService")

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
			NpcService.spawn("slammer", GymService.point(30, -30), nil)
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
end

return DevService
