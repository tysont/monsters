--!strict
-- Server side of developer tools. Every request is checked against DebugAccess.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DevService = {
	name = "DevService",
}

local speedMultipliers: { [Player]: number } = {}

local function applySpeed(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = MapLayout.walkSpeed * (speedMultipliers[player] or 1)
	end
end

function DevService.init(_self: typeof(DevService))
	Net.onServerEvent(Remotes.DevSetSpeedMultiplier, function(player: Player, multiplier: number)
		if not DebugAccess.canView(player) then
			return
		end
		if multiplier == 1 then
			speedMultipliers[player] = nil
		else
			speedMultipliers[player] = multiplier
		end
		applySpeed(player)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			if speedMultipliers[player] then
				applySpeed(player)
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		speedMultipliers[player] = nil
	end)
end

return DevService
