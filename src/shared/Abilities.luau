--!strict
-- Ability rules shared by the server (resolution) and the client (prediction and previews).
-- Pure, unit tested under Lune.
--
--   Slots: 0 is the class's basic attack (left mouse); 1 to 3 are its abilities (keys 1, 2, 3).
--   Aim assist: a direction snaps to the enemy (or ally) nearest the aim within a generous cone,
--   so no ability needs pixel-precise aim. Points are clamped to the ability's range.
--   Shapes: circle (around the centre), cone (from the caster), line (from the caster, with a
--   half width). Targets are taken nearest first (lines: first along the line).

local Classes = require("./Classes")
local Shapes = require("./Combat/Shapes")

export type Point = { x: number, z: number }

export type Candidate = {
	id: number,
	position: Point,
	radius: number,
}

local Abilities = {}

Abilities.SLOTS = 3

-- The ability in a slot (0 = basic), or nil.
function Abilities.slot(class: Classes.Class, slot: number): Classes.Ability?
	if slot == 0 then
		return class.basic
	end
	return class.abilities[slot]
end

function Abilities.unlocked(ability: Classes.Ability, level: number): boolean
	return level >= ability.unlockLevel
end

-- Whether an ability last used at `lastAt` may be used at `now` (with network jitter slack).
function Abilities.ready(lastAt: number?, now: number, cooldown: number, tolerance: number): boolean
	return lastAt == nil or now - lastAt >= cooldown - tolerance
end

local function unit(x: number, z: number): (number, number)
	local d = math.sqrt(x * x + z * z)
	if d < 1e-6 then
		return 0, -1
	end
	return x / d, z / d
end

-- The candidate nearest the aim ray from `origin` along `dir` within `cone` degrees (total)
-- and `range` (to its edge), or nil. Ties go to the nearer one.
function Abilities.nearestToAim(
	origin: Point,
	dir: Point,
	candidates: { Candidate },
	range: number,
	cone: number
): Candidate?
	local fx, fz = unit(dir.x, dir.z)
	local half = math.rad(cone / 2)
	local best: Candidate? = nil
	local bestAngle, bestDistance = math.huge, math.huge
	for _, c in candidates do
		local vx, vz = c.position.x - origin.x, c.position.z - origin.z
		local d = math.sqrt(vx * vx + vz * vz)
		if d - c.radius <= range then
			local angle = if d < 1e-6 then 0 else math.acos(math.clamp((vx * fx + vz * fz) / d, -1, 1))
			-- Bodies count by their edge: a wide body close by is easier to hit.
			local slack = if d > 1e-6 then math.atan(c.radius / d) else math.pi
			angle = math.max(0, angle - slack)
			if angle <= half then
				if angle < bestAngle - 1e-3 or (math.abs(angle - bestAngle) <= 1e-3 and d < bestDistance) then
					best, bestAngle, bestDistance = c, angle, d
				end
			end
		end
	end
	return best
end

-- Aim assist: the unit direction towards the enemy nearest the aim, or the aim itself.
function Abilities.assist(origin: Point, dir: Point, candidates: { Candidate }, range: number, cone: number): Point
	local target = Abilities.nearestToAim(origin, dir, candidates, range, cone)
	if target then
		local x, z = unit(target.position.x - origin.x, target.position.z - origin.z)
		return { x = x, z = z }
	end
	local x, z = unit(dir.x, dir.z)
	return { x = x, z = z }
end

-- A ground point clamped to `range` from `origin`.
function Abilities.clampPoint(origin: Point, point: Point, range: number): Point
	local vx, vz = point.x - origin.x, point.z - origin.z
	local d = math.sqrt(vx * vx + vz * vz)
	if d <= range then
		return { x = point.x, z = point.z }
	end
	return { x = origin.x + vx / d * range, z = origin.z + vz / d * range }
end

