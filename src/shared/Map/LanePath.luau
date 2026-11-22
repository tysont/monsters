--!strict
-- Lane geometry on the ground plane. A lane is a polyline (ordered control points joined by
-- straight segments) from team 1's base to team 2's base. Positions along it are given as a
-- distance in studs from the start, or as progress from 0 (team 1 end) to 1 (team 2 end), plus an
-- optional lateral offset (positive = left of the direction of travel from team 1 to team 2).
--
-- Pure Luau with plain {x, z} points, so it runs under Lune for tests and headless simulation.

export type Point = { x: number, z: number }

export type Path = {
	points: { Point },
	-- cumulative[i] is the distance from the start to points[i].
	cumulative: { number },
	length: number,
}

local LanePath = {}

local function sub(a: Point, b: Point): Point
	return { x = a.x - b.x, z = a.z - b.z }
end

local function len(v: Point): number
	return math.sqrt(v.x * v.x + v.z * v.z)
end

function LanePath.new(points: { Point }): Path
	assert(#points >= 2, "a lane needs at least two points")
	local cumulative = { 0 }
	for i = 2, #points do
		local segment = len(sub(points[i], points[i - 1]))
		assert(segment > 0, `lane points {i - 1} and {i} are identical`)
		cumulative[i] = cumulative[i - 1] + segment
	end
	return table.freeze({
		points = table.freeze(table.clone(points)),
		cumulative = table.freeze(cumulative),
		length = cumulative[#points],
	})
end

-- Index of the segment (1..#points-1) containing `distance`, which must already be clamped.
local function segmentAt(path: Path, distance: number): number
	local cumulative = path.cumulative
	for i = 2, #cumulative do
		if distance <= cumulative[i] then
			return i - 1
		end
	end
	return #cumulative - 1
end

-- Unit direction of travel (team 1 to team 2) at `distance`.
function LanePath.tangentAt(path: Path, distance: number): Point
	local d = math.clamp(distance, 0, path.length)
	local i = segmentAt(path, d)
	local delta = sub(path.points[i + 1], path.points[i])
	local l = len(delta)
	return { x = delta.x / l, z = delta.z / l }
end

-- The point `distance` studs along the lane (clamped to the ends), moved `lateral` studs to the
-- left of the direction of travel.
function LanePath.pointAt(path: Path, distance: number, lateral: number?): Point
	local d = math.clamp(distance, 0, path.length)
	local i = segmentAt(path, d)
	local a = path.points[i]
	local b = path.points[i + 1]
	local segmentLength = path.cumulative[i + 1] - path.cumulative[i]
	local t = (d - path.cumulative[i]) / segmentLength
	local x = a.x + (b.x - a.x) * t
	local z = a.z + (b.z - a.z) * t
	local offset = lateral or 0
	if offset ~= 0 then
		local dx = (b.x - a.x) / segmentLength
		local dz = (b.z - a.z) / segmentLength
		-- Left of travel on the x/z plane seen from above with +y up is (dz, -dx).
		x += dz * offset
		z += -dx * offset
	end
	return { x = x, z = z }
end

function LanePath.pointAtProgress(path: Path, progress: number, lateral: number?): Point
	return LanePath.pointAt(path, progress * path.length, lateral)
end

-- Projects `point` onto the lane. Returns the distance along the lane of the nearest point and
-- the signed lateral offset from it (positive = left of travel).
function LanePath.project(path: Path, point: Point): (number, number)
	local bestDistanceSq = math.huge
	local bestAlong = 0
	local bestLateral = 0
	local points = path.points
	for i = 1, #points - 1 do
		local a = points[i]
		local b = points[i + 1]
		local segmentLength = path.cumulative[i + 1] - path.cumulative[i]
		local dx = (b.x - a.x) / segmentLength
		local dz = (b.z - a.z) / segmentLength
		local px = point.x - a.x
		local pz = point.z - a.z
		local t = math.clamp(px * dx + pz * dz, 0, segmentLength)
		local nearestX = a.x + dx * t
		local nearestZ = a.z + dz * t
		local ox = point.x - nearestX
		local oz = point.z - nearestZ
		local distanceSq = ox * ox + oz * oz
		if distanceSq < bestDistanceSq then
			bestDistanceSq = distanceSq
			bestAlong = path.cumulative[i] + t
			bestLateral = ox * dz - oz * dx
		end
	end
	return bestAlong, bestLateral
end

-- Progress (0 at team 1's end, 1 at team 2's end) of the nearest point on the lane.
function LanePath.progressOf(path: Path, point: Point): number
	local along = LanePath.project(path, point)
	return along / path.length
end

return LanePath
