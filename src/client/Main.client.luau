--!strict
-- Client entry point. Starts the controllers in `Controllers/`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)

local started = Loader.runContainer(script.Parent.Controllers)

print(`[Monsters] client started ({#started} controllers)`)
