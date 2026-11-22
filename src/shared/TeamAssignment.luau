--!strict
-- Pure team-balancing rules, unit tested under Lune. TeamService applies them to real players
-- and bots. Teams are numbered 1 and 2; members are identified by string IDs (for example
-- "player:123" or "bot:4").
--
-- Balance has two parts:
--   headcount  a hard rule: teams never differ by more than one member;
--   strength   the sum of each member's power (a combat multiplier, 1.0 for a new player and
--              about 1.5 for a maxed one; see Appendix A). Assignment and reshuffles prefer the
--              weaker team, and `balance` reports the gap so later systems (Phase 11 underdog
--              bonus, wave scaling, comeback help) can soften it. Strength nudges teams towards
--              even; it is not meant to let a new player beat a maxed one.

export type Team = number

-- Picks a random integer in [1, n]. Injected so tests are deterministic.
export type Random = (n: number) -> number

-- Power by member ID. Missing members count as DEFAULT_POWER.
export type Powers = { [string]: number }

export type Balance = {
	counts: { number },
	-- Sum of member power per team.
	strength: { number },
	-- strength[1] - strength[2]; positive means team 1 is stronger.
	strengthGap: number,
	-- Team 1's share of total strength (0.5 when even; 0.5 when both teams are empty).
	strengthShare: number,
	-- The team with less strength, or nil when equal.
	weaker: Team?,
}

local TEAM_COUNT = 2

local TeamAssignment = {}

-- Power of a member with no level or pet bonuses.
TeamAssignment.DEFAULT_POWER = 1

local function powerOf(powers: Powers, id: string): number
	return powers[id] or TeamAssignment.DEFAULT_POWER
end

-- Headcount and strength of each team.
function TeamAssignment.balance(teamOf: { [string]: Team }, powers: Powers): Balance
	local counts = { 0, 0 }
	local strength = { 0, 0 }
	for id, team in teamOf do
		counts[team] += 1
		strength[team] += powerOf(powers, id)
	end
	local total = strength[1] + strength[2]
	local gap = strength[1] - strength[2]
	return {
		counts = counts,
		strength = strength,
		strengthGap = gap,
		strengthShare = if total > 0 then strength[1] / total else 0.5,
		weaker = if gap > 0 then 2 elseif gap < 0 then 1 else nil,
	}
end