-- Where the caster ends up after the ability's dash (or where it stands).
function Abilities.dashEnd(ability: Classes.Ability, origin: Point, dir: Point): Point
	local dash = ability.dash or 0
	local x, z = unit(dir.x, dir.z)
	return { x = origin.x + x * dash, z = origin.z + z * dash }
end

-- The shape's centre: the aim point for point aim, otherwise the caster (after any dash).
function Abilities.centre(ability: Classes.Ability, origin: Point, dir: Point, point: Point?): Point
	if ability.aim == "point" then
		return Abilities.clampPoint(origin, point or origin, ability.range or 0)
	end
	return Abilities.dashEnd(ability, origin, dir)
end

-- Whether a body (x, z, radius) touches `shape` centred at (cx, cz) facing unit (dx, dz).
function Abilities.inShape(
	shape: Classes.Shape,
	cx: number,
	cz: number,
	dx: number,
	dz: number,
	x: number,
	z: number,
	radius: number
): boolean
	if shape.kind == "circle" then
		return Shapes.inCircle(cx, cz, shape.size, x, z, radius)
	elseif shape.kind == "cone" then
		return Shapes.inCone(cx, cz, dx, dz, shape.size, shape.width or 90, x, z, radius)
	end
	-- Line: in front of the caster, within the half width of the segment.
	local along = (x - cx) * dx + (z - cz) * dz
	if along < -radius then
		return false
	end
	local bx, bz = cx + dx * shape.size, cz + dz * shape.size
	return Shapes.segmentDistance(cx, cz, bx, bz, x, z) <= (shape.width or 2) + radius
end

-- Bound for a spatial query around the centre that covers the shape.
function Abilities.bound(shape: Classes.Shape): number
	return shape.size
end

-- Of the candidates, those hit by the shape: nearest first (lines: first along the line), at
-- most `maxTargets`.
function Abilities.targets(
	shape: Classes.Shape,
	centre: Point,
	dir: Point,
	candidates: { Candidate },
	maxTargets: number?
): { number }
	local dx, dz = unit(dir.x, dir.z)
	local hits: { { id: number, order: number } } = {}
	for _, c in candidates do
		if Abilities.inShape(shape, centre.x, centre.z, dx, dz, c.position.x, c.position.z, c.radius) then
			local vx, vz = c.position.x - centre.x, c.position.z - centre.z
			local order = if shape.kind == "line" then vx * dx + vz * dz else math.sqrt(vx * vx + vz * vz)
			table.insert(hits, { id = c.id, order = order })
		end
	end
	table.sort(hits, function(a, b): boolean
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.id < b.id
	end)
	local out: { number } = {}
	for i = 1, math.min(#hits, maxTargets or math.huge) do
		out[i] = hits[i].id
	end
	return out
end

-- Damage, heal or shield/regen amount for an effect from a caster with `damage`.
function Abilities.amount(effect: Classes.Effect, damage: number): number
	if effect.kind == "status" and effect.status ~= "shield" and effect.status ~= "regen" then
		return effect.magnitude or 0
	end
	return (effect.scale or 1) * damage
end

-- What a class has unlocked at a level: the basic attack and each ability slot.
function Abilities.unlockedSlots(class: Classes.Class, level: number): { boolean }
	local out: { boolean } = {}
	for i, ability in class.abilities do
		out[i] = Abilities.unlocked(ability, level)
	end
	return out
end

-- The highest milestone look a class has reached at a level.
function Abilities.milestone(class: Classes.Class, level: number): Classes.Milestone
	local best = class.milestones[1]
	for _, m in class.milestones do
		if level >= m.level and m.level >= best.level then
			best = m
		end
	end
	return best
end

-- Teamwork against monsters: the damage multiplier for a set of distinct attacking classes
-- ({ [classId] = true }): `perClass` for each class beyond the first.
function Abilities.teamwork(classes: { [string]: boolean }, perClass: number): number
	local n = 0
	for _ in classes do
		n += 1
	end
	return 1 + perClass * math.max(0, n - 1)
end

return Abilities
