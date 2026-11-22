--!strict
-- Shared module: required by both server and client.

local Greeting = {}

function Greeting.forPlayer(name: string): string
	return `Welcome to Monsters, {name}!`
end

return Greeting
