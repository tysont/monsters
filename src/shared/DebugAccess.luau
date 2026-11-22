--!strict
-- Who may see developer tools such as the debug overlay. Used by both server and client.

local Config = require("./Config")

local DebugAccess = {}

-- Pure rule, unit tested: allowed in dev and test; elsewhere only the owner and listed users.
function DebugAccess.isAllowed(config: Config.Config, userId: number, ownerUserId: number?): boolean
	if not config.debug.overlayEnabled then
		return false
	end
	if config.environment ~= "production" then
		return true
	end
	if ownerUserId ~= nil and userId == ownerUserId then
		return true
	end
	return table.find(config.debug.overlayUserIds, userId) ~= nil
end

-- The user ID of the experience owner, or nil when a group owns it (list staff in
-- Config.debug.overlayUserIds until group ranks are supported in Phase 14).
local function ownerUserId(): number?
	if game.CreatorType == Enum.CreatorType.User then
		return game.CreatorId
	end
	return nil
end

function DebugAccess.canView(player: Player): boolean
	return DebugAccess.isAllowed(Config.get(), player.UserId, ownerUserId())
end

return DebugAccess