-- The team a new member joins:
--   1. the smaller team (headcount never differs by more than one);
--   2. on a tie, the weaker team if the strength gap exceeds `tolerance`;
--   3. the team with more of the joiner's friends;
--   4. `behind` (the team that is losing the round; a hook until Phase 11);
--   5. otherwise random.
function TeamAssignment.chooseTeam(
	counts: { number },
	strength: { number },
	friendsOnTeam: { number },
	behind: Team?,
	tolerance: number,
	random: Random
): Team
	local smallest = math.min(counts[1], counts[2])
	local candidates: { Team } = {}
	for team = 1, TEAM_COUNT do
		if counts[team] == smallest then
			table.insert(candidates, team)
		end
	end
	if #candidates == 1 then
		return candidates[1]
	end

	local gap = strength[1] - strength[2]
	if math.abs(gap) > tolerance then
		return if gap > 0 then 2 else 1
	end

	local mostFriends = math.max(friendsOnTeam[1], friendsOnTeam[2])
	if mostFriends > 0 and friendsOnTeam[1] ~= friendsOnTeam[2] then
		return if friendsOnTeam[1] == mostFriends then 1 else 2
	end
	if behind ~= nil then
		return behind
	end
	return candidates[random(#candidates)]
end

-- Splits members into friend groups: connected components of the friendship graph.
-- `friends[id]` lists the IDs that member is friends with (either direction is enough).
-- Members appear in the order given; groups are returned in order of their first member.
function TeamAssignment.friendGroups(members: { string }, friends: { [string]: { string } }): { { string } }
	local present: { [string]: boolean } = {}
	for _, id in members do
		present[id] = true
	end
	-- Undirected adjacency restricted to present members.
	local adjacent: { [string]: { string } } = {}
	for _, id in members do
		adjacent[id] = adjacent[id] or {}
		local memberFriends: { string } = friends[id] or {}
		for _, other in memberFriends do
			if present[other] and other ~= id then
				table.insert(adjacent[id], other)
				adjacent[other] = adjacent[other] or {}
				table.insert(adjacent[other], id)
			end
		end
	end

	local seen: { [string]: boolean } = {}
	local groups: { { string } } = {}
	for _, id in members do
		if not seen[id] then
			local group: { string } = {}
			local stack = { id }
			seen[id] = true
			while #stack > 0 do
				local current = table.remove(stack) :: string
				table.insert(group, current)
				for _, other in adjacent[current] do
					if not seen[other] then
						seen[other] = true
						table.insert(stack, other)
					end
				end
			end
			table.insert(groups, group)
		end
	end
	return groups
end

local function shuffle<T>(list: { T }, random: Random)
	for i = #list, 2, -1 do
		local j = random(i)
		list[i], list[j] = list[j], list[i]
	end
end

-- Most swaps the strength pass will make, as a safety bound.
local MAX_SWAPS = 200

-- New teams for a round reset. Returns team by member ID.
--   - Headcount never differs by more than one.
--   - Friend groups stay together where headcount allows.
--   - Strength is evened out: groups go strongest-first onto the weaker team, then single
--     members are swapped across teams while a swap narrows the strength gap. Friend groups are
--     never split to even strength.
function TeamAssignment.reshuffle(groups: { { string } }, powers: Powers, random: Random): { [string]: Team }
	local order = table.clone(groups)
	shuffle(order, random)
	local entries = {}
	for i, group in order do
		local power = 0
		for _, id in group do
			power += powerOf(powers, id)
		end
		entries[i] = { group = group, power = power, index = i }
	end
	-- Larger groups first so they land before teams fill up, then stronger first; ties keep the
	-- shuffled order so equal reshuffles still vary.
	table.sort(entries, function(a, b)
		if #a.group ~= #b.group then
			return #a.group > #b.group
		end
		if a.power ~= b.power then
			return a.power > b.power
		end
		return a.index < b.index
	end)

	local result: { [string]: Team } = {}
	local members: { { string } } = { {}, {} }
	local strength = { 0, 0 }
	for _, entry in entries do
		local team
		if #members[1] ~= #members[2] then
			team = if #members[1] < #members[2] then 1 else 2
		else
			team = if strength[1] <= strength[2] then 1 else 2
		end
		for _, id in entry.group do
			result[id] = team
			table.insert(members[team], id)
		end
		strength[team] += entry.power
	end

	-- A large group can leave headcount unbalanced; move members (the most recently placed, which
	-- belong to the smallest groups) until the teams differ by at most one.
	while math.abs(#members[1] - #members[2]) > 1 do
		local from = if #members[1] > #members[2] then 1 else 2
		local to = 3 - from
		local id = table.remove(members[from]) :: string
		table.insert(members[to], id)
		result[id] = to
		strength[from] -= powerOf(powers, id)
		strength[to] += powerOf(powers, id)
	end

	-- Strength pass: swap one single member from each team (friend groups are not split) while
	-- the best swap narrows the gap. Swaps keep headcount unchanged.
	local single: { [string]: boolean } = {}
	for _, group in groups do
		if #group == 1 then
			single[group[1]] = true
		end
	end
	for _ = 1, MAX_SWAPS do
		local gap = strength[1] - strength[2]
		local bestA, bestB, bestGap = nil, nil, math.abs(gap)
		for _, a in members[1] do
			if single[a] then
				local pa = powerOf(powers, a)
				for _, b in members[2] do
					if single[b] then
						local newGap = math.abs(gap - 2 * (pa - powerOf(powers, b)))
						if newGap < bestGap - 1e-9 then
							bestA, bestB, bestGap = a, b, newGap
						end
					end
				end
			end
		end
		if bestA == nil or bestB == nil then
			break
		end
		local a, b = bestA :: string, bestB :: string
		local ia = table.find(members[1], a) :: number
		local ib = table.find(members[2], b) :: number
		members[1][ia], members[2][ib] = b, a
		result[a], result[b] = 2, 1
		local delta = powerOf(powers, a) - powerOf(powers, b)
		strength[1] -= delta
		strength[2] += delta
	end
	return result
end

-- How many more members the larger team has (0 when balanced).
function TeamAssignment.imbalance(counts: { number }): number
	return math.abs(counts[1] - counts[2])
end

return TeamAssignment
