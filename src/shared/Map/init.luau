--!strict
-- The resolved map: `Map.build(layout)` applies scale and mirroring to a MapLayout and returns
-- every lane, wall, base and marker for both teams. The server builds the greybox from this; later
-- phases place guardians, hatcheries, camps and minion spawns from the same markers.
--
-- Pure Luau (no engine access), so it is unit tested under Lune.

local LanePath = require("@self/LanePath")
local MapLayout = require("./Config/MapLayout")

export type Point = LanePath.Point
export type Path = LanePath.Path
export type Rect = MapLayout.Rect
export type LaneId = MapLayout.LaneId
export type Team = number -- 1 (west) or 2 (east)

export type MarkerKind = "innerGuardian" | "outerGuardian" | "hatchery" | "titan" | "camp" | "minionSpawn"

export type Marker = {
	kind: MarkerKind,
	-- Owning team, or nil for neutral markers (jungle camps).
	team: Team?,
	lane: LaneId?,
	position: Point,
}

export type Wall = Rect & { height: number, boundary: boolean }

-- Iterate lanes through records: iterating an array of string literals widens them to string in
-- strict mode, while record fields keep their literal type.
export type Lane = { id: LaneId, path: Path }

export type MapData = {
	scale: number,
	-- Playable area: x in [-halfWidth, halfWidth], z in [-halfDepth, halfDepth].
	halfWidth: number,
	halfDepth: number,
	laneWidth: number,
	-- Each lane runs from team 1's base gate to team 2's base gate. `lanes` is in order (top,
	-- middle, bottom) for iteration; `laneById` is for lookups.
	lanes: { Lane },
	laneById: { [LaneId]: Path },
	bases: { [Team]: Rect },
	-- Jungle obstacles plus the four boundary walls.
	walls: { Wall },
	markers: { Marker },
	walkSpeed: number,
}

local LANE_ORDER: { { id: LaneId } } = { { id = "top" }, { id = "middle" }, { id = "bottom" } }

local Map = {}

local function mirrorX(p: Point): Point
	return { x = -p.x, z = p.z }
end

local function mirrorZ(p: Point): Point
	return { x = p.x, z = -p.z }
end

local function scaled(p: Point, s: number): Point
	return { x = p.x * s, z = p.z * s }
end

local function scaledRect(r: Rect, s: number): Rect
	return { center = scaled(r.center, s), size = scaled(r.size, s) }
end

-- Team 1's half plus its mirror, joined at the centre line.
local function fullLane(half: { Point }, s: number, id: string): Path
	local last = half[#half]
	assert(math.abs(last.x) < 1e-9, `lane {id} must end on the centre line (x = 0)`)
	local points: { Point } = {}
	for _, p in half do
		table.insert(points, scaled(p, s))
	end
	for i = #half - 1, 1, -1 do
		table.insert(points, scaled(mirrorX(half[i]), s))
	end
	return LanePath.new(points)
end

function Map.build(layout: MapLayout.MapLayout): MapData
	local s = layout.scale
	assert(s > 0, "scale must be positive")
	assert(
		layout.innerGuardianProgress < layout.hatcheryProgress
			and layout.hatcheryProgress < layout.outerGuardianProgress
			and layout.outerGuardianProgress < 0.5,
		"lane progress must be inner guardian < hatchery < outer guardian < 0.5"
	)

	local lanes: { Lane } = {}
	local laneById: { [LaneId]: Path } = {}
	for _, entry in LANE_ORDER do
		local path = fullLane(layout.lanes[entry.id], s, entry.id)
		table.insert(lanes, { id = entry.id, path = path })
		laneById[entry.id] = path
	end

	local base1 = scaledRect(layout.base, s)
	local bases: { [Team]: Rect } = {
		[1] = base1,
		[2] = { center = mirrorX(base1.center), size = base1.size },
	}

	local markers: { Marker } = {}
	local function add(kind: MarkerKind, team: Team?, lane: LaneId?, position: Point)
		table.insert(markers, { kind = kind, team = team, lane = lane, position = position })
	end

	for team: Team = 1, 2 do
		add("titan", team, nil, bases[team].center)
	end

	-- Lane structures are placed for team 1 and mirrored for team 2.
	for _, lane in lanes do
		-- Read lane.id at each use; a local copy captured by the closure widens to string.
		local path = lane.path
		local function place(kind: MarkerKind, progress: number, lateral: number?)
			local p = LanePath.pointAtProgress(path, progress, lateral)
			add(kind, 1, lane.id, p)
			add(kind, 2, lane.id, mirrorX(p))
		end
		place("minionSpawn", layout.minionSpawnProgress)
		place("innerGuardian", layout.innerGuardianProgress)
		place("hatchery", layout.hatcheryProgress, layout.hatcheryLateral[lane.id] * s)
		place("outerGuardian", layout.outerGuardianProgress)
	end

	-- Jungle content goes into all four quadrants.
	local walls: { Wall } = {}
	local quadrants = {
		function(p: Point): Point
			return p
		end,
		mirrorX,
		mirrorZ,
		function(p: Point): Point
			return mirrorX(mirrorZ(p))
		end,
	}
	for _, transform in quadrants do
		for _, wall in layout.jungleWalls do
			local r = scaledRect(wall, s)
			table.insert(
				walls,
				{ center = transform(r.center), size = r.size, height = layout.wallHeight, boundary = false }
			)
		end
		for _, camp in layout.jungleCamps do
			add("camp", nil, nil, transform(scaled(camp, s)))
		end
	end

	-- Boundary walls just outside the playable area, overlapping at the corners.
	local hw = layout.halfWidth * s
	local hd = layout.halfDepth * s
	local t = layout.boundaryThickness
	local h = layout.boundaryHeight
	table.insert(
		walls,
		{ center = { x = 0, z = -hd - t / 2 }, size = { x = 2 * hw + 2 * t, z = t }, height = h, boundary = true }
	)
	table.insert(
		walls,
		{ center = { x = 0, z = hd + t / 2 }, size = { x = 2 * hw + 2 * t, z = t }, height = h, boundary = true }
	)
	table.insert(
		walls,
		{ center = { x = -hw - t / 2, z = 0 }, size = { x = t, z = 2 * hd }, height = h, boundary = true }
	)
	table.insert(
		walls,
		{ center = { x = hw + t / 2, z = 0 }, size = { x = t, z = 2 * hd }, height = h, boundary = true }
	)

	return {
		scale = s,
		halfWidth = hw,
		halfDepth = hd,
		laneWidth = layout.laneWidth * s,
		lanes = lanes,
		laneById = laneById,
		bases = bases,
		walls = walls,
		markers = markers,
		walkSpeed = layout.walkSpeed,
	}
end

-- Markers of one kind (optionally for one team).
function Map.markersOf(map: MapData, kind: MarkerKind, team: Team?): { Marker }
	local out: { Marker } = {}
	for _, marker in map.markers do
		if marker.kind == kind and (team == nil or marker.team == team) then
			table.insert(out, marker)
		end
	end
	return out
end

local current: MapData? = nil

-- The map built from the shared MapLayout. Built once, then cached.
function Map.get(): MapData
	if current == nil then
		current = Map.build(MapLayout)
	end
	return current :: MapData
end

return Map
