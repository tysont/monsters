--!strict
-- The monster definition format. A monster type is one definition file in this folder plus an
-- entry in `init.luau`; no new code. Definitions are plain data read by the shared behaviour
-- state machine (Shared.Combat.MonsterBrain) and MonsterService.

export type Primitive =
	-- A circle on the monster or on its target.
	"slam"
	-- A cone in front.
	| "sweep"
	-- Bolts that fly along a line.
	| "projectile"
	-- The monster dashes along a line, hitting everything it passes through once.
	| "charge"
	-- Calls `summon.count` monsters of type `summon.id` around itself (no damage).
	| "summon"
	-- Grabs the nearest body in a small circle at its target and throws it.
	| "grab"
	-- Burrows (untargetable), then erupts under where its target stood.
	| "burrow"

export type Attack = {
	id: string,
	primitive: Primitive,
	-- Slams land on the monster itself ("self") or where the target stood when it was chosen
	-- ("target").
	origin: ("self" | "target")?,
	-- Chosen only when the target's distance (to its edge) is in this band.
	minRange: number,
	maxRange: number,
	damage: number,
	telegraphSeconds: number,
	recoverSeconds: number,
	-- Seconds after this attack lands before it can be chosen again.
	cooldown: number,
	-- Slam, grab and burrow: circle radius. Projectile: bolt radius.
	radius: number?,
	-- Sweep: cone length. Projectile and charge: how far it travels.
	reach: number?,
	-- Sweep: total width in degrees.
	arc: number?,
	-- Projectile and charge: speed. Projectile: number of bolts and degrees between them.
	speed: number?,
	count: number?,
	spread: number?,
	-- Summon: the monster type and how many (at most `max` alive per summoner).
	summon: { id: string, count: number, max: number }?,
	knockback: number,
	-- Heavy hits knock players down instead of a shove.
	heavy: boolean?,
	-- First phase (1-based) this attack is used in.
	minPhase: number?,
	-- Relative chance among the attacks available at once.
	weight: number?,
}

-- One special rule per jungle monster type.
export type Signature =
	-- Hits from its front half do no damage: get behind it.
	"armoredFront"
	-- Splits into `split.count` monsters of type `split.id` when defeated.
	| "splits"
	-- Spends much of the fight underground (its burrow attack); hit it when it surfaces.
	| "burrower"

-- Placeholder look until real models arrive (Phase 13).
export type Look = {
	shape: "blocky" | "blob" | "shell" | "worm",
	color: { number },
}

export type Definition = {
	name: string,
	maxHealth: number,
	radius: number,
	height: number,
	-- 0 for stationary monsters.
	speed: number,
	-- Targets within this range of the monster's edge are engaged.
	aggroRange: number,
	-- Mobile monsters give up and walk home beyond this distance from home.
	leashRange: number,
	defence: number,
	-- Asleep (no logic) until a hostile comes within this range.
	wakeRange: number,
	attacks: { Attack },
	stagger: {
		-- Damage taken while recovering that fills the stagger bar.
		threshold: number,
		seconds: number,
		-- Damage taken is multiplied by this while staggered.
		bonus: number,
		-- The bar drains this fast outside recovery.
		decayPerSecond: number,
	},
	-- Health fractions where phases 2, 3, ... begin, descending. Empty for a single phase.
	phases: { number },
	-- Each phase after the first multiplies telegraph, recovery and cooldown times by this.
	phaseTempo: number,
	signature: Signature?,
	-- `splits`: what it splits into.
	split: { id: string, count: number }?,
	-- The egg type a camp of this monster drops (Phase 8), or nil for none.
	egg: string?,
	-- Asset references for the real model and animations (Phase 13); nil uses the placeholder.
	model: string?,
	animations: { [string]: string }?,
	look: Look?,
}

return nil
