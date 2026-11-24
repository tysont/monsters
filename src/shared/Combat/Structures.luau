--!strict
-- Lane structures (guardians and Titans): where they stand, which can be damaged, and who a
-- guardian attacks. Pure, unit tested under Lune.
--
--   Lane gating: an inner guardian cannot be damaged until the outer guardian in its lane is
--   dead; a Titan cannot be damaged until at least one of its team's inner guardians is dead.
--   Guardian targeting: a hostile who recently hurt one of the guardian's team's players nearby
--   (provoked) first, then the nearest enemy minion, then the nearest other hostile.

local Map = require("../Map")

export type Kind = "outerGuardian" | "innerGuardian" | "titan"

export type Structure = {
	kind: Kind,
	team: number,
	-- nil for Titans.
	lane: Map.LaneId?,
	position: Map.Point,
	-- Attribute-safe identifier, e.g. "T1_top_outerGuardian" or "T2_titan".
	key: string,
}

export type Candidate = {
	id: number,
	distance: number,
	isMinion: boolean,
	provoked: boolean,
}

-- Every structure kind, as records (iterating string literals widens them in strict mode).
local KINDS: { { kind: Kind } } = { { kind = "outerGuardian" }, { kind = "innerGuardian" }, { kind = "titan" } }

local Structures = {}

function Structures.key(kind: Kind, team: number, lane: Map.LaneId?): string
	if lane then
		return `T{team}_{lane}_{kind}`
	end
	return `T{team}_{kind}`
end

-- Every structure on the map, from its markers: per team, an outer and an inner guardian per lane
-- and one Titan.
function Structures.list(map: Map.MapData): { Structure }
	local out: { Structure } = {}
	for _, entry in KINDS do
		for _, marker in Map.markersOf(map, entry.kind) do
			local team = marker.team :: number
			local lane: Map.LaneId? = if entry.kind == "titan" then nil else marker.lane :: Map.LaneId?
			table.insert(out, {
				kind = entry.kind,
				team = team,
				lane = lane,
				position = marker.position,
				key = Structures.key(entry.kind, team, lane),
			})
		end
	end
	return out
end

-- Whether a structure can take damage, given which structure keys are dead.
function Structures.vulnerable(kind: Kind, team: number, lane: Map.LaneId?, dead: { [string]: boolean }): boolean
	if kind == "outerGuardian" then
		return true
	elseif kind == "innerGuardian" then
		return dead[Structures.key("outerGuardian", team, lane)] == true
	end
	for _, l in Map.get().lanes do
		if dead[Structures.key("innerGuardian", team, l.id)] then
			return true
		end
	end
	return false
end

-- The ID a guardian should attack, or nil for no candidates.
function Structures.chooseTarget(candidates: { Candidate }): number?
	local best: Candidate? = nil
	local function rank(c: Candidate): number
		return if c.provoked then 0 elseif c.isMinion then 1 else 2
	end
	for _, c in candidates do
		if best == nil then
			best = c
		else
			local current = best :: Candidate
			local a, b = rank(c), rank(current)
			if a < b or (a == b and c.distance < current.distance) then
				best = c
			end
		end
	end
	return if best then best.id else nil
end

return Structures
