--!strict
-- The single stat function (Appendix A). Pure, unit tested under Lune.
--
--   level multiplier  1 + 0.25 * L / (L + 20), where L = class level - 1, so level 1 is exactly
--                     1.0 and the ceiling is 1.25
--   pet multiplier    1.0 to 1.2 (stubbed at 1.0 until Phase 9)
--   power             level multiplier * pet multiplier (1.0 new, up to 1.5); also the
--                     member power used for team strength (TeamService.powerOf)

local Config = require("../Config")

export type Stats = {
	maxHealth: number,
	damage: number,
	defence: number,
	-- Combined combat multiplier.
	power: number,
}

local Stats = {}

function Stats.levelMultiplier(classLevel: number): number
	local l = math.max(0, classLevel - 1)
	return 1 + 0.25 * l / (l + 20)
end

-- Stats for a class at a level with a pet multiplier (1.0 when there is no pet).
function Stats.compute(base: Config.ClassStats, classLevel: number, petMultiplier: number?): Stats
	local power = Stats.levelMultiplier(classLevel) * (petMultiplier or 1)
	return {
		maxHealth = math.floor(base.maxHealth * power + 0.5),
		damage = base.damage * power,
		defence = base.defence,
		power = power,
	}
end

return Stats
