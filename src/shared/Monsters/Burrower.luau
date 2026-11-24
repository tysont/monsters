--!strict
-- Burrower (jungle): a sand worm. Signature: it spends much of the fight underground, where it
-- cannot be hit, and erupts under where you stood; up close it grabs and throws. Keep moving
-- when the ground marks you, then hit it while it recovers on the surface.

local Types = require("./Types")

local definition: Types.Definition = {
	name = "Burrower",
	maxHealth = 600,
	radius = 3,
	height = 7,
	speed = 6,
	aggroRange = 32,
	leashRange = 45,
	defence = 0,
	wakeRange = 45,
	attacks = {
		{
			id = "burrow",
			primitive = "burrow",
			origin = "target",
			minRange = 0,
			maxRange = 30,
			damage = 30,
			telegraphSeconds = 1.4,
			recoverSeconds = 1.4,
			cooldown = 4,
			radius = 6,
			knockback = 35,
			heavy = true,
			weight = 3,
		},
		{
			id = "grab",
			primitive = "grab",
			origin = "target",
			minRange = 0,
			maxRange = 5,
			damage = 22,
			telegraphSeconds = 0.8,
			recoverSeconds = 1,
			cooldown = 3,
			radius = 3.5,
			knockback = 70,
			heavy = true,
			weight = 2,
		},
	},
	stagger = { threshold = 120, seconds = 2.5, bonus = 1.5, decayPerSecond = 15 },
	phases = {},
	phaseTempo = 1,
	signature = "burrower",
	egg = "burrower",
	look = { shape = "worm", color = { 200, 170, 110 } },
}

return definition
