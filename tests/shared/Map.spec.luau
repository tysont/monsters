--!strict
-- Contract tests for Shared.Map built from the real MapLayout. These encode the Phase 1
-- acceptance tests that can be checked from data: lane walking time, marker counts and placement,
-- identical geometry for both teams, connectivity, and rescaling from one number.

local LanePath = require("../../src/shared/Map/LanePath")
local Map = require("../../src/shared/Map")
local MapLayout = require("../../src/shared/Config/MapLayout")
local TestKit = require("../TestKit")

type Point = Map.Point

-- Roblox's default jump reaches about 7.2 studs.
local JUMP_HEIGHT = 7.2
-- Half the width of a character, used to inflate walls when checking walkable space.
local CHARACTER_RADIUS = 2
local GRID = 4

local function withScale(scale: number): MapLayout.MapLayout
	local layout = table.clone(MapLayout)
	layout.scale = scale
	return layout
end

local function insideRect(p: Point, center: Point, size: Point, inflate: number): boolean
	return math.abs(p.x - center.x) <= size.x / 2 + inflate and math.abs(p.z - center.z) <= size.z / 2 + inflate
end

-- Grid of walkable cells: inside the playable area and not inside any wall.
local function walkableGrid(map: Map.MapData): ((p: Point) -> (number, number), { { boolean } }, number, number)
	local cols = math.floor(2 * map.halfWidth / GRID)
	local rows = math.floor(2 * map.halfDepth / GRID)
	local function cellOf(p: Point): (number, number)
		local c = math.clamp(math.floor((p.x + map.halfWidth) / GRID) + 1, 1, cols)
		local r = math.clamp(math.floor((p.z + map.halfDepth) / GRID) + 1, 1, rows)
		return c, r
	end
	local grid: { { boolean } } = {}
	for c = 1, cols do
		local column = {}
		local x = -map.halfWidth + (c - 0.5) * GRID
		for r = 1, rows do
			local p = { x = x, z = -map.halfDepth + (r - 0.5) * GRID }
			local free = true
			for _, wall in map.walls do
				if insideRect(p, wall.center, wall.size, CHARACTER_RADIUS) then
					free = false
					break
				end
			end
			column[r] = free
		end
		grid[c] = column
	end
	return cellOf, grid, cols, rows
end

-- Flood fill from `start`; returns a set of reached cells keyed by c * 100000 + r.
local function reachable(grid: { { boolean } }, cols: number, rows: number, sc: number, sr: number): { [number]: true }
	local seen: { [number]: true } = {}
	local stack = { { sc, sr } }
	while #stack > 0 do
		local cell = table.remove(stack) :: { number }
		local c, r = cell[1], cell[2]
		local key = c * 100000 + r
		if c >= 1 and c <= cols and r >= 1 and r <= rows and not seen[key] and grid[c][r] then
			seen[key] = true
			table.insert(stack, { c + 1, r })
			table.insert(stack, { c - 1, r })
			table.insert(stack, { c, r + 1 })
			table.insert(stack, { c, r - 1 })
		end
	end
	return seen
end

