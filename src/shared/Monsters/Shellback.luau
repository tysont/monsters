--!strict
-- Shellback (jungle): a shelled brute. Signature: hits on its armoured front do nothing. Its
-- charge carries it past you and leaves its back open while it recovers, so dodge the charge
-- and punish from behind.

local Types = require("./Types")

local definition: Types.Definition = {
	name = "Shellback",
	maxHealth = 280,
	radius = 3.5,
	height = 6,
	speed = 7,
	aggroRange = 30,
	leashRange = 45,
	defence = 0,
	wakeRange = 45,
	attacks = {
		{
			id = "bite",
			primitive = "sweep",
			minRange = 0,
			maxRange = 6,
			damage = 18,
			telegraphSeconds = 0.8,
			recoverSeconds = 0.9,
			cooldown = 2,
			reach = 10,
			arc = 100,
			knockback = 25,
			weight = 2,
		},
		{
			id = "charge",
			primitive = "charge",
			minRange = 0,
			maxRange = 26,
			damage = 28,
			telegraphSeconds = 1,
			recoverSeconds = 2,
			cooldown = 4.5,
			reach = 30,
			speed = 45,
			knockback = 40,
			heavy = true,
			weight = 3,
		},
	},
	stagger = { threshold = 120, seconds = 2.5, bonus = 1.5, decayPerSecond = 15 },
	phases = {},
	phaseTempo = 1,
	signature = "armoredFront",
	egg = "shellback",
	look = { shape = "shell", color = { 96, 140, 84 } },
}

return definition
