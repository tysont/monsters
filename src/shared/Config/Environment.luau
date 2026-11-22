--!strict
-- Works out which environment the game is running in.
--
-- - Set the `Environment` attribute on the DataModel (`game`) to force one, e.g. "production"
--   in Studio to check production behaviour.
-- - Otherwise Studio is "dev" and live servers are "production".
-- - "test" is used by the unit test runner, which calls `Config.resolve("test")` directly.

export type Environment = "dev" | "test" | "production"

local Environment = {}

function Environment.parse(value: unknown): Environment?
	-- Each literal is returned explicitly: comparing does not narrow `value` to the literal type.
	if value == "dev" then
		return "dev"
	elseif value == "test" then
		return "test"
	elseif value == "production" then
		return "production"
	end
	return nil
end

function Environment.detect(): Environment
	local forced = Environment.parse(game:GetAttribute("Environment"))
	if forced ~= nil then
		-- Cast: the type checker widens the refined literal union to string here.
		return forced :: Environment
	end
	if game:GetService("RunService"):IsStudio() then
		return "dev"
	end
	return "production"
end

return Environment
