--!strict
-- Inner guardian: locked until its lane's outer guardian falls. Tougher outer guardian.

local Types = require("./Types")

local definition: Types.Definition = {
	name = "Inner Guardian",
	maxHealth = 4000,
	radius = 5.5,
	height = 18,
	speed = 0,
	aggroRange = 30,
	leashRange = 0,
	defence = 0,
	wakeRange = 40,
	attacks = {
		{
			id = "slam",
			primitive = "slam",
			origin = "target",
			minRange = 0,
			maxRange = 30,
			damage = 36,
			telegraphSeconds = 1,
			recoverSeconds = 1.2,
			cooldown = 2.5,
			radius = 7.5,
			knockback = 32,
			heavy = true,
			weight = 2,
		},
		{
			id = "sweep",
			primitive = "sweep",
			minRange = 0,
			maxRange = 12,
			damage = 30,
			telegraphSeconds = 0.9,
			recoverSeconds = 1,
			cooldown = 2,
			reach = 18,
			arc = 110,
			knockback = 26,
			weight = 3,
		},
		{
			id = "bolt",
			primitive = "projectile",
			minRange = 8,
			maxRange = 30,
			damage = 24,
			telegraphSeconds = 0.6,
			recoverSeconds = 0.8,
			cooldown = 1.5,
			radius = 1.5,
			reach = 40,
			speed = 55,
			count = 1,
			spread = 0,
			knockback = 12,
			weight = 2,
		},
	},
	stagger = { threshold = 240, seconds = 3, bonus = 1.5, decayPerSecond = 20 },
	phases = {},
	phaseTempo = 1,
}

return definition
