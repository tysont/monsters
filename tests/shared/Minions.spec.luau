--!strict
-- Contract tests for the Phase 5 pure modules: SpatialGrid, MinionCodec and Minions rules.

local MinionCodec = require("../../src/shared/Combat/MinionCodec")
local Minions = require("../../src/shared/Combat/Minions")
local SpatialGrid = require("../../src/shared/Combat/SpatialGrid")
local TestKit = require("../TestKit")

local function sorted(list: { number }): { number }
	local copy = table.clone(list)
	table.sort(copy)
	return copy
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- SpatialGrid ---------------------------------------------------------------------------

	-- A query finds IDs in nearby cells and not far ones.
	t.test("grid query finds nearby IDs only", function()
		local g = SpatialGrid.new(16)
		SpatialGrid.update(g, 1, 0, 0)
		SpatialGrid.update(g, 2, 10, 5)
		SpatialGrid.update(g, 3, 500, 500)
		local found = sorted(SpatialGrid.collect(g, 0, 0, 20))
		expect.deepEqual(found, { 1, 2 })
		expect.equal(g.count, 3)
	end)

	-- Moving an ID across cells updates where it is found.
	t.test("grid update moves IDs between cells", function()
		local g = SpatialGrid.new(10)
		SpatialGrid.update(g, 7, 0, 0)
		SpatialGrid.update(g, 7, 200, 0)
		expect.deepEqual(SpatialGrid.collect(g, 0, 0, 5), {})
		expect.deepEqual(SpatialGrid.collect(g, 200, 0, 5), { 7 })
		expect.equal(g.count, 1)
	end)

	-- Removing keeps the other IDs in the same cell intact (swap-remove bookkeeping).
	t.test("grid remove keeps cell neighbours", function()
		local g = SpatialGrid.new(10)
		for id = 1, 5 do
			SpatialGrid.update(g, id, 1, 1)
		end
		SpatialGrid.remove(g, 2)
		SpatialGrid.remove(g, 5)
		expect.deepEqual(sorted(SpatialGrid.collect(g, 1, 1, 1)), { 1, 3, 4 })
		expect.falsy(SpatialGrid.has(g, 2))
		expect.equal(g.count, 3)
		-- Removing an unknown ID is harmless.
		SpatialGrid.remove(g, 99)
		expect.equal(g.count, 3)
	end)

	-- Negative coordinates and cell edges work.
	t.test("grid handles negative coordinates and edges", function()
		local g = SpatialGrid.new(16)
		SpatialGrid.update(g, 1, -0.01, -0.01)
		SpatialGrid.update(g, 2, 16, 16)
		expect.deepEqual(SpatialGrid.collect(g, -8, -8, 4), { 1 })
		expect.deepEqual(sorted(SpatialGrid.collect(g, 8, 8, 10)), { 1, 2 })
	end)

	-- A query over a large radius matches a brute-force scan.
	t.test("grid query matches brute force", function()
		local g = SpatialGrid.new(12)
		local positions = {}
		local seed = 3
		for id = 1, 200 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local x = seed % 400 - 200
			seed = (seed * 1103515245 + 12345) % 2147483648
			local z = seed % 400 - 200
			positions[id] = { x, z }
			SpatialGrid.update(g, id, x, z)
		end
		local inGrid: { [number]: boolean } = {}
		for _, id in SpatialGrid.collect(g, 10, -20, 50) do
			inGrid[id] = true
		end
		for id, p in positions do
			local dx, dz = p[1] - 10, p[2] + 20
			if math.sqrt(dx * dx + dz * dz) <= 50 and not inGrid[id] then
				error(`grid missed {id}`)
			end
		end
	end)

	-- MinionCodec ---------------------------------------------------------------------------

	-- Kind and team round trip with the other fields.
	t.test("minion codec round trips kind and team", function()
		local chunks = MinionCodec.pack(5, {
			{ id = 42, x = -600.5, z = 280.25, yaw = 1, health = 0.75, state = 1, kind = 2, team = 2 },
		}, 900)
		local time, out = MinionCodec.unpack(chunks[1])
		local e = (out :: { MinionCodec.Entity })[1]
		expect.near(time :: number, 5)
		expect.equal(e.id, 42)
		expect.equal(e.kind, 2)
		expect.equal(e.team, 2)
		expect.near(e.x, -600.5, 1 / 16)
		expect.near(e.health, 0.75, 1 / 255)
		expect.equal(e.state, 1)
	end)

	-- 300 minions split into chunks under 900 bytes.
	t.test("minion codec chunks stay under 900 bytes", function()
		local list = {}
		for i = 1, 300 do
			table.insert(list, { id = i, x = i, z = 0, yaw = 0, health = 1, state = 0, kind = 1, team = 1 })
		end
		local total = 0
		for _, b in MinionCodec.pack(0, list, 900) do
			expect.truthy(buffer.len(b) <= 900)
			local _, out = MinionCodec.unpack(b)
			total += #(out :: { MinionCodec.Entity })
		end
		expect.equal(total, 300)
	end)

	-- Quantize matches what unpack would read back, so change detection is exact.
	t.test("quantize detects visible changes only", function()
		local a = { id = 1, x = 10, z = 10, yaw = 0, health = 1, state = 0, kind = 1, team = 1 }
		local b = table.clone(a)
		b.x = 10.01 -- below 1/16 stud
		local ax = MinionCodec.quantize(a)
		local bx = MinionCodec.quantize(b)
		expect.equal(ax, bx)
		b.x = 10.1
		expect.truthy(MinionCodec.quantize(b) ~= ax)
	end)

	-- Minions rules -------------------------------------------------------------------------

	-- Waves follow the composition order and scale.
	t.test("wavePlan follows composition and scale", function()
		local composition = { { kind = "melee", count = 3 }, { kind = "ranged", count = 2 } }
		expect.deepEqual(Minions.wavePlan(composition, 1), { "melee", "melee", "melee", "ranged", "ranged" })
		expect.equal(#Minions.wavePlan(composition, 4), 20)
		-- A tiny scale keeps one of each kind.
		expect.deepEqual(Minions.wavePlan(composition, 0.01), { "melee", "ranged" })
	end)

	-- Formation offsets are centred and span the width.
	t.test("lateralFor spreads evenly and centres", function()
		expect.near(Minions.lateralFor(1, 1, 8), 0)
		expect.near(Minions.lateralFor(1, 3, 8), -4)
		expect.near(Minions.lateralFor(2, 3, 8), 0)
		expect.near(Minions.lateralFor(3, 3, 8), 4)
	end)

	-- Team 1 walks up the lane, team 2 down it; each starts near its own end.
	t.test("direction, start and end follow the team", function()
		expect.equal(Minions.direction(1), 1)
		expect.equal(Minions.direction(2), -1)
		expect.near(Minions.startDistance(1000, 1, 0.01), 10)
		expect.near(Minions.startDistance(1000, 2, 0.01), 990)
		expect.truthy(Minions.reachedEnd(1000, 1000, 1))
		expect.falsy(Minions.reachedEnd(999, 1000, 1))
		expect.truthy(Minions.reachedEnd(0, 1000, 2))
	end)

	-- Enemy minions are preferred over nearer players; otherwise nearest wins.
	t.test("chooseTarget prefers minions, then nearest", function()
		expect.equal(
			Minions.chooseTarget({
				{ id = 1, distance = 2, isMinion = false },
				{ id = 2, distance = 10, isMinion = true },
				{ id = 3, distance = 5, isMinion = true },
			}),
			3
		)
		expect.equal(
			Minions.chooseTarget({
				{ id = 1, distance = 8, isMinion = false },
				{ id = 2, distance = 3, isMinion = false },
			}),
			2
		)
		expect.equal(Minions.chooseTarget({}), nil)
	end)
end
