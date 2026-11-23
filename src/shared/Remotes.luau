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
}

export type NpcActionEvent = {
	id: number,
	action: string,
	x: number,
	z: number,
	radius: number,
	duration: number,
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

	-- A telegraph or impact for clients to draw.
	NpcAction = Net.serverToClient({
		check = Guard.struct({
			id = id,
			action = Guard.oneOf({ "telegraph", "impact" }),
			x = finite,
			z = finite,
			radius = finite,
			duration = finite,
		}) :: Guard.Check<NpcActionEvent>,
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
		check = Guard.string(500),
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
