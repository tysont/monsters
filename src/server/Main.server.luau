--!strict
-- Server entry point. Runs once when the server starts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Greeting = require(ReplicatedStorage.Shared.Greeting)

print("[Monsters] server started")

Players.PlayerAdded:Connect(function(player: Player)
	print(`[Monsters] {Greeting.forPlayer(player.Name)}`)
end)
