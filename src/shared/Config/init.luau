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
	-- Team 1 is the west base, team 2 the east base. Names are placeholders.
	teams: { TeamDefinition },
	teamBalance: {
		-- When teams have equal headcount, a joiner goes to the weaker team if the strength gap
		-- (sum of member power) is larger than this. 1.0 is one new player's worth of power.
		strengthTolerance: number,
	},
	round: {
		-- Countdown before a round becomes Active.
		startingSeconds: number,
		-- Input is frozen and the result is shown.
		endingSeconds: number,
		-- Teams are reshuffled and the map reset; players wait at their new base.
		intermissionSeconds: number,
	},
	respawn: RespawnConfig,
	combat: CombatConfig,
}

-- Base stats for a class at level 1 with no pet. Phase 10 adds the other classes.
export type ClassStats = {
	maxHealth: number,
	damage: number,
	-- Damage taken is multiplied by 100 / (100 + defence).
	defence: number,
}

export type EnemyConfig = {
	maxHealth: number,
	-- Collision radius used for hits and spacing.
	radius: number,
	speed: number,
	aggroRange: number,
	damage: number,
	attackRange: number,
	attackCooldown: number,
}

export type CombatConfig = {
	-- Default values for the live-tunable numbers (see Shared.Combat.Tuning for limits).
	tuning: {
		attackCooldown: number,
		attackRange: number,
		-- Total arc in degrees in front of the attacker.
		attackArc: number,
		dodgeDistance: number,
		dodgeCooldown: number,
		-- Invulnerability window after starting a dodge, in seconds.
		iframes: number,
		hitStop: number,
		knockback: number,
		-- Multiplies every gym enemy's health.
		enemyHealthScale: number,
	},
	knight: ClassStats,
	-- Most targets one melee swing can hit.
	maxTargets: number,
	-- Extra range allowed on the server for movement between client and server.
	rangeTolerance: number,
	-- Attacks and dodges may arrive this much earlier than their cooldown (network jitter).
	cooldownTolerance: number,
	-- How far back in time the server rewinds target positions for an attacker's ping.
	maxRewind: number,
	-- Monster area attacks resolve this long after impact so a dodge sent just before impact
	-- still arrives in time.
	hitResolveDelay: number,
	dodgeDuration: number,
	swingDuration: number,
	-- Damage within this many seconds earns an assist on a kill.
	assistWindow: number,
	regen: {
		-- Seconds without taking damage before out-of-combat regeneration starts.
		outOfCombatDelay: number,
		-- Fractions of max health per second.
		outOfCombatPerSecond: number,
		atBasePerSecond: number,
	},
	gym: {
		-- Whether the dev-only combat gym is built.
		enabled: boolean,
		center: { x: number, z: number },
		size: number,
	},
	enemies: {
		dummy: EnemyConfig,
		weak: EnemyConfig,
		slammer: EnemyConfig & {
			slamRadius: number,
			telegraphSeconds: number,
			recoverSeconds: number,
		},
	},
	sounds: {
		swing: string,
		hit: string,
		slam: string,
	},
}

export type RespawnConfig = {
	-- Respawn delay is base + perMinute * minutes into the round, capped at max.
	baseSeconds: number,
	perMinuteSeconds: number,
	maxSeconds: number,
	-- Spawn protection (a ForceField) after each spawn.
	protectionSeconds: number,
}

export type TeamDefinition = {
	name: string,
	-- A BrickColor name; Roblox teams are identified by BrickColor.
	brickColor: string,
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
		teams = {
			{ name = "Blue", brickColor = "Bright blue" },
			{ name = "Red", brickColor = "Bright red" },
		},
		teamBalance = {
			strengthTolerance = 0.25,
		},
		round = {
			startingSeconds = 10,
			endingSeconds = 10,
			intermissionSeconds = 15,
		},
		respawn = {
			baseSeconds = 5,
			perMinuteSeconds = 0.25,
			maxSeconds = 15,
			protectionSeconds = 3,
		},
		combat = {
			tuning = {
				attackCooldown = 0.5,
				attackRange = 7,
				attackArc = 120,
				dodgeDistance = 14,
				dodgeCooldown = 1.2,
				iframes = 0.35,
				hitStop = 0.06,
				knockback = 20,
				enemyHealthScale = 1,
			},
			knight = { maxHealth = 100, damage = 20, defence = 0 },
			maxTargets = 3,
			rangeTolerance = 2,
			cooldownTolerance = 0.05,
			maxRewind = 0.25,
			hitResolveDelay = 0.1,
			dodgeDuration = 0.2,
			swingDuration = 0.25,
			assistWindow = 10,
			regen = {
				outOfCombatDelay = 5,
				outOfCombatPerSecond = 0.02,
				atBasePerSecond = 0.1,
			},
			gym = {
				enabled = true,
				center = { x = 0, z = 900 },
				size = 220,
			},
			enemies = {
				dummy = {
					maxHealth = 1000,
					radius = 2,
					speed = 0,
					aggroRange = 0,
					damage = 0,
					attackRange = 0,
					attackCooldown = 1,
				},
				weak = {
					maxHealth = 40,
					radius = 1.5,
					speed = 11,
					aggroRange = 60,
					damage = 4,
					attackRange = 4,
					attackCooldown = 1.5,
				},
				slammer = {
					maxHealth = 400,
					radius = 4,
					speed = 6,
					aggroRange = 45,
					damage = 35,
					attackRange = 12,
					attackCooldown = 1,
					slamRadius = 14,
					telegraphSeconds = 1,
					recoverSeconds = 1.5,
				},
			},
			sounds = {
				swing = "rbxassetid://9119710806",
				hit = "rbxassetid://9117971636",
				slam = "rbxassetid://9113524242",
			},
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
		config.combat.gym.enabled = false
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
