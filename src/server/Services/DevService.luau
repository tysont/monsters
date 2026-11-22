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
--   /devhelp           list these commands

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CharacterService = require("./CharacterService")
local RoundService = require("./RoundService")
local ShutdownService = require("./ShutdownService")
local TeamService = require("./TeamService")

local DevService = {
	name = "DevService",
	dependencies = { "TeamService", "CharacterService", "RoundService", "ShutdownService" },
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

	for _, command in COMMANDS do
		register(command.alias, command.run)
	end
	register("/devhelp", function(_player: Player, _args: { string }): string
		return help()
	end)
end

return DevService
