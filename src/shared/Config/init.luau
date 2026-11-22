--!strict
-- All tunable numbers live here. Every system reads from `Config.get()` so values can later be
-- overridden at runtime by live config (Phase 14) without touching the systems themselves.
--
-- `Config.resolve(environment)` is pure (no engine access) so it can be unit tested under Lune.

local Environment = require("@self/Environment")

export type Environment = Environment.Environment

export type RateLimit = {
	-- Tokens added per second.
	rate: number,
	-- Maximum tokens held, i.e. how many calls can arrive in one burst.
	burst: number,
}

export type Config = {
	environment: Environment,
	debug: {
		-- Whether the debug overlay exists at all for players allowed to see it.
		overlayEnabled: boolean,
		-- Whether the overlay starts expanded (it can always be toggled with F2 or a tap).
		overlayExpandedByDefault: boolean,
		-- User IDs allowed to see the overlay outside Studio. The experience owner is always allowed.
		overlayUserIds: { number },
		-- Seconds between server stat broadcasts to allowed players.
		statsInterval: number,
	},
	net: {
		-- Applied to every client-to-server remote that does not set its own limit.
		defaultRateLimit: RateLimit,
		-- Print a warning when a client sends a payload that fails validation or exceeds its rate limit.
		logViolations: boolean,
		-- Validate server-to-client payloads on the client too (catches server bugs; costs CPU).
		validateServerPayloads: boolean,
	},
}

local function base(environment: Environment): Config
	return {
		environment = environment,
		debug = {
			overlayEnabled = true,
			overlayExpandedByDefault = true,
			overlayUserIds = {},
			statsInterval = 1,
		},
		net = {
			defaultRateLimit = { rate = 10, burst = 20 },
			logViolations = true,
			validateServerPayloads = true,
		},
	}
end

-- Per-environment adjustments applied on top of `base`.
local overrides: { [Environment]: (config: Config) -> () } = {
	dev = function(_config: Config) end,
	test = function(config: Config)
		config.net.logViolations = false
	end,
	production = function(config: Config)
		config.debug.overlayExpandedByDefault = false
		config.net.validateServerPayloads = false
	end,
}

local function deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			deepFreeze(child)
		end
		table.freeze(value)
	end
	return value
end

local Config = {}

-- Builds the frozen config for an environment.
function Config.resolve(environment: Environment): Config
	local config = base(environment)
	overrides[environment](config)
	return deepFreeze(config)
end

local current: Config? = nil

-- The config for the environment this code is running in. Resolved once, then cached.
function Config.get(): Config
	if current == nil then
		current = Config.resolve(Environment.detect())
	end
	return current :: Config
end

return Config
