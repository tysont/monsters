--!strict
-- Splitter (jungle): a jelly blob that calls splitlings to its side. Signature: splits into two
-- splitlings when defeated, so the fight ends only when the pieces are cleared too. Thin the
-- splitlings or burst the big one down and deal with the rest.

local Types = require("./Types")

local definition: Types.Definition = {
	name = "Splitter",
	maxHealth = 380,
	radius = 3.2,
	height = 6,
	speed = 8,
	aggroRange = 30,
	leashRange = 45,
	defence = 0,
	wakeRange = 45,
	attacks = {
		{
			id = "slam",
			primitive = "slam",
			origin = "self",
			minRange = 0,
			maxRange = 4,
			damage = 20,
			telegraphSeconds = 0.9,
			recoverSeconds = 1,
			cooldown = 2.2,
			radius = 7,
			knockback = 25,
			weight = 3,
		},
		{
			id = "call",
			primitive = "summon",
			minRange = 0,
			maxRange = 25,
			damage = 0,
			telegraphSeconds = 1.2,
			recoverSeconds = 1.2,
			cooldown = 9,
			radius = 4,
			summon = { id = "splitling", count = 2, max = 3 },
			knockback = 0,
			weight = 1,
		},
	},
	stagger = { threshold = 90, seconds = 2.5, bonus = 1.5, decayPerSecond = 15 },
	phases = {},
	phaseTempo = 1,
	signature = "splits",
	split = { id = "splitling", count = 2 },
	egg = "splitter",
	look = { shape = "blob", color = { 220, 110, 170 } },
}

return definition
