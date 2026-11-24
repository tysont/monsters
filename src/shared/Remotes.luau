--!strict
-- Every remote in the game, in one place. Add a remote here, then use it through Shared.Net.
-- The key becomes the remote's instance name.

local Guard = require("./Net/Guard")
local Net = require("./Net")

export type ServerStats = {
	-- Average and worst heartbeat interval over the sample window, in milliseconds.
	frameMs: number,
	frameMaxMs: number,
	-- Engine-reported time spent in the heartbeat step, in milliseconds.
	heartbeatMs: number,
	sendKBps: number,
	receiveKBps: number,
	memoryMb: number,
	instances: number,
	players: number,
	-- Average milliseconds per frame spent simulating and replicating NPCs (NpcService).
	simMs: number,
}

export type AttackRequest = {
	-- Direction the attacker is facing (only x and z are used).
	direction: Vector3,
}

export type HitEvent = {
	target: number,
	source: number,
	amount: number,
	position: Vector3,
	-- Velocity to apply to the target (studs per second), zero for none.
	knockback: Vector3,
	killed: boolean,
	-- Heavy hits (big monster attacks) knock the target down.
	heavy: boolean,
}

export type KillEvent = {
	killer: number,
	victim: number,
	assists: { number },
}

export type NpcSpawnEvent = {
	-- Positive NPC ID (its combatant ID is the negative).
	id: number,
	kind: string,
	team: number?,
	maxHealth: number,
	radius: number,
	-- Body size multiplier (pets are smaller); nil for 1.
	scale: number?,
	-- Colour override 0xRRGGBB (pet skins); nil for the definition's colour.
	tint: number?,
}

-- A monster attack for clients to draw. Times are server time.
--   telegraph   draw `shape` filling from startsAt to endsAt
--   impact      the attack landed (effects); for projectiles see "projectile"
--   projectile  `count` bolts leave (x, z) at startsAt, fanned `spread` degrees around (dx, dz),
--               flying `reach` studs at `speed`
--   phase       the monster entered phase `value`
--   stagger     the monster is staggered until endsAt
export type MonsterActionEvent = {
	-- NPC ID.
	id: number,
	action: string,
	-- "circle" (x, z, radius), "cone" (x, z, dx, dz, reach, arc) or "line" (x, z, dx, dz, reach,
	-- radius as half-width, count and spread for fans).
	shape: string,
	x: number,
	z: number,
	dx: number,
	dz: number,
	radius: number,
	reach: number,
	arc: number,
	count: number,
	spread: number,
	speed: number,
	startsAt: number,
	endsAt: number,
	value: number,
}

export type HatchReadyEvent = {
	egg: number,
	kind: string,
	rarity: string,
	hatchery: string,
	expiresAt: number,
}

export type LevelUpEvent = {
	level: number,
	class: string,
}

export type HatchChoiceRequest = {
	egg: number,
	choice: string,
	target: number?,
}

export type RaidAlertEvent = {
	hatchery: string,
	lane: string,
	raider: string,
}

-- A launch pad flight for the local player to fly (the server picked the landing spot).
-- A class ability cast (Phase 10). Slot 0 is the basic attack for non-melee classes; 1 to 3 the
-- abilities. `point` is the ground point for point-aimed abilities.
export type AbilityCastRequest = {
	slot: number,
	direction: Vector3,
	point: Vector3?,
}

-- Someone cast an ability (for effects). `origin` is where the shape starts (after any dash),
-- `target` its centre or the end of a line, `delay` the seconds until it resolves.
export type AbilityFxEvent = {
	caster: number,
	class: string,
	slot: number,
	origin: Vector3,
	target: Vector3,
	direction: Vector3,
	delay: number,
}

export type LaunchEvent = {
	from: Vector3,
	to: Vector3,
	duration: number,
	apex: number,
	-- What it flies to, for the toast (e.g. "top outer guardian").
	label: string,
}

-- Phase 12 shop and cosmetics.
export type EquipRequest = {
	slot: string,
	-- nil clears the slot.
	item: string?,
}

