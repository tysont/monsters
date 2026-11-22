--!strict
-- Server entry point. Creates every remote, then starts the services in `Services/`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

Net.createRemotes(Remotes :: any)
local started = Loader.runContainer(script.Parent.Services)

print(`[Monsters] server started ({Config.get().environment}, {#started} services)`)
