--!strict
-- Pure minion rules shared by MinionService and its tests: wave makeup, formation, direction
-- of travel and target priority.

local Minions = {}

-- Kind codes carried in snapshots (MinionCodec) and their names.
Minions.KIND_INDEX = table.freeze({ melee = 1, ranged = 2, siege = 3 } :: { [string]: number })
Minions.KIND_NAMES = table.freeze({ "melee", "ranged", "siege" })

-- Minion combatant IDs are -(ID_BASE + network ID), clear of NPC rows (-1 to -65535) and
-- players (positive UserIds).
Minions.ID_BASE = 100000

function Minions.combatantId(networkId: number): number
	return -(Minions.ID_BASE + networkId)
end

-- The network ID for a minion combatant ID, or nil if the ID is not a minion's.
function Minions.networkId(combatantId: number): number?
	local n = -combatantId - Minions.ID_BASE
	return if n >= 1 and n <= 65535 then n else nil
end

export type Composition = { { kind: string, count: number } }

-- The kinds in one wave, front to back. `scale` multiplies every count (load testing); each
-- kind present in the composition keeps at least one minion.
function Minions.wavePlan(composition: Composition, scale: number): { string }
	local plan: { string } = {}
	for _, entry in composition do
		local count = math.max(1, math.floor(entry.count * scale + 0.5))
		for _ = 1, count do
			table.insert(plan, entry.kind)
		end
	end
	return plan
end

-- Side-to-side offset for the i-th of n minions, spread evenly across `width` and centred.
function Minions.lateralFor(i: number, n: number, width: number): number
	if n <= 1 then
		return 0
	end
	return (i - 1) / (n - 1) * width - width / 2
end

-- +1 when the team walks from distance 0 towards the far end of the lane (team 1), -1 for team 2.
function Minions.direction(team: number): number
	return if team == 1 then 1 else -1
end

-- Starting distance along a lane of `length` for a team, `spawnProgress` in from its own end.
function Minions.startDistance(length: number, team: number, spawnProgress: number): number
	return if team == 1 then length * spawnProgress else length * (1 - spawnProgress)
end

-- Whether a minion at `distance` has reached the far end of its lane.
function Minions.reachedEnd(distance: number, length: number, team: number): boolean
	return if team == 1 then distance >= length else distance <= 0
end

export type Candidate = { id: number, distance: number, isMinion: boolean }

-- Target priority: the nearest enemy minion if any, otherwise the nearest other hostile
-- (players and bots; guardians from Phase 6). Ties go to the lower ID.
function Minions.chooseTarget(candidates: { Candidate }): number?
	local best: Candidate? = nil
	for _, c in candidates do
		if best == nil then
			best = c
		else
			local b = best :: Candidate
			if c.isMinion ~= b.isMinion then
				if c.isMinion then
					best = c
				end
			elseif c.distance < b.distance or (c.distance == b.distance and c.id < b.id) then
				best = c
			end
		end
	end
	return if best then best.id else nil
end

return Minions
