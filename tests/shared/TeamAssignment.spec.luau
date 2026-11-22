--!strict
-- Contract tests for Shared.TeamAssignment: joiners go to the smaller team, friends stay together
-- only when balance allows, and reshuffles keep teams within one of each other.

local TeamAssignment = require("../../src/shared/TeamAssignment")
local TestKit = require("../TestKit")

-- Deterministic pseudo-random source (linear congruential), returning integers in [1, n].
local function seeded(seed: number): TeamAssignment.Random
	local state = seed
	return function(n: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state % n + 1
	end
end

local function first(_n: number): number
	return 1
end

local function counts(result: { [string]: number }): { number }
	local c = { 0, 0 }
	for _, team in result do
		c[team] += 1
	end
	return c
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- The smaller team always wins, whatever the friends or the behind hook say.
	t.test("joiner goes to the smaller team", function()
		expect.equal(TeamAssignment.chooseTeam({ 3, 2 }, { 9, 1 }, { 5, 0 }, 1, 0.25, first), 2)
		expect.equal(TeamAssignment.chooseTeam({ 2, 3 }, { 1, 9 }, { 0, 5 }, 2, 0.25, first), 1)
	end)

	-- On a tie, friends decide.
	t.test("tie goes to the team with more friends", function()
		expect.equal(TeamAssignment.chooseTeam({ 2, 2 }, { 2, 2 }, { 0, 1 }, 1, 0.25, first), 2)
		expect.equal(TeamAssignment.chooseTeam({ 2, 2 }, { 2, 2 }, { 2, 1 }, 2, 0.25, first), 1)
	end)

	-- With no friend preference, the behind hook decides; without it, the random source does.
	t.test("tie without friends uses behind, then random", function()
		expect.equal(TeamAssignment.chooseTeam({ 1, 1 }, { 1, 1 }, { 0, 0 }, 2, 0.25, first), 2)
		expect.equal(TeamAssignment.chooseTeam({ 1, 1 }, { 1, 1 }, { 1, 1 }, nil, 0.25, first), 1)
		expect.equal(
			TeamAssignment.chooseTeam({ 1, 1 }, { 1, 1 }, { 0, 0 }, nil, 0.25, function(n)
				return n
			end),
			2
		)
	end)

	-- Acceptance: any join order never produces teams differing by more than one.
	t.test("random join orders stay balanced", function()
		local random = seeded(7)
		for _ = 1, 200 do
			local c = { 0, 0 }
			for _ = 1, 10 do
				local friends = { random(3) - 1, random(3) - 1 }
				local behind = if random(3) == 1 then nil else random(2)
				local strength = { c[1] * (1 + random(5) / 10), c[2] * (1 + random(5) / 10) }
				local team = TeamAssignment.chooseTeam(c, strength, friends, behind, 0.25, random)
				c[team] += 1
				expect.truthy(math.abs(c[1] - c[2]) <= 1)
			end
		end
	end)

	-- Friend groups are connected components; friendship in one direction is enough.
	t.test("friendGroups joins friends of friends", function()
		local groups = TeamAssignment.friendGroups({ "a", "b", "c", "d" }, { a = { "b" }, c = { "b" } })
		expect.equal(#groups, 2)
		expect.deepEqual(groups[2], { "d" })
		expect.equal(#groups[1], 3)
	end)

	-- Friends who are not in the server are ignored.
	t.test("friendGroups ignores absent members", function()
		local groups = TeamAssignment.friendGroups({ "a", "b" }, { a = { "zzz" } })
		expect.equal(#groups, 2)
	end)

	-- Every member gets a team and the teams differ by at most one.
	t.test("reshuffle balances teams", function()
		local random = seeded(42)
		for size = 0, 41 do
			local groups = {}
			for i = 1, size do
				table.insert(groups, { `m{i}` })
			end
			local result = TeamAssignment.reshuffle(groups, {}, random)
			local c = counts(result)
			expect.equal(c[1] + c[2], size)
			expect.truthy(math.abs(c[1] - c[2]) <= 1)
		end
	end)

	-- Small friend groups stay on one team.
	t.test("reshuffle keeps small friend groups together", function()
		local groups = { { "a", "b" }, { "c", "d" }, { "e" }, { "f" } }
		local result = TeamAssignment.reshuffle(groups, {}, seeded(3))
		expect.equal(result.a, result.b)
		expect.equal(result.c, result.d)
	end)

	-- A group too large to fit is split rather than unbalancing the teams.
	t.test("reshuffle splits a group larger than a team", function()
		local result = TeamAssignment.reshuffle({ { "a", "b", "c", "d", "e" }, { "f" } }, {}, seeded(1))
		local c = counts(result)
		expect.equal(c[1], 3)
		expect.equal(c[2], 3)
	end)

	-- Reshuffling actually changes teams between rounds (not always the same split).
	t.test("reshuffle varies with the random source", function()
		local groups = {}
		for i = 1, 20 do
			table.insert(groups, { `m{i}` })
		end
		local a = TeamAssignment.reshuffle(groups, {}, seeded(1))
		local b = TeamAssignment.reshuffle(groups, {}, seeded(2))
		local same = true
		for id, team in a do
			if b[id] ~= team then
				same = false
			end
		end
		expect.falsy(same)
	end)

	-- Strength is the sum of member power; missing members count as a new player (1.0).
	t.test("balance sums strength and finds the weaker team", function()
		local b = TeamAssignment.balance({ a = 1, b = 1, c = 2, d = 2 }, { a = 1.5, b = 1.4, c = 1.0 })
		expect.deepEqual(b.counts, { 2, 2 })
		expect.near(b.strength[1], 2.9)
		expect.near(b.strength[2], 2.0)
		expect.near(b.strengthGap, 0.9)
		expect.equal(b.weaker, 2)
		expect.near(b.strengthShare, 2.9 / 4.9)
	end)

	-- Empty or perfectly even teams have no weaker side.
	t.test("balance of even teams has no weaker team", function()
		local empty = TeamAssignment.balance({}, {})
		expect.equal(empty.weaker, nil)
		expect.near(empty.strengthShare, 0.5)
		local even = TeamAssignment.balance({ a = 1, b = 2 }, {})
		expect.equal(even.weaker, nil)
	end)

	-- With equal headcount, a clear strength gap sends the joiner to the weaker team, even away
	-- from friends.
	t.test("tie with a strength gap goes to the weaker team", function()
		expect.equal(TeamAssignment.chooseTeam({ 3, 3 }, { 4.2, 3.0 }, { 2, 0 }, 1, 0.25, first), 2)
		expect.equal(TeamAssignment.chooseTeam({ 3, 3 }, { 3.0, 4.2 }, { 0, 2 }, 2, 0.25, first), 1)
	end)

	-- A gap within the tolerance does not override friends.
	t.test("small strength gaps leave the choice to friends", function()
		expect.equal(TeamAssignment.chooseTeam({ 3, 3 }, { 3.2, 3.0 }, { 1, 0 }, nil, 0.25, first), 1)
	end)

	-- Headcount stays the hard rule: a much stronger smaller team still gets the joiner.
	t.test("headcount beats strength", function()
		expect.equal(TeamAssignment.chooseTeam({ 2, 3 }, { 3.0, 3.0 }, { 0, 0 }, nil, 0.25, first), 1)
	end)

	-- Reshuffle evens out strength: four strong and four new players split two and two.
	t.test("reshuffle evens strength across teams", function()
		local groups = {}
		local powers: TeamAssignment.Powers = {}
		for i = 1, 8 do
			local id = `m{i}`
			table.insert(groups, { id })
			powers[id] = if i <= 4 then 1.5 else 1.0
		end
		for seed = 1, 20 do
			local result = TeamAssignment.reshuffle(groups, powers, seeded(seed))
			local b = TeamAssignment.balance(result, powers)
			expect.deepEqual(b.counts, { 4, 4 })
			expect.near(b.strengthGap, 0)
		end
	end)

	-- Uneven powers end with the smallest gap single-member swaps can reach.
	t.test("reshuffle minimises the strength gap with swaps", function()
		local groups = { { "a" }, { "b" }, { "c" }, { "d" }, { "e" }, { "f" } }
		local powers: TeamAssignment.Powers = { a = 1.5, b = 1.45, c = 1.3, d = 1.1, e = 1.05, f = 1.0 }
		local result = TeamAssignment.reshuffle(groups, powers, seeded(5))
		local b = TeamAssignment.balance(result, powers)
		expect.deepEqual(b.counts, { 3, 3 })
		-- Best possible split is {1.5, 1.05, 1.1} vs {1.45, 1.3, 1.0}: gap 0.1.
		expect.truthy(math.abs(b.strengthGap) <= 0.1 + 1e-9)
	end)

	-- Friend groups are never split to even strength.
	t.test("reshuffle keeps friend groups together while evening strength", function()
		local groups = { { "a", "b" }, { "c" }, { "d" } }
		local powers: TeamAssignment.Powers = { a = 1.5, b = 1.5, c = 1.0, d = 1.0 }
		local result = TeamAssignment.reshuffle(groups, powers, seeded(9))
		expect.equal(result.a, result.b)
		expect.equal(result.c, result.d)
	end)

	-- Imbalance is the difference in team sizes.
	t.test("imbalance is the size difference", function()
		expect.equal(TeamAssignment.imbalance({ 5, 3 }), 2)
		expect.equal(TeamAssignment.imbalance({ 4, 4 }), 0)
	end)
end
