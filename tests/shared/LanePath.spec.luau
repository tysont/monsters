--!strict
-- Contract tests for Shared.Map.LanePath: distance/progress <-> position along a polyline lane,
-- with lateral offsets positive to the left of travel.

local LanePath = require("../../src/shared/Map/LanePath")
local TestKit = require("../TestKit")

-- An L-shaped lane: 100 studs east, then 50 studs south (+z).
local function lPath(): LanePath.Path
	return LanePath.new({ { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 50 } })
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- Length is the sum of the segment lengths.
	t.test("length sums the segments", function()
		expect.near(lPath().length, 150)
	end)

	-- Points along the lane follow the segments in order.
	t.test("pointAt walks the segments", function()
		local path = lPath()
		local a = LanePath.pointAt(path, 50)
		expect.near(a.x, 50)
		expect.near(a.z, 0)
		local b = LanePath.pointAt(path, 125)
		expect.near(b.x, 100)
		expect.near(b.z, 25)
	end)

	-- Distances outside the lane clamp to its ends.
	t.test("pointAt clamps to the ends", function()
		local path = lPath()
		local before = LanePath.pointAt(path, -10)
		local after = LanePath.pointAt(path, 1000)
		expect.near(before.x, 0)
		expect.near(after.z, 50)
	end)

	-- Progress is distance as a fraction of the length.
	t.test("pointAtProgress matches pointAt", function()
		local path = lPath()
		local p = LanePath.pointAtProgress(path, 0.5)
		local q = LanePath.pointAt(path, 75)
		expect.near(p.x, q.x)
		expect.near(p.z, q.z)
	end)

	-- Travelling east, left is north (negative z) when viewed from above with +y up.
	t.test("positive lateral offset is left of travel", function()
		local p = LanePath.pointAt(lPath(), 50, 10)
		expect.near(p.x, 50)
		expect.near(p.z, -10)
	end)

	-- project is the inverse of pointAt for points beside the lane.
	t.test("project inverts pointAt with lateral offset", function()
		local path = lPath()
		for _, case in { { 20, 5 }, { 90, -7 }, { 130, 3 } } do
			local p = LanePath.pointAt(path, case[1], case[2])
			local along, lateral = LanePath.project(path, p)
			expect.near(along, case[1], 1e-6)
			expect.near(lateral, case[2], 1e-6)
		end
	end)

	-- progressOf returns 0..1 from team 1's end.
	t.test("progressOf returns fraction of length", function()
		local path = lPath()
		expect.near(LanePath.progressOf(path, { x = 0, z = 0 }), 0)
		expect.near(LanePath.progressOf(path, { x = 100, z = 50 }), 1)
		expect.near(LanePath.progressOf(path, { x = 75, z = 3 }), 0.5)
	end)

	-- The tangent points along the current segment.
	t.test("tangentAt follows the segment direction", function()
		local path = lPath()
		local east = LanePath.tangentAt(path, 10)
		local south = LanePath.tangentAt(path, 140)
		expect.near(east.x, 1)
		expect.near(south.z, 1)
	end)

	-- Degenerate lanes are rejected.
	t.test("rejects lanes with fewer than two distinct points", function()
		expect.throws(function()
			LanePath.new({ { x = 0, z = 0 } })
		end)
		expect.throws(function()
			LanePath.new({ { x = 0, z = 0 }, { x = 0, z = 0 } })
		end)
	end)
end
