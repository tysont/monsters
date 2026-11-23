--!strict
-- Melee geometry on the ground plane: range, arc and target selection. Pure, unit tested under
-- Lune. The server uses it to resolve attacks; the client uses the same rules to predict its own
-- hits for instant feedback.

export type Point = { x: number, z: number }

export type Candidate = {
	id: number,
	position: Point,
	-- Body radius; a target counts as in range when its edge is.
	radius: number,
}

export type Params = {
	range: number,
	-- Total arc in degrees.
	arc: number,
	maxTargets: number,
}

local Melee = {}

-- Whether `target` is within half of `arc` degrees either side of `facing` from `origin`.
-- `facing` need not be normalised. A target at the origin always counts.
function Melee.inArc(origin: Point, facing: Point, target: Point, arc: number): boolean
	if arc >= 360 then
		return true
	end
	local dx, dz = target.x - origin.x, target.z - origin.z
	local d = math.sqrt(dx * dx + dz * dz)
	local f = math.sqrt(facing.x * facing.x + facing.z * facing.z)
	if d < 1e-6 then
		return true
	end
	if f < 1e-6 then
		return false
	end
	local cos = (dx * facing.x + dz * facing.z) / (d * f)
	return cos >= math.cos(math.rad(arc / 2)) - 1e-9
end

-- Targets hit by a swing from `origin` facing `facing`, nearest first, at most maxTargets.
function Melee.selectTargets(origin: Point, facing: Point, candidates: { Candidate }, params: Params): { number }
	local hits = {}
	for _, c in candidates do
		local dx, dz = c.position.x - origin.x, c.position.z - origin.z
		local distance = math.sqrt(dx * dx + dz * dz)
		if distance - c.radius <= params.range and Melee.inArc(origin, facing, c.position, params.arc) then
			table.insert(hits, { id = c.id, distance = distance })
		end
	end
	table.sort(hits, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.id < b.id
	end)
	local ids: { number } = {}
	for i = 1, math.min(#hits, params.maxTargets) do
		ids[i] = hits[i].id
	end
	return ids
end

-- Whether an action last used at `lastAt` may be used again at `now`. `tolerance` forgives
-- requests that arrive slightly early because of network jitter.
function Melee.cooldownReady(lastAt: number?, now: number, cooldown: number, tolerance: number): boolean
	if lastAt == nil then
		return true
	end
	return now - lastAt >= cooldown - tolerance
end

return Melee
