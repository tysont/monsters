--!strict
-- The class and ability format (Phase 10). A class is one definition file in this folder plus an
-- entry in `init.luau`. Abilities are plain data resolved by Shared.Abilities (aim, shapes) and
-- AbilityService (effects); there is no per-ability code.

export type Stats = {
	maxHealth: number,
	-- Base outgoing damage; every ability's damage and healing scale from it.
	damage: number,
	defence: number,
}

-- How an ability is aimed. Nothing needs pixel-precise aim: directions snap to a target in a
-- generous cone, points are clamped to range, and ally abilities pick the ally nearest the aim
-- (or the caster).
export type Aim =
	-- Centred on the caster.
	"self"
	-- From the caster along the aim direction (snapped by aim assist).
	| "direction"
	-- At a point on the ground, clamped to `range`.
	| "point"
	-- On one ally (or yourself) chosen from the aim direction within `range`.
	| "ally"

export type Shape = {
	-- "circle", "cone" or "line" (checked by tests).
	kind: string,
	-- circle: radius around the centre. cone: reach. line: length.
	size: number,
	-- cone: total arc in degrees. line: half width.
	width: number?,
}

export type Effect = {
	-- damage: scale x caster damage to each enemy hit.
	-- heal: scale x caster damage to each ally hit.
	-- status: a status effect; for shield and regen the magnitude is scale x caster damage,
	-- otherwise `magnitude` is used as is.
	-- "damage", "heal" or "status" (checked by tests).
	kind: string,
	scale: number?,
	-- A Shared.Combat.Status kind (checked by tests).
	status: string?,
	magnitude: number?,
	duration: number?,
	-- damage: extra multiplier against monsters (camp monsters, guardians, Titans).
	monsterBonus: number?,
	-- damage: knockback speed away from the shape centre.
	knockback: number?,
}

export type Ability = {
	id: string,
	name: string,
	description: string,
	-- A short glyph for the ability bar until Phase 13 icons.
	glyph: string,
	-- Class level that unlocks it (every class has its full kit by level 10).
	unlockLevel: number,
	cooldown: number,
	-- One of Aim (checked by tests).
	aim: string,
	-- Most distance from the caster for point and ally aim, and the aim assist reach.
	range: number?,
	shape: Shape?,
	-- Most enemies hit (nearest first; lines: first along the line).
	maxTargets: number?,
	enemy: { Effect }?,
	-- Allies in the shape (including the caster), or the chosen ally for "ally" aim.
	ally: { Effect }?,
	-- The caster only.
	self: { Effect }?,
	-- The caster dashes this far along the aim before the shape resolves (gap closer).
	dash: number?,
	-- Seconds between the cast and the shape resolving; clients show a telegraph.
	delay: number?,
	-- Placed as a trap at the aim point: arms after `arm` seconds, lasts `lifetime`, and resolves
	-- the shape when an enemy steps within `trigger`. At most `max` per caster.
	trap: { arm: number, lifetime: number, trigger: number, max: number }?,
	-- Visual: a bolt flies from the caster at this speed (studs per second) before impact.
	projectileSpeed: number?,
	-- The Knight's sword: uses the player melee path (Shared.Combat.Melee and the tuning panel).
	melee: boolean?,
}

-- Stub looks by class level (Phase 13 replaces them with real cosmetics).
export type Milestone = {
	level: number,
	name: string,
	-- Weapon accent colour (RGB 0-255).
	accent: { number },
	glow: boolean?,
	sparkles: boolean?,
}

export type Class = {
	id: string,
	name: string,
	role: string,
	description: string,
	-- Team-neutral class colour (RGB 0-255) for UI and effects.
	color: { number },
	stats: Stats,
	-- Primary attack (left mouse).
	basic: Ability,
	-- Abilities on keys 1, 2 and 3.
	abilities: { Ability },
	-- "sword", "bow", "staff" or "wand".
	weapon: string,
	milestones: { Milestone },
}

return nil
