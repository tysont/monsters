--!strict
-- Egg and hatchery rules, pure and unit tested under Lune. EggService and HatcheryService apply
-- them on the server; clients use them to show what is possible.
--
--   States: dropped (on the ground) -> carried -> incubating (in a hatchery slot) -> hatched.
--   Anyone may pick up a dropped egg. A carrier deposits it at one of their own team's
--   hatcheries with a free slot. An enemy may raid an incubating egg only once that lane's
--   outer guardian is dead; the raider then carries it home and incubation starts over.

local Config = require("./Config")

export type State = "dropped" | "carried" | "incubating" | "hatched"

export type Choice = "claim" | "feed" | "unleash"

local Eggs = {}

function Eggs.incubationSeconds(rarity: string, config: Config.EggConfig): number
	return (config.incubation :: any)[rarity] or config.incubation.common
end

-- Health and damage multiplier for an unleashed monster of this rarity.
function Eggs.rarityScale(rarity: string, config: Config.EggConfig): number
	return (config.rarityScale :: any)[rarity] or 1
end

function Eggs.canPickUp(state: State): boolean
	return state == "dropped"
end

-- Whether a carrier on `carrierTeam` can deposit into a hatchery of `hatcheryTeam` that has
-- `freeSlots` free.
function Eggs.canDeposit(carrierTeam: number?, hatcheryTeam: number, freeSlots: number): boolean
	return carrierTeam == hatcheryTeam and freeSlots > 0
end

-- Whether a player on `raiderTeam` may raid a hatchery of `hatcheryTeam`.
function Eggs.canRaid(
	raiderTeam: number?,
	hatcheryTeam: number,
	outerGuardianDead: boolean,
	incubating: number,
	alreadyCarrying: boolean,
	config: Config.EggConfig
): boolean
	if raiderTeam == nil or raiderTeam == hatcheryTeam or incubating <= 0 or alreadyCarrying then
		return false
	end
	return outerGuardianDead or not config.raidRequiresOuterGuardian
end

-- Which incubating egg a raid takes: the one closest to hatching (the biggest loss for the
-- defenders). `endsAt` lists each candidate's hatch time; returns its index.
function Eggs.raidPick(endsAt: { number }): number?
	local best, bestAt = nil, math.huge
	for i, at in endsAt do
		if at < bestAt then
			best, bestAt = i, at
		end
	end
	return best
end

-- Whether a carrier could have moved `distance` studs in `seconds` at `walkSpeed` slowed by the
-- carry scale, with `tolerance` studs of slack for lag and knockback.
function Eggs.validCarrierMove(distance: number, seconds: number, walkSpeed: number, config: Config.EggConfig): boolean
	return distance <= walkSpeed * config.carrySpeedScale * seconds * 1.25 + config.moveTolerance
end

function Eggs.isChoice(value: string): boolean
	return value == "claim" or value == "feed" or value == "unleash"
end

return Eggs