return function(t: TestKit.Context)
	local expect = t.expect
	local map = Map.build(MapLayout)

	-- Acceptance: walking a full lane takes 60 to 90 seconds at default walk speed.
	t.test("every lane takes 60 to 90 seconds to walk", function()
		for _, lane in map.lanes do
			local seconds = lane.path.length / map.walkSpeed
			if seconds < 60 or seconds > 90 then
				error(`{lane.id} lane takes {seconds} s`)
			end
		end
	end)

	-- Structure counts from the design: 12 guardians, 2 Titans, 6 hatcheries, 12 camps.
	t.test("has the designed number of each marker", function()
		local outer = #Map.markersOf(map, "outerGuardian")
		local inner = #Map.markersOf(map, "innerGuardian")
		expect.equal(outer + inner, 12)
		expect.equal(#Map.markersOf(map, "titan"), 2)
		expect.equal(#Map.markersOf(map, "hatchery"), 6)
		expect.equal(#Map.markersOf(map, "camp"), 12)
		expect.equal(#Map.markersOf(map, "minionSpawn"), 6)
	end)

	-- Acceptance: every hatchery sits between its lane's outer and inner guardian.
	t.test("every hatchery is between its lane's inner and outer guardian", function()
		for _, hatchery in Map.markersOf(map, "hatchery") do
			local path = map.laneById[hatchery.lane :: Map.LaneId]
			local function progress(p: Point): number
				local value = LanePath.progressOf(path, p)
				-- Measure from the owning team's base.
				return if hatchery.team == 2 then 1 - value else value
			end
			local inner, outer
			for _, m in Map.markersOf(map, "innerGuardian", hatchery.team) do
				if m.lane == hatchery.lane then
					inner = progress(m.position)
				end
			end
			for _, m in Map.markersOf(map, "outerGuardian", hatchery.team) do
				if m.lane == hatchery.lane then
					outer = progress(m.position)
				end
			end
			local h = progress(hatchery.position)
			if not (inner < h and h < outer) then
				error(`team {hatchery.team} {hatchery.lane} hatchery at {h} is not between {inner} and {outer}`)
			end
		end
	end)

	-- Both teams get identical geometry: every team 2 marker mirrors a team 1 marker.
	t.test("team 2 mirrors team 1", function()
		for _, m in map.markers do
			if m.team == 1 then
				local found = false
				for _, other in map.markers do
					if
						other.team == 2
						and other.kind == m.kind
						and other.lane == m.lane
						and math.abs(other.position.x + m.position.x) < 1e-6
						and math.abs(other.position.z - m.position.z) < 1e-6
					then
						found = true
					end
				end
				if not found then
					error(`no mirror for team 1 {m.kind} on {m.lane}`)
				end
			end
		end
		expect.near(map.bases[1].center.x, -map.bases[2].center.x)
	end)

	-- Lanes run symmetrically: progress p from team 1 equals progress 1 - p from team 2.
	t.test("lanes are symmetric about the centre line", function()
		for _, lane in map.lanes do
			local path = lane.path
			local a = LanePath.pointAtProgress(path, 0.3)
			local b = LanePath.pointAtProgress(path, 0.7)
			expect.near(a.x, -b.x, 1e-6)
			expect.near(a.z, b.z, 1e-6)
		end
	end)

	-- Acceptance: nothing can be climbed out of bounds; walls are too tall to jump onto.
	t.test("walls cannot be jumped onto", function()
		for _, wall in map.walls do
			expect.truthy(wall.height > JUMP_HEIGHT * 1.5)
		end
	end)

	-- Everything players need to reach is inside the playable area.
	t.test("markers and lanes are inside the playable area", function()
		local function inside(p: Point): boolean
			return math.abs(p.x) <= map.halfWidth and math.abs(p.z) <= map.halfDepth
		end
		for _, m in map.markers do
			expect.truthy(inside(m.position))
		end
		for _, lane in map.lanes do
			for _, p in lane.path.points do
				expect.truthy(inside(p))
			end
		end
	end)

	-- Jungle walls never block a lane or sit on a structure.
	t.test("walls stay clear of lanes and markers", function()
		local clearance = map.laneWidth / 2 + CHARACTER_RADIUS
		for i, wall in map.walls do
			for _, m in map.markers do
				if insideRect(m.position, wall.center, wall.size, 12) then
					error(`wall {i} overlaps a {m.kind}`)
				end
			end
			for _, lane in map.lanes do
				local path = lane.path
				local d = 0
				while d <= path.length do
					if insideRect(LanePath.pointAt(path, d), wall.center, wall.size, clearance) then
						error(`wall {i} blocks the {lane.id} lane at {d}`)
					end
					d += GRID
				end
			end
		end
	end)

	-- Acceptance: jungle paths connect all three lanes; every lane, structure and camp is reachable
	-- from team 1's base on foot.
	t.test("everything is reachable from a base", function()
		local cellOf, grid, cols, rows = walkableGrid(map)
		local sc, sr = cellOf(map.bases[1].center)
		local seen = reachable(grid, cols, rows, sc, sr)
		local function check(p: Point, what: string)
			local c, r = cellOf(p)
			if not seen[c * 100000 + r] then
				error(`{what} at ({p.x}, {p.z}) is not reachable`)
			end
		end
		for _, m in map.markers do
			check(m.position, m.kind)
		end
		for _, lane in map.lanes do
			local path = lane.path
			for d = 0, path.length, 25 do
				check(LanePath.pointAt(path, d), `{lane.id} lane`)
			end
		end
		check(map.bases[2].center, "team 2 base")
	end)

	-- Acceptance: changing one number (scale) rescales the map.
	t.test("scale rescales lanes, markers and walls", function()
		local big = Map.build(withScale(1.5))
		for i, lane in map.lanes do
			expect.near(big.lanes[i].path.length, lane.path.length * 1.5, 1e-6)
		end
		for i, m in map.markers do
			expect.near(big.markers[i].position.x, m.position.x * 1.5, 1e-6)
			expect.near(big.markers[i].position.z, m.position.z * 1.5, 1e-6)
		end
		expect.near(big.halfWidth, map.halfWidth * 1.5)
		expect.near(big.walls[1].size.x, map.walls[1].size.x * 1.5)
	end)

	-- Invalid layouts are rejected rather than producing a broken map.
	t.test("rejects hatcheries outside the guardian band", function()
		local layout = table.clone(MapLayout)
		layout.hatcheryProgress = 0.5
		expect.throws(function()
			Map.build(layout)
		end, "inner guardian < hatchery")
	end)
end