export type PetSkinRequest = {
	pet: number,
	item: string?,
}

export type KillEffectEvent = {
	item: string,
	position: Vector3,
}

export type EmoteEvent = {
	player: number,
	item: string,
}

export type AnnounceEvent = {
	text: string,
	-- Toast kind: "info", "success", "warning" or "danger".
	kind: string,
}

export type RoundSummary = {
	round: number,
	winner: number,
	-- Seconds the round was Active.
	duration: number,
	myTeam: number,
	kills: number,
	deaths: number,
	assists: number,
	damage: number,
	structureDamage: number,
	minions: number,
	structuresDestroyed: number,
	-- Per team (index 1 and 2).
	teamKills: { number },
	teamStructures: { number },
	-- Display name of the top scorer, or "" if nobody scored.
	mvp: string,
}

export type WaveInfo = {
	lane: string,
	team: number,
	count: number,
	front: number,
}

export type TuningRequest = {
	key: string,
	value: number,
}

local finite = Guard.number()
local id = Guard.number({ integer = true })

return Net.define({
	-- Combat -------------------------------------------------------------------------------

	-- A swing. The server checks cooldown, range, arc and line of sight and picks the targets.
	CombatAttack = Net.clientToServer({
		check = Guard.struct({ direction = Guard.vector3() }) :: Guard.Check<AttackRequest>,
		rateLimit = { rate = 8, burst = 10 },
	}),

	-- A dodge. The client moves its own character; the server grants invulnerability.
	CombatDodge = Net.clientToServer({
		check = Guard.none,
		rateLimit = { rate = 4, burst = 6 },
	}),

	-- Someone swung (for other clients to play the swing). Payload is the attacker's combatant ID.
	CombatSwing = Net.serverToClient({
		check = id,
		reliable = false,
	}),

	-- Damage was dealt (damage numbers, hit flash, knockback).
	CombatHit = Net.serverToClient({
		check = Guard.struct({
			target = id,
			source = id,
			amount = finite,
			position = Guard.vector3(),
			knockback = Guard.vector3(),
			killed = Guard.boolean,
			heavy = Guard.boolean,
		}) :: Guard.Check<HitEvent>,
	}),

	-- A combatant was defeated (kill feed, kill and assist credit).
	CombatKill = Net.serverToClient({
		check = Guard.struct({
			killer = id,
			victim = id,
			assists = Guard.array(id, 64),
		}) :: Guard.Check<KillEvent>,
	}),

	-- NPCs (data rows rendered by clients) --------------------------------------------------

	-- Client is ready for NPC state; the server replies with every live NPC's spawn event.
	NpcReady = Net.clientToServer({
		check = Guard.none,
		rateLimit = { rate = 0.5, burst = 2 },
	}),

	NpcSpawn = Net.serverToClient({
		check = Guard.struct({
			id = id,
			kind = Guard.string(32),
			team = Guard.optional(id),
			maxHealth = finite,
			radius = finite,
			scale = Guard.optional(finite),
			tint = Guard.optional(id),
		}) :: Guard.Check<NpcSpawnEvent>,
	}),

	NpcDespawn = Net.serverToClient({
		check = id,
	}),

	-- Packed positions, facing, health and state (Shared.Combat.NpcCodec), chunked under 900 bytes.
	NpcSnapshot = Net.serverToClient({
		check = Guard.buffer(1000),
		reliable = false,
	}),

	-- Minions near this client (Shared.Combat.MinionCodec): only changed minions, plus every
	-- minion in range once a second. Chunked under 900 bytes.
	MinionSnapshot = Net.serverToClient({
		check = Guard.buffer(1000),
		reliable = false,
	}),

	-- Once a second, for the minimap: per lane and team, how many minions are alive and how far
	-- the front of the wave has advanced (0 = own base, 1 = enemy base).
	WaveSummary = Net.serverToClient({
		check = Guard.array(
			Guard.struct({
				lane = Guard.oneOf({ "top", "middle", "bottom" }),
				team = id,
				count = id,
				front = finite,
			}),
			6
		) :: Guard.Check<{ WaveInfo }>,
		reliable = false,
	}),

	-- A monster telegraph, impact, projectile launch, phase change or stagger (see
	-- MonsterActionEvent).
	MonsterAction = Net.serverToClient({
		check = Guard.struct({
			id = id,
			action = Guard.oneOf({ "telegraph", "impact", "projectile", "phase", "stagger" }),
			shape = Guard.oneOf({ "circle", "cone", "line", "none" }),
			x = finite,
			z = finite,
			dx = finite,
			dz = finite,
			radius = finite,
			reach = finite,
			arc = finite,
			count = id,
			spread = finite,
			speed = finite,
			startsAt = finite,
			endsAt = finite,
			value = finite,
		}) :: Guard.Check<MonsterActionEvent>,
	}),

	-- Eggs and hatcheries ---------------------------------------------------------------------

	-- To the owner: an egg they incubated has hatched; choose what it becomes before `expiresAt`
	-- (server time), or it is unleashed.
	HatchReady = Net.serverToClient({
		check = Guard.struct({
			egg = id,
			kind = Guard.string(32),
			rarity = Guard.string(16),
			hatchery = Guard.string(32),
			expiresAt = finite,
		}) :: Guard.Check<HatchReadyEvent>,
	}),

	-- The owner's choice for a hatched egg. `target`: the pet to replace (claim with a full
	-- stable) or to feed.
	HatchChoice = Net.clientToServer({
		check = Guard.struct({
			egg = id,
			choice = Guard.oneOf({ "claim", "feed", "unleash" }),
			target = Guard.optional(id),
		}) :: Guard.Check<HatchChoiceRequest>,
		rateLimit = { rate = 2, burst = 4 },
	}),

	-- Progression and pets ---------------------------------------------------------------------

	-- To the player: their active class levelled up.
	LevelUp = Net.serverToClient({
		check = Guard.struct({ level = id, class = Guard.string(32) }) :: Guard.Check<LevelUpEvent>,
	}),

	-- Choose the active pet (0 for none). Only allowed in your own base.
	SetActivePet = Net.clientToServer({
		check = id,
		rateLimit = { rate = 1, burst = 3 },
	}),

	-- To the defending team: an enemy started raiding one of their hatcheries.
	RaidAlert = Net.serverToClient({
		check = Guard.struct({
			hatchery = Guard.string(32),
			lane = Guard.string(16),
			raider = Guard.string(64),
		}) :: Guard.Check<RaidAlertEvent>,
	}),

	-- Classes ------------------------------------------------------------------------------

	AbilityCast = Net.clientToServer({
		check = Guard.struct({
			slot = Guard.number({ integer = true, min = 0, max = 3 }),
			direction = Guard.vector3(),
			point = Guard.optional(Guard.vector3()),
		}) :: Guard.Check<AbilityCastRequest>,
		rateLimit = { rate = 10, burst = 16 },
	}),

	AbilityFx = Net.serverToClient({
		check = Guard.struct({
			caster = id,
			class = Guard.string(16),
			slot = id,
			origin = Guard.vector3(),
			target = Guard.vector3(),
			direction = Guard.vector3(),
			delay = finite,
		}) :: Guard.Check<AbilityFxEvent>,
	}),

	-- Choose the active class: on first join, at the base class station, or while dead.
	ChooseClass = Net.clientToServer({
		check = Guard.string(16),
		rateLimit = { rate = 1, burst = 3 },
	}),

	-- To the launching player: fly this arc (Shared.Launchers).
	Launch = Net.serverToClient({
		check = Guard.struct({
			from = Guard.vector3(),
			to = Guard.vector3(),
			duration = finite,
			apex = finite,
			label = Guard.string(64),
		}) :: Guard.Check<LaunchEvent>,
	}),

	-- A short message for everyone (or a team): bounties, the jungle boss.
	Announce = Net.serverToClient({
		check = Guard.struct({
			text = Guard.string(200),
			kind = Guard.string(16),
		}) :: Guard.Check<AnnounceEvent>,
	}),

	-- Shop and cosmetics (Phase 12) ---------------------------------------------------------

	BuyCosmetic = Net.clientToServer({
		check = Guard.string(32),
		rateLimit = { rate = 2, burst = 5 },
	}),

	EquipCosmetic = Net.clientToServer({
		check = Guard.struct({
			slot = Guard.string(16),
			item = Guard.optional(Guard.string(32)),
		}) :: Guard.Check<EquipRequest>,
		rateLimit = { rate = 4, burst = 10 },
	}),

	SelectLoadout = Net.clientToServer({
		check = Guard.number({ integer = true, min = 1, max = 10 }),
		rateLimit = { rate = 2, burst = 5 },
	}),

	SetPetSkin = Net.clientToServer({
		check = Guard.struct({
			pet = id,
			item = Guard.optional(Guard.string(32)),
		}) :: Guard.Check<PetSkinRequest>,
		rateLimit = { rate = 2, burst = 5 },
	}),

	-- Play your equipped emote (others nearby see it).
	Emote = Net.clientToServer({
		check = Guard.none,
		rateLimit = { rate = 0.5, burst = 2 },
	}),

	EmotePlayed = Net.serverToClient({
		check = Guard.struct({ player = id, item = Guard.string(32) }) :: Guard.Check<EmoteEvent>,
	}),

	-- A kill effect where a victim fell (the killer's equipped effect).
	KillEffect = Net.serverToClient({
		check = Guard.struct({ item = Guard.string(32), position = Guard.vector3() }) :: Guard.Check<KillEffectEvent>,
	}),

	-- Rounds ---------------------------------------------------------------------------------

	-- Sent to each player when a round ends: the result and their stats for the round.
	RoundSummary = Net.serverToClient({
		check = Guard.struct({
			round = id,
			winner = id,
			duration = finite,
			myTeam = id,
			kills = id,
			deaths = id,
			assists = id,
			damage = finite,
			structureDamage = finite,
			minions = id,
			structuresDestroyed = id,
			teamKills = Guard.array(id, 2),
			teamStructures = Guard.array(id, 2),
			mvp = Guard.string(64),
		}) :: Guard.Check<RoundSummary>,
	}),

	-- Dev tools ----------------------------------------------------------------------------

	-- Dev tool: set one live-tuning value (Shared.Combat.Tuning). Ignored without dev access.
	DevSetTuning = Net.clientToServer({
		check = Guard.struct({ key = Guard.string(40), value = finite }) :: Guard.Check<TuningRequest>,
		rateLimit = { rate = 10, burst = 20 },
	}),

	-- Dev tool: clear every live-tuning override back to the Config defaults.
	DevResetTuning = Net.clientToServer({
		check = Guard.none,
		rateLimit = { rate = 1, burst = 3 },
	}),
	-- Client tells the server whether its debug overlay is expanded, so stats go only where shown.
	DebugOverlayExpanded = Net.clientToServer({
		check = Guard.boolean,
		rateLimit = { rate = 2, burst = 5 },
	}),

	-- Dev tool: multiplies the sender's walk speed (1 = normal). Ignored for players without
	-- dev access.
	DevSetSpeedMultiplier = Net.clientToServer({
		check = Guard.number({ min = 1, max = 8 }),
		rateLimit = { rate = 2, burst = 5 },
	}),

	-- Dev tool: a reply to a dev chat command, shown as a system message in chat.
	DevMessage = Net.serverToClient({
		check = Guard.string(2000),
	}),

	-- Server performance numbers for the debug overlay, sent about once a second.
	DebugServerStats = Net.serverToClient({
		check = Guard.struct({
			frameMs = Guard.number(),
			frameMaxMs = Guard.number(),
			heartbeatMs = Guard.number(),
			sendKBps = Guard.number(),
			receiveKBps = Guard.number(),
			memoryMb = Guard.number(),
			instances = Guard.number({ integer = true }),
			players = Guard.number({ integer = true }),
			simMs = Guard.number(),
		}) :: Guard.Check<ServerStats>,
		reliable = false,
	}),
})
