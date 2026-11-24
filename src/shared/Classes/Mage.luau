--!strict
-- Mage: area damage and crowd control.

local Types = require("./Types")

local Mage: Types.Class = {
	id = "mage",
	name = "Mage",
	role = "Area damage",
	description = "Staff. Fireballs for groups, frost to slow them and a prison that stuns.",
	color = { 150, 110, 255 },
	stats = { maxHealth = 80, damage = 20, defence = 0 },
	weapon = "staff",
	basic = {
		id = "bolt",
		name = "Arcane Bolt",
		description = "A magic bolt at the first enemy in line.",
		glyph = "BO",
		unlockLevel = 1,
		cooldown = 0.7,
		aim = "direction",
		range = 36,
		shape = { kind = "line", size = 36, width = 2.5 },
		maxTargets = 1,
		projectileSpeed = 120,
		enemy = { { kind = "damage", scale = 1 } :: Types.Effect },
	},
	abilities = {
		{
			id = "fireball",
			name = "Fireball",
			description = "Hurl a fireball that bursts on the ground, hitting everything around it.",
			glyph = "FB",
			unlockLevel = 1,
			cooldown = 7,
			aim = "point",
			range = 40,
			shape = { kind = "circle", size = 8 },
			maxTargets = 8,
			projectileSpeed = 90,
			enemy = { { kind = "damage", scale = 1.5, knockback = 12 } :: Types.Effect },
		},
		{
			id = "frostNova",
			name = "Frost Nova",
			description = "A blast of frost around you that damages and slows.",
			glyph = "FN",
			unlockLevel = 4,
			cooldown = 12,
			aim = "self",
			shape = { kind = "circle", size = 13 },
			maxTargets = 10,
			enemy = {
				{ kind = "damage", scale = 0.7 } :: Types.Effect,
				{ kind = "status", status = "slow", magnitude = 0.5, duration = 3 } :: Types.Effect,
			},
		},
		{
			id = "prison",
			name = "Arcane Prison",
			description = "After a short delay, stun everything in an area.",
			glyph = "AP",
			unlockLevel = 8,
			cooldown = 16,
			aim = "point",
			range = 35,
			delay = 0.7,
			shape = { kind = "circle", size = 8 },
			maxTargets = 8,
			enemy = {
				{ kind = "damage", scale = 0.8 } :: Types.Effect,
				{ kind = "status", status = "stun", duration = 1.6 } :: Types.Effect,
			},
		},
	},
	milestones = {
		{ level = 1, name = "Apprentice", accent = { 150, 110, 255 } },
		{ level = 10, name = "Mage", accent = { 255, 200, 70 } },
		{ level = 25, name = "Sorcerer", accent = { 255, 200, 70 }, glow = true },
		{ level = 50, name = "Archmage", accent = { 210, 190, 255 }, glow = true, sparkles = true },
	},
}

return Mage
