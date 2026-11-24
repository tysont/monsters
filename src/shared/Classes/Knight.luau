--!strict
-- Knight: the front line. Closes the gap, holds monsters' attention and stops enemies cold.

local Types = require("./Types")

local Knight: Types.Class = {
	id = "knight",
	name = "Knight",
	role = "Tank",
	description = "Sword and shield. Charges in, taunts monsters off your team and stuns with a shield bash.",
	color = { 200, 205, 215 },
	stats = { maxHealth = 120, damage = 20, defence = 25 },
	weapon = "sword",
	basic = {
		id = "slash",
		name = "Slash",
		description = "A sword swing that hits up to three enemies in front of you.",
		glyph = "SL",
		unlockLevel = 1,
		cooldown = 0.5,
		aim = "direction",
		melee = true,
	},
	abilities = {
		{
			id = "charge",
			name = "Charge",
			description = "Dash forward and crash into enemies at the end, damaging and slowing them.",
			glyph = "CH",
			unlockLevel = 1,
			cooldown = 8,
			aim = "direction",
			range = 24,
			dash = 18,
			shape = { kind = "circle", size = 7 },
			maxTargets = 4,
			enemy = {
				{ kind = "damage", scale = 1.2, knockback = 18 } :: Types.Effect,
				{ kind = "status", status = "slow", magnitude = 0.4, duration = 2 } :: Types.Effect,
			},
		},
		{
			id = "rally",
			name = "Rally",
			description = "Taunt nearby monsters and minions to attack you, and raise a shield.",
			glyph = "RA",
			unlockLevel = 4,
			cooldown = 14,
			aim = "self",
			shape = { kind = "circle", size = 16 },
			maxTargets = 12,
			enemy = { { kind = "status", status = "taunt", duration = 4 } :: Types.Effect },
			self = { { kind = "status", status = "shield", scale = 2.5, duration = 5 } :: Types.Effect },
		},
		{
			id = "shieldBash",
			name = "Shield Bash",
			description = "Bash everything in front of you, stunning it briefly.",
			glyph = "SB",
			unlockLevel = 8,
			cooldown = 12,
			aim = "direction",
			range = 10,
			shape = { kind = "cone", size = 9, width = 110 },
			maxTargets = 5,
			enemy = {
				{ kind = "damage", scale = 1.4, knockback = 26 } :: Types.Effect,
				{ kind = "status", status = "stun", duration = 1.2 } :: Types.Effect,
			},
		},
	},
	milestones = {
		{ level = 1, name = "Squire", accent = { 200, 205, 215 } },
		{ level = 10, name = "Knight", accent = { 255, 200, 70 } },
		{ level = 25, name = "Champion", accent = { 255, 200, 70 }, glow = true },
		{ level = 50, name = "Paladin", accent = { 255, 240, 160 }, glow = true, sparkles = true },
	},
}

return Knight
