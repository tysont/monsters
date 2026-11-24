--!strict
-- Splitling: the small blob a Splitter calls or splits into. Fast, weak, nips at your heels.

local Types = require("./Types")

local definition: Types.Definition = {
	name = "Splitling",
	maxHealth = 120,
	radius = 1.6,
	height = 3,
	speed = 11,
	aggroRange = 30,
	leashRange = 50,
	defence = 0,
	wakeRange = 45,
	attacks = {
		{
			id = "nip",
			primitive = "slam",
			origin = "self",
			minRange = 0,
			maxRange = 2.5,
			damage = 8,
			telegraphSeconds = 0.6,
			recoverSeconds = 0.6,
			cooldown = 1.4,
			radius = 3.5,
			knockback = 10,
		},
	},
	stagger = { threshold = 40, seconds = 2, bonus = 1.5, decayPerSecond = 10 },
	phases = {},
	phaseTempo = 1,
	look = { shape = "blob", color = { 240, 150, 200 } },
}

return definition
