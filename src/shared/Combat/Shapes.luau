--!strict
-- Ground shapes for monster attacks: circles (slam), cones (sweep) and lines (projectile paths),
-- all on the x/z plane. Pure, unit tested under Lune. The server resolves hits with these and
-- clients draw the same shapes as telegraphs.

local Shapes = {}

-- Whether a body of radius `pr` at (px, pz) touches the circle.
function Shapes.inCircle(cx: number, cz: number, radius: number, px: number, pz: number, pr: number): boolean
	local dx, dz = px - cx, pz - cz
	local r = radius + pr
	return dx * dx + dz * dz <= r * r
end

-- Whether a body touches the cone from (ox, oz) facing the unit direction (dx, dz), `reach` long
-- and `arc` degrees wide in total. Bodies right at the origin always count.
function Shapes.inCone(
	ox: number,
	oz: number,
	dx: number,
	dz: number,
	reach: number,
	arc: number,
	px: number,
	pz: number,
	pr: number
): boolean
	local vx, vz = px - ox, pz - oz
	local d = math.sqrt(vx * vx + vz * vz)
	if d > reach + pr then
		return false
	end
	if d <= pr then
		return true
	end
	local cos = math.clamp((vx * dx + vz * dz) / d, -1, 1)
	local angle = math.deg(math.acos(cos))
	-- The body's width widens the arc a little at this distance.
	local slack = math.deg(math.asin(math.clamp(pr / d, 0, 1)))
	return angle <= arc / 2 + slack
end

-- Distance from (px, pz) to the segment from (ax, az) to (bx, bz).
function Shapes.segmentDistance(ax: number, az: number, bx: number, bz: number, px: number, pz: number): number
	local sx, sz = bx - ax, bz - az
	local length2 = sx * sx + sz * sz
	local t = if length2 > 0 then math.clamp(((px - ax) * sx + (pz - az) * sz) / length2, 0, 1) else 0
	local cx, cz = ax + sx * t, az + sz * t
	local ex, ez = px - cx, pz - cz
	return math.sqrt(ex * ex + ez * ez)
end

-- (dx, dz) rotated by `degrees` (positive turns from +x towards +z).
function Shapes.rotate(dx: number, dz: number, degrees: number): (number, number)
	local a = math.rad(degrees)
	local c, s = math.cos(a), math.sin(a)
	return dx * c - dz * s, dx * s + dz * c
end

-- `count` directions fanned evenly around (dx, dz), `spread` degrees apart.
function Shapes.fan(dx: number, dz: number, count: number, spread: number): { { x: number, z: number } }
	local out: { { x: number, z: number } } = {}
	for i = 1, count do
		local offset = (i - (count + 1) / 2) * spread
		local x, z = Shapes.rotate(dx, dz, offset)
		table.insert(out, { x = x, z = z })
	end
	return out
end

export type EscapeShape = {
	primitive: string,
	radius: number?,
	reach: number?,
	arc: number?,
}

-- The farthest a body of radius `pr` standing anywhere inside the shape has to walk to get out,
-- taking the best direction. Used to check that every telegraph can be escaped on foot.
function Shapes.worstEscape(shape: EscapeShape, pr: number): number
	if shape.primitive == "slam" or shape.primitive == "grab" or shape.primitive == "burrow" then
		return (shape.radius or 0) + pr
	elseif shape.primitive == "projectile" or shape.primitive == "charge" then
		-- Step sideways off the line (for a charge, `radius` is the charging body's radius).
		return (shape.radius or 0) + pr
	end
	-- Sweep: from a point d along the centre line, either back out past the reach or sideways
	-- past the edge. The worst point is where both are equal.
	local reach = shape.reach or 0
	local half = math.rad(math.min((shape.arc or 0) / 2, 90))
	local s = math.sin(half)
	if (shape.arc or 0) >= 180 then
		return reach + pr
	end
	return reach * s / (1 + s) + pr
end

return Shapes
