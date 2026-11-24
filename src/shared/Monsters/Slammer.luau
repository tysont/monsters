--!strict
-- Slammer: the Phase 3 combat gym monster, with the tuning that passed combat testing.

local Types = require("./Types")

local definition: Types.Definition = {
	name = "Slammer",
	maxHealth = 400,
	radius = 4,
	height = 8,
	speed = 6,
	aggroRange = 45,
	leashRange = 90,
	defence = 0,
	wakeRange = 60,
	attacks = {
		{
			id = "slam",
			primitive = "slam",
			origin = "self",
			minRange = 0,
			maxRange = 8,
			damage = 35,
			telegraphSeconds = 1,
			recoverSeconds = 1.5,
			cooldown = 1,
			radius = 14,
			knockback = 30,
			heavy = true,
		},
	},
	stagger = { threshold = 120, seconds = 2.5, bonus = 1.5, decayPerSecond = 15 },
	phases = {},
	phaseTempo = 1,
}

return definition
