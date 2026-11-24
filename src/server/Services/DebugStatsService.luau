--!strict
-- Samples server performance and sends it to players allowed to see the debug overlay who
-- currently have it expanded.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Config = require(ReplicatedStorage.Shared.Config)
local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local MinionService = require("./MinionService")
local NpcService = require("./NpcService")

local DebugStatsService = {
	name = "DebugStatsService",
	dependencies = { "NpcService", "MinionService" },
}

local viewers: { [Player]: true } = {}

-- Frame interval samples since the last broadcast.
local frameCount = 0
local frameTotal = 0
local frameMax = 0

local function round(n: number, places: number): number
	local scale = 10 ^ places
	return math.floor(n * scale + 0.5) / scale
end

local function broadcast()
	local recipients: { Player } = {}
	for player in viewers do
		table.insert(recipients, player)
	end
	local count = frameCount
	local total = frameTotal
	local max = frameMax
	frameCount, frameTotal, frameMax = 0, 0, 0
	if #recipients == 0 or count == 0 then
		return
	end

	local stats: Remotes.ServerStats = {
		frameMs = round(total / count * 1000, 2),
		frameMaxMs = round(max * 1000, 2),
		heartbeatMs = round(Stats.HeartbeatTimeMs, 2),
		sendKBps = round(Stats.DataSendKbps, 1),
		receiveKBps = round(Stats.DataReceiveKbps, 1),
		memoryMb = round(Stats:GetTotalMemoryUsageMb(), 0),
		instances = Stats.InstanceCount,
		players = #Players:GetPlayers(),
		simMs = round((NpcService.averageCost + MinionService.tickCost + MinionService.snapshotCost) * 1000, 3),
	}
	Net.fireClients(Remotes.DebugServerStats, recipients, stats)
end

function DebugStatsService.init(_self: typeof(DebugStatsService))
	if not Config.get().debug.overlayEnabled then
		return
	end

	Net.onServerEvent(Remotes.DebugOverlayExpanded, function(player: Player, expanded: boolean)
		if expanded and DebugAccess.canView(player) then
			viewers[player] = true
		else
			viewers[player] = nil
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		viewers[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		frameCount += 1
		frameTotal += dt
		if dt > frameMax then
			frameMax = dt
		end
	end)
end

function DebugStatsService.start(_self: typeof(DebugStatsService))
	if not Config.get().debug.overlayEnabled then
		return
	end
	local interval = Config.get().debug.statsInterval
	while true do
		task.wait(interval)
		broadcast()
	end
end

return DebugStatsService
