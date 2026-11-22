--!strict
-- Client entry point. Runs once per player when they join.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Greeting = require(ReplicatedStorage.Shared.Greeting)

local player = Players.LocalPlayer
print(`[Monsters] client: {Greeting.forPlayer(player.Name)}`)
