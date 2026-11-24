--!strict
-- Healer: keeps the team alive, and can still fight alone.

local Types = require("./Types")

-- Blessing: everything the Healer casts on allies also empowers them (+20% damage dealt). Like
-- the Hunter's mark it does not add up with itself.
local BLESSING = 0.2

local Healer: Types.Class = {
	id = "healer",
	name = "Healer",
	role = "Support",
	description = "Wand. Heals and shields allies and blesses them to hit harder; smites enemies.",
	color = { 255, 220, 120 },
	stats = { maxHealth = 95, damage = 13, defence = 0 },
	weapon = "wand",
	basic = {
		id = "smite",
		name = "Smite",
		description = "A bolt of light at the first enemy in line.",
		glyph = "SM",
		unlockLevel = 1,
		cooldown = 0.7,
		aim = "direction",
		range = 34,
		shape = { kind = "line", size = 34, width = 2.5 },
		maxTargets = 1,
		projectileSpeed = 110,
		enemy = { { kind = "damage", scale = 1 } :: Types.Effect },
	},
	abilities = {
		{
			id = "mend",
			name = "Mend",
			description = "Heal the ally you aim at (or yourself), heal them over time, and bless them: +20% damage.",
			glyph = "ME",
			unlockLevel = 1,
			cooldown = 5,
			aim = "ally",
			range = 40,
			ally = {
				{ kind = "heal", scale = 2.6 } :: Types.Effect,
				{ kind = "status", status = "regen", scale = 0.4, duration = 4 } :: Types.Effect,
				{ kind = "status", status = "empower", magnitude = BLESSING, duration = 6 } :: Types.Effect,
			},
		},
		{
			id = "sanctuary",
			name = "Sanctuary",
			description = "Bless an area: allies in it are healed and empowered, enemies in it are burned.",
			glyph = "SA",
			unlockLevel = 4,
			cooldown = 14,
			aim = "point",
			range = 30,
			shape = { kind = "circle", size = 12 },
			maxTargets = 10,
			ally = {
				{ kind = "heal", scale = 1.6 } :: Types.Effect,
				{ kind = "status", status = "regen", scale = 0.3, duration = 4 } :: Types.Effect,
				{ kind = "status", status = "empower", magnitude = BLESSING, duration = 6 } :: Types.Effect,
			},
			enemy = { { kind = "damage", scale = 0.6 } :: Types.Effect },
		},
		{
			id = "barrier",
			name = "Barrier",
			description = "Shield and empower yourself and every ally around you.",
			glyph = "BA",
			unlockLevel = 8,
			cooldown = 16,
			aim = "self",
			shape = { kind = "circle", size = 16 },
			maxTargets = 10,
			ally = {
				{ kind = "status", status = "shield", scale = 2.4, duration = 6 } :: Types.Effect,
				{ kind = "status", status = "empower", magnitude = BLESSING, duration = 6 } :: Types.Effect,
			},
		},
	},
	milestones = {
		{ level = 1, name = "Acolyte", accent = { 255, 220, 120 } },
		{ level = 10, name = "Healer", accent = { 255, 200, 70 } },
		{ level = 25, name = "Cleric", accent = { 255, 200, 70 }, glow = true },
		{ level = 50, name = "Saint", accent = { 255, 250, 210 }, glow = true, sparkles = true },
	},
}

return Healer
