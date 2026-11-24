--!strict
-- All tunable numbers live here. Every system reads from `Config.get()` so values can later be
-- overridden at runtime by live config (Phase 14) without touching the systems themselves.
--
-- `Config.resolve(environment)` is pure (no engine access) so it can be unit tested under Lune.

local Environment = require("@self/Environment")
local Balance = require("./Balance")
local Classes = require("./Classes")
local Monsters = require("./Monsters")

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
	minions: MinionConfig,
	-- Monster definitions by ID (guardians, Titans, gym monsters; jungle monsters from Phase 7).
	monsters: { [string]: MonsterDefinition },
	-- Class definitions by ID (Shared.Classes) and class rules.
	classDefinitions: { [string]: Classes.Class },
	classes: ClassConfig,
	camps: CampConfig,
	eggs: EggConfig,
	progression: ProgressionConfig,
	data: DataConfig,
	structures: StructureConfig,
	launchers: LauncherConfig,
	-- Phase 11 balance: equalisers, escalation, comeback help, underdog, bounties, payout,
	-- idle detection and the jungle boss (rules in Shared.Balance).
	balance: Balance.BalanceConfig,
}

-- Monster definitions live in Shared.Monsters (one file per type); these are re-exported here.
export type MonsterAttack = Monsters.Attack
export type MonsterDefinition = Monsters.Definition

export type CampTier = {
	-- Multiply the camp monster's health and damage.
	healthScale: number,
	damageScale: number,
	-- Seconds from clearing the camp until it respawns.
	respawnSeconds: number,
	-- Egg rarity dropped by this tier (Phase 8 uses it).
	rarity: string,
}

