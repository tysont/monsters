--!strict
-- Contract tests for launch pads (Shared.Launchers).

local Config = require("../../src/shared/Config")
local Launchers = require("../../src/shared/Launchers")
local Map = require("../../src/shared/Map")
local Structures = require("../../src/shared/Combat/Structures")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local config = Config.resolve("dev").launchers
	local map = Map.get()

	local function inside(p: Map.Point, r: Map.Rect): boolean
		return math.abs(p.x - r.center.x) <= r.size.x / 2 and math.abs(p.z - r.center.z) <= r.size.z / 2
	end

	local function guardian(kind: Structures.Kind, team: number, lane: Map.LaneId): Map.Point
		for _, s in Structures.list(map) do
			if s.kind == kind and s.team == team and s.lane == lane then
				return s.position
			end
		end
		error("no such guardian")
	end

	t.test("each base has one pad per lane, inside the base and mirrored", function()
		local pads = Launchers.pads(map, config)
		expect.equal(#pads, 6)
		local byKey: { [string]: Launchers.Pad } = {}
		for _, pad in pads do
			byKey[pad.key] = pad
			expect.truthy(inside(pad.position, map.bases[pad.team]))
		end
		for _, lane in map.lanes do
			local a = byKey[Launchers.key(1, lane.id)]
			local b = byKey[Launchers.key(2, lane.id)]
			expect.near(a.position.x, -b.position.x, 1e-6)
			expect.near(a.position.z, b.position.z, 1e-6)
		end
	end)

	t.test("pads fly to the furthest standing guardian in their lane", function()
		local dead: { [string]: boolean } = {}
		expect.equal(Launchers.destination(1, "top", dead), "outerGuardian")
		dead[Structures.key("outerGuardian", 1, "top")] = true
		expect.equal(Launchers.destination(1, "top", dead), "innerGuardian")
		-- Other lanes and the other team are unaffected.
		expect.equal(Launchers.destination(1, "middle", dead), "outerGuardian")
		expect.equal(Launchers.destination(2, "top", dead), "outerGuardian")
		dead[Structures.key("innerGuardian", 1, "top")] = true
		expect.equal(Launchers.destination(1, "top", dead), nil)
	end)

	t.test("landing is on the lane, short of the guardian on the team's own side", function()
		for team = 1, 2 do
			for _, lane in map.lanes do
				for _, kind: Structures.Kind in { "outerGuardian", "innerGuardian" } :: { Structures.Kind } do
					local g = guardian(kind, team, lane.id)
					local land = Launchers.landing(map, team, lane.id, g, config)
					local dx, dz = land.x - g.x, land.z - g.z
					expect.near(math.sqrt(dx * dx + dz * dz), config.landingOffset, 0.5)
					-- Nearer the team's own base than the guardian is.
					local base = map.bases[team].center
					expect.truthy(math.abs(land.x - base.x) < math.abs(g.x - base.x))
				end
			end
		end
	end)

	t.test("flights are a few seconds and arc above the lane", function()
		for _, pad in Launchers.pads(map, config) do
			local g = guardian("outerGuardian", pad.team, pad.lane)
			local dx, dz = g.x - pad.position.x, g.z - pad.position.z
			local distance = math.sqrt(dx * dx + dz * dz)
			local seconds = Launchers.flightSeconds(distance, config)
			expect.truthy(seconds >= config.minSeconds and seconds <= config.maxSeconds)
			-- Much faster than walking there.
			expect.truthy(seconds < distance / map.walkSpeed / 4)
		end
		local apex = Launchers.apex(400, config)
		expect.near(Launchers.height(0, 3, 5, apex), 3, 1e-9)
		expect.near(Launchers.height(1, 3, 5, apex), 5, 1e-9)
		expect.near(Launchers.height(0.5, 3, 5, apex), 4 + apex, 1e-9)
		-- Rising at the start, falling at the end, level at the peak (for equal ends).
		expect.truthy(Launchers.climb(0, 0, 0, apex) > 0)
		expect.truthy(Launchers.climb(1, 0, 0, apex) < 0)
		expect.near(Launchers.climb(0.5, 0, 0, apex), 0, 1e-9)
	end)
end
