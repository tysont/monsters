--!strict
-- Levels, XP, catch-up, account level, unlocks and pet power (Appendix A). Pure, unit tested
-- under Lune.
--
--   Class level: each class has its own level and XP; XP earned goes to the active class. The
--     XP to go from level L to L + 1 grows gently and never caps.
--   Catch-up: a class below the player's highest class level earns XP at the catch-up multiplier
--     until it reaches that level; an award that crosses the threshold is multiplied only up to
--     it.
--   Account level: the sum of all class levels. Gates pet slots and titles.
--   Combat power: class level multiplier (Shared.Combat.Stats) times pet multiplier,
--     1 + 0.20 * x / (x + h) for pet XP x, so a maxed player is about 1.5 times a new one.

local Config = require("./Config")
local Stats = require("./Combat/Stats")

export type ClassProgress = { level: number, xp: number }

export type AwardResult = {
	-- XP actually added after catch-up.
	gained: number,
	levelsGained: number,
}

local Progression = {}

-- XP needed to go from `level` to `level + 1`.
function Progression.xpToNext(level: number, config: Config.ProgressionConfig): number
	return math.floor(config.xpBase + config.xpGrowth * (math.max(1, level) - 1) ^ config.xpExponent + 0.5)
end

-- Total XP after applying catch-up to `amount` for a class at `progress` when the player's
-- highest class level is `highest`. Only the XP needed to reach `highest` is multiplied.
function Progression.catchUpAmount(
	progress: ClassProgress,
	highest: number,
	amount: number,
	config: Config.ProgressionConfig
): number
	if amount <= 0 or progress.level >= highest then
		return math.max(0, amount)
	end
	-- Raw XP from here to the start of level `highest`.
	local needed = Progression.xpToNext(progress.level, config) - progress.xp
	for level = progress.level + 1, highest - 1 do
		needed += Progression.xpToNext(level, config)
	end
	local multiplier = config.catchUpMultiplier
	local boosted = amount * multiplier
	if boosted <= needed then
		return boosted
	end
	-- Crossing: the part that fills the gap is boosted, the rest is not.
	local rawUsed = needed / multiplier
	return needed + (amount - rawUsed)
end

-- Adds XP to a class in place (with catch-up), levelling up as many times as it earns.
function Progression.award(
	progress: ClassProgress,
	highest: number,
	amount: number,
	config: Config.ProgressionConfig
): AwardResult
	local gained = Progression.catchUpAmount(progress, highest, amount, config)
	progress.xp += gained
	local levels = 0
	while progress.xp >= Progression.xpToNext(progress.level, config) do
		progress.xp -= Progression.xpToNext(progress.level, config)
		progress.level += 1
		levels += 1
	end
	return { gained = gained, levelsGained = levels }
end

function Progression.accountLevel(classes: { [string]: ClassProgress }): number
	local total = 0
	for _, progress in classes do
		total += progress.level
	end
	return total
end

function Progression.highestLevel(classes: { [string]: ClassProgress }): number
	local best = 1
	for _, progress in classes do
		best = math.max(best, progress.level)
	end
	return best
end

-- Pet slots unlocked at an account level.
function Progression.petSlots(accountLevel: number, config: Config.ProgressionConfig): number
	local slots = 0
	for _, required in config.petSlotLevels do
		if accountLevel >= required then
			slots += 1
		end
	end
	return slots
end

-- Titles unlocked at an account level, in unlock order.
function Progression.titles(accountLevel: number, config: Config.ProgressionConfig): { string }
	local list: { string } = {}
	for _, t in config.titles do
		if accountLevel >= t.level then
			table.insert(list, t.name)
		end
	end
	return list
end

function Progression.petMultiplier(petXp: number, config: Config.ProgressionConfig): number
	local x = math.max(0, petXp)
	return 1 + config.petBonus * x / (x + config.petHalfXp)
end

-- Combat power (the stat multiplier and the member power for team strength).
function Progression.power(classLevel: number, petXp: number?, config: Config.ProgressionConfig): number
	local pet = if petXp then Progression.petMultiplier(petXp, config) else 1
	return Stats.levelMultiplier(classLevel) * pet
end

-- Pet XP from feeding a hatched egg of `rarity` and `kind` to a pet of `petKind`.
function Progression.feedXp(rarity: string, kind: string, petKind: string, config: Config.ProgressionConfig): number
	local base = (config.feedXp :: any)[rarity] or config.feedXp.common
	return if kind == petKind then math.floor(base * config.feedMatchBonus + 0.5) else base
end

return Progression
