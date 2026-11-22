--!strict
-- Graceful shutdown when a server closes (for example when an update is published).
--
--   Public server closing: tell everyone (the `ShuttingDown` attribute on ReplicatedStorage),
--   then teleport them together into a fresh reserved server.
--   That reserved server: tell everyone, wait a moment, then teleport them back to a public
--   server, which runs the new version.
--
-- Teleports do not work in Studio; there only the message is shown (try /shutdowntest).
-- Phase 14 extends this into the full soft-shutdown and migration flow.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local NOTICE_SECONDS = 3
local RETURN_DELAY_SECONDS = 5
-- BindToClose allows about 30 seconds in total.
local CLOSE_WAIT_SECONDS = 25

local ShutdownService = {
	name = "ShutdownService",
}

local function isSoftShutdownServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

-- Shows the shutdown message to every client.
function ShutdownService.notify(message: string)
	ReplicatedStorage:SetAttribute("ShuttingDown", message)
end

local function teleport(players: { Player }, options: TeleportOptions?)
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, players, options)
	end)
	if not ok then
		warn(`[Shutdown] teleport failed: {err}`)
	end
end

local function onClose()
	if RunService:IsStudio() or isSoftShutdownServer() then
		return
	end
	local players = Players:GetPlayers()
	if #players == 0 then
		return
	end
	ShutdownService.notify("This server is updating. Moving you to a new server...")
	task.wait(NOTICE_SECONDS)

	local options = Instance.new("TeleportOptions")
	options.ReservedServerId = HttpService:GenerateGUID(false)
	options:SetTeleportData({ softShutdown = true })
	teleport(Players:GetPlayers(), options)

	local deadline = os.clock() + CLOSE_WAIT_SECONDS
	while #Players:GetPlayers() > 0 and os.clock() < deadline do
		task.wait(1)
	end
end

function ShutdownService.init(_self: typeof(ShutdownService))
	game:BindToClose(onClose)

	if isSoftShutdownServer() then
		ShutdownService.notify("Server updated. Taking you back in...")
		Players.PlayerAdded:Connect(function(player: Player)
			task.wait(RETURN_DELAY_SECONDS)
			if player.Parent ~= nil then
				teleport({ player }, nil)
			end
		end)
	end
end

return ShutdownService