export type CampConfig = {
	-- Monster type at each jungle camp: camp k of each quadrant uses types[(k + quadrant) % #types].
	types: { string },
	-- Tiers by distance from the centre line: tier 3 (hardest) within tierEdges[2] studs of it,
	-- tier 2 within tierEdges[1], tier 1 beyond.
	tierEdges: { number },
	tiers: { CampTier },
	-- Camp monsters return home beyond this distance from the camp.
	leashRange: number,
	-- A damaged camp with no hostile within leashRange + 10 for this long resets to full.
	resetSeconds: number,
	-- Health grows by this fraction per attacker beyond the first, up to maxGroupScale.
	groupScalePerAttacker: number,
	maxGroupScale: number,
}

export type ProgressionConfig = {
	-- XP from level L to L + 1 is xpBase + xpGrowth * (L - 1) ^ xpExponent. Levels never cap.
	xpBase: number,
	xpGrowth: number,
	xpExponent: number,
	-- A class below the player's highest class level earns XP at this multiplier until it
	-- catches up.
	catchUpMultiplier: number,
	-- Account level needed for each pet slot (first slot at the start).
	petSlotLevels: { number },
	titles: { { level: number, name: string } },
	-- Pet multiplier 1 + petBonus * x / (x + petHalfXp) for pet XP x (ceiling 1 + petBonus).
	petBonus: number,
	petHalfXp: number,
	-- Pet XP from feeding a hatched egg, by rarity; matching the pet's type multiplies it.
	feedXp: { common: number, rare: number, epic: number, legendary: number },
	feedMatchBonus: number,
	-- XP awards.
	xp: {
		-- Per minion with proximity credit.
		minion: number,
		-- Per hit point of a defeated camp monster, in full to everyone who damaged it.
		monsterPerHealth: number,
		-- Per structure destroyed, to every player on the attacking team within structureRange.
		outerGuardian: number,
		innerGuardian: number,
		titan: number,
		structureRange: number,
		kill: number,
		assist: number,
		-- To everyone who damaged the camp, times its tier.
		campClear: number,
		eggDeposited: number,
		eggHatched: number,
		raid: number,
		-- To the owner of an unleashed monster, per point of damage it deals.
		unleashPerDamage: number,
		-- Per point of health healed on (or damage shielded for) another player or bot.
		healPerHealth: number,
	},
	-- Pets deal this fraction of their monster type's damage.
	petDamageScale: number,
	-- Seconds before a pet comes back after its owner respawns or switches.
	petRespawnSeconds: number,
}

export type DataConfig = {
	-- Data store names are prefixed per environment, so Studio never touches live data.
	storePrefix: string,
	storeName: string,
	autosaveSeconds: number,
	-- A lock not refreshed for this long belongs to a dead server and may be taken over.
	staleLockSeconds: number,
	-- Load attempts (with backoff) before the player is told and removed.
	loadAttempts: number,
	-- Use an in-memory store when data stores are unavailable (Studio without API access). Never
	-- in production, where a failed load must not become an empty profile.
	allowMemoryFallback: boolean,
}

export type EggConfig = {
	-- Seconds in a hatchery slot by rarity.
	incubation: { common: number, rare: number, epic: number, legendary: number },
	-- Slots per hatchery.
	slots: number,
	-- Carriers walk at this fraction of normal speed and cannot dodge.
	carrySpeedScale: number,
	-- Eggs on the ground (from a camp or a fallen carrier) disappear after this long.
	droppedSeconds: number,
	-- Seconds a raider holds the raid prompt.
	raidSeconds: number,
	-- Raiding needs the hatchery lane's outer guardian dead.
	raidRequiresOuterGuardian: boolean,
	-- The owner has this long to choose what a hatched egg becomes; then it is unleashed.
	choiceSeconds: number,
	-- Unleashed monsters' health and damage by rarity.
	rarityScale: { common: number, rare: number, epic: number, legendary: number },
	-- Slack in studs for carrier movement checks.
	moveTolerance: number,
	-- Seconds between egg interactions per player (pick up, deposit, raid).
	interactCooldown: number,
}
-- Launch pads (rules in Shared.Launchers).
export type LauncherConfig = {
	-- How far inside the base (from the lane's gate) a pad sits.
	padInset: number,
	-- Pads activate within this many studs.
	padRange: number,
	-- Landing spot: this far along the lane from the guardian, towards your base.
	landingOffset: number,
	-- Flight time = distance / flightSpeed + flightBase, clamped to [minSeconds, maxSeconds].
	flightSpeed: number,
	flightBase: number,
	minSeconds: number,
	maxSeconds: number,
	-- Arc peak above the straight line = distance * apexPerStud, clamped to [minApex, maxApex].
	apexPerStud: number,
	minApex: number,
	maxApex: number,
	-- Seconds between launches per player.
	cooldownSeconds: number,
}

-- Class rules (Phase 10). Class definitions live in Shared.Classes.
export type ClassConfig = {
	-- New profiles start as this class (the first-join picker defaults to it).
	default: string,
	-- Status effect stacking rules (Shared.Combat.Status).
	status: { maxSlow: number, stunImmunity: number, maxShieldFraction: number },
	-- Aim assist cones in degrees (total): enemies for direction aim, allies for ally aim.
	aimAssistCone: number,
	allyAssistCone: number,
	-- Casts may arrive this much earlier than their cooldown (network jitter).
	cooldownTolerance: number,
	-- Switching class is allowed within this distance of your base's class station.
	stationRange: number,
	-- How often statuses tick (heal over time, expiry, movement).
	statusTickSeconds: number,
	-- Heals and shields within this many seconds make the healer an assist on the ally's kills.
	supportWindow: number,
	-- Teamwork: a monster takes this much more damage for each distinct class beyond the first
	-- that hit it within teamworkWindow seconds (four classes: three times this).
	teamworkPerClass: number,
	teamworkWindow: number,
}

export type StructureConfig = {
	-- Multiplies every guardian and Titan's health (dev testing; 1 in play).
	healthScale: number,
	-- A guardian prefers a hostile who hurt one of its team's players nearby, for this long.
	provokeSeconds: number,
	-- Range around a guardian in which hurting its teammates provokes it.
	provokeRange: number,
	-- While the Titan has taken damage in the last alertSeconds, its team respawns faster.
	alertSeconds: number,
	defenderRespawnScale: number,
}

export type MinionKindConfig = {
	maxHealth: number,
	damage: number,
	attackRange: number,
	attackCooldown: number,
	speed: number,
	radius: number,
}

export type MinionConfig = {
	-- Seconds between waves (per lane, per team); the first wave comes firstWaveDelay seconds
	-- after the round becomes Active.
	waveInterval: number,
	firstWaveDelay: number,
	-- Wave makeup, front to back.
	composition: { { kind: string, count: number } },
	-- Seconds between minions leaving the spawn in one wave.
	spawnStagger: number,
	-- Side-to-side spread of a wave across the lane.
	formationWidth: number,
	-- Minions engage enemies within this range of themselves.
	aggroRange: number,
	-- Hostile players within this range of a dying minion get credit (XP from Phase 9, gold
	-- from Phase 12).
	creditRadius: number,
	-- Clients receive minions within this range of their character.
	interestRadius: number,
	-- Every minion in range is resent this often even if unchanged.
	keyframeSeconds: number,
	kinds: { melee: MinionKindConfig, ranged: MinionKindConfig, siege: MinionKindConfig },
}

-- Base stats for a class at level 1 with no pet (each class file in Shared.Classes has them).
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
			},
			sounds = {
				swing = "rbxassetid://9119710806",
				hit = "rbxassetid://9117971636",
				slam = "rbxassetid://9113524242",
			},
		},
		minions = {
			waveInterval = 30,
			firstWaveDelay = 5,
			composition = {
				{ kind = "melee", count = 3 },
				{ kind = "ranged", count = 3 },
			},
			spawnStagger = 0.5,
			formationWidth = 8,
			aggroRange = 16,
			creditRadius = 40,
			interestRadius = 300,
			keyframeSeconds = 1,
			kinds = {
				melee = { maxHealth = 40, damage = 6, attackRange = 3.5, attackCooldown = 1.2, speed = 9, radius = 1.4 },
				ranged = { maxHealth = 30, damage = 5, attackRange = 14, attackCooldown = 1.6, speed = 9, radius = 1.2 },
				-- Phase 11 escalation: siege minions join waves late in a round so rounds end.
				siege = { maxHealth = 200, damage = 22, attackRange = 4.5, attackCooldown = 1.6, speed = 7, radius = 2 },
			},
		},
		monsters = Monsters,
		classDefinitions = Classes,
		classes = {
			default = "knight",
			status = { maxSlow = 0.8, stunImmunity = 1.5, maxShieldFraction = 0.6 },
			aimAssistCone = 30,
			allyAssistCone = 50,
			cooldownTolerance = 0.05,
			stationRange = 14,
			statusTickSeconds = 0.1,
			supportWindow = 10,
			teamworkPerClass = 0.12,
			teamworkWindow = 6,
		},
		camps = {
			types = { "splitter", "shellback", "burrower" },
			tierEdges = { 350, 180 },
			tiers = {
				{ healthScale = 1, damageScale = 1, respawnSeconds = 60, rarity = "common" },
				{ healthScale = 1.4, damageScale = 1.15, respawnSeconds = 75, rarity = "rare" },
				{ healthScale = 4, damageScale = 3, respawnSeconds = 90, rarity = "epic" },
			},
			leashRange = 45,
			resetSeconds = 6,
			groupScalePerAttacker = 0.15,
			maxGroupScale = 1.6,
		},
		eggs = {
			incubation = { common = 60, rare = 120, epic = 180, legendary = 240 },
			slots = 4,
			carrySpeedScale = 0.7,
			droppedSeconds = 90,
			raidSeconds = 3,
			raidRequiresOuterGuardian = true,
			choiceSeconds = 30,
			rarityScale = { common = 1, rare = 1.3, epic = 1.6, legendary = 2 },
			moveTolerance = 8,
			interactCooldown = 0.5,
		},
		progression = {
			xpBase = 100,
			xpGrowth = 25,
			xpExponent = 1.2,
			catchUpMultiplier = 2,
			petSlotLevels = { 1, 15, 40 },
			titles = {
				{ level = 5, name = "Recruit" },
				{ level = 15, name = "Tamer" },
				{ level = 40, name = "Warden" },
				{ level = 80, name = "Titanbreaker" },
			},
			petBonus = 0.2,
			petHalfXp = 2000,
			feedXp = { common = 200, rare = 400, epic = 800, legendary = 1600 },
			feedMatchBonus = 1.5,
			xp = {
				minion = 4,
				monsterPerHealth = 0.1,
				outerGuardian = 150,
				innerGuardian = 200,
				titan = 300,
				structureRange = 120,
				kill = 50,
				assist = 50,
				campClear = 40,
				eggDeposited = 30,
				eggHatched = 40,
				raid = 60,
				unleashPerDamage = 0.1,
				healPerHealth = 0.25,
			},
			petDamageScale = 0.3,
			petRespawnSeconds = 3,
		},
		data = {
			storePrefix = "dev_",
			storeName = "profiles_v1",
			autosaveSeconds = 60,
			staleLockSeconds = 600,
			loadAttempts = 4,
			allowMemoryFallback = true,
		},
		structures = {
			healthScale = 0.7,
			provokeSeconds = 4,
			provokeRange = 36,
			alertSeconds = 8,
			defenderRespawnScale = 0.5,
		},
		launchers = {
			padInset = 22,
			padRange = 10,
			landingOffset = 18,
			flightSpeed = 170,
			flightBase = 0.6,
			minSeconds = 1.5,
			maxSeconds = 4,
			apexPerStud = 0.25,
			minApex = 40,
			maxApex = 120,
			cooldownSeconds = 1,
		},
		balance = {
			equaliser = {
				gapForFull = 0.4,
				waveStrength = 0.25,
				respawn = 0.25,
				reward = 0.2,
				shortHanded = 0.05,
				shortHandedMax = 0.15,
				behindPerStructure = 0.2,
				behindMax = 0.5,
			},
			escalation = {
				startMinutes = 8,
				perMinute = 0.08,
				max = 1,
				siegeAfterMinutes = 12,
				siegeEveryMinutes = 5,
				siegeMax = 3,
			},
			comeback = { defenderRespawnScale = 0.5, fadeStartMinutes = 10, fadeEndMinutes = 25 },
			underdog = { k = 0.5, cap = 0.25 },
			bounty = { power = 1.35, streak = 4, base = 50, perStreak = 15, max = 200 },
			payout = {
				win = 200,
				loseShare = 0.8,
				contributionWeight = 0.3,
				longBonus = 0.25,
				longFromMinutes = 15,
				longFullMinutes = 30,
				closeBonus = 0.25,
				stayBonus = 50,
			},
			idle = { idleSeconds = 180, kickSeconds = 900 },
			boss = {
				firstMinutes = 10,
				respawnMinutes = 8,
				buffSeconds = 120,
				waveBuff = 0.5,
				-- The two jungle pits between the centre walls; the boss alternates between them.
				positions = { { x = 0, z = -150 }, { x = 0, z = 150 } },
				killXp = 150,
				xpRange = 80,
			},
		},
	}
end

-- Per-environment adjustments applied on top of `base`.
local overrides: { [Environment]: (config: Config) -> () } = {
	dev = function(_config: Config) end,
	test = function(config: Config)
		config.data.storePrefix = "test_"
		config.net.logViolations = false
	end,
	production = function(config: Config)
		config.debug.overlayExpandedByDefault = false
		config.net.validateServerPayloads = false
		config.combat.gym.enabled = false
		config.data.storePrefix = ""
		config.data.allowMemoryFallback = false
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
