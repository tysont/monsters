--!strict
-- Hunter: ranged damage. Arrows find monsters' weak points; traps and marks set up the team.

local Types = require("./Types")

-- Arrows hit monsters' weak points.
local WEAK_POINT = 1.35

local Hunter: Types.Class = {
	id = "hunter",
	name = "Hunter",
	role = "Ranged damage",
	description = "Bow. Strong against monsters' weak points; snares enemies and marks targets for the team.",
	color = { 120, 200, 90 },
	stats = { maxHealth = 85, damage = 17, defence = 0 },
	weapon = "bow",
	basic = {
		id = "arrow",
		name = "Arrow",
		description = "A long-range arrow. Extra damage to monsters (weak points).",
		glyph = "AR",
		unlockLevel = 1,
		cooldown = 0.6,
		aim = "direction",
		range = 45,
		shape = { kind = "line", size = 45, width = 2.5 },
		maxTargets = 1,
		projectileSpeed = 160,
		enemy = { { kind = "damage", scale = 1, monsterBonus = WEAK_POINT } :: Types.Effect },
	},
	abilities = {
		{
			id = "volley",
			name = "Volley",
			description = "A fan of arrows that hits everything in a wide cone.",
			glyph = "VO",
			unlockLevel = 1,
			cooldown = 8,
			aim = "direction",
			range = 32,
			shape = { kind = "cone", size = 32, width = 50 },
			maxTargets = 6,
			enemy = { { kind = "damage", scale = 0.9, monsterBonus = WEAK_POINT } :: Types.Effect },
		},
		{
			id = "snare",
			name = "Snare Trap",
			description = "Place a trap that snares and damages the first enemies to step near it.",
			glyph = "TR",
			unlockLevel = 4,
			cooldown = 10,
			aim = "point",
			range = 30,
			shape = { kind = "circle", size = 7 },
			maxTargets = 4,
			trap = { arm = 0.8, lifetime = 25, trigger = 5, max = 2 },
			enemy = {
				{ kind = "damage", scale = 0.8 } :: Types.Effect,
				{ kind = "status", status = "slow", magnitude = 0.7, duration = 3 } :: Types.Effect,
			},
		},
		{
			id = "mark",
			name = "Marked Shot",
			description = "A heavy arrow that marks its target: it takes 25% more damage from everyone.",
			glyph = "MK",
			unlockLevel = 8,
			cooldown = 12,
			aim = "direction",
			range = 60,
			shape = { kind = "line", size = 60, width = 3 },
			maxTargets = 1,
			projectileSpeed = 220,
			enemy = {
				{ kind = "damage", scale = 1.8, monsterBonus = WEAK_POINT } :: Types.Effect,
				{ kind = "status", status = "vulnerable", magnitude = 0.25, duration = 6 } :: Types.Effect,
			},
		},
	},
	milestones = {
		{ level = 1, name = "Tracker", accent = { 120, 200, 90 } },
		{ level = 10, name = "Hunter", accent = { 255, 200, 70 } },
		{ level = 25, name = "Ranger", accent = { 255, 200, 70 }, glow = true },
		{ level = 50, name = "Beastmaster", accent = { 190, 255, 160 }, glow = true, sparkles = true },
	},
}

return Hunter
