--!strict
-- Placeholder visuals for class abilities (Phase 13 replaces them): bolts that fly, bursts that
-- grow and fade, fans of streaks for cones, and a ring that marks a delayed area. Each cast makes
-- a handful of parts that tween and are destroyed; nothing is created per frame.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Abilities = require(ReplicatedStorage.Shared.Abilities)
local Classes = require(ReplicatedStorage.Shared.Classes)
local Shapes = require(ReplicatedStorage.Shared.Combat.Shapes)

local AbilityFx = {}

local folder: Folder? = nil

local function container(): Folder
	if folder == nil or folder.Parent == nil then
		local f = Instance.new("Folder")
		f.Name = "AbilityFx"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Size = size
	p.CFrame = cframe
	p.Parent = container()
	return p
end

local function fadeOut(p: BasePart, seconds: number, grow: Vector3?)
	local goal: { [string]: any } = { Transparency = 1 }
	if grow then
		goal.Size = grow
	end
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	Debris:AddItem(p, seconds + 0.05)
end

-- A flat disc on the ground at `centre` with `radius`.
local function disc(centre: Vector3, radius: number, color: Color3, transparency: number): Part
	return part(
		Enum.PartType.Cylinder,
		Vector3.new(0.2, radius * 2, radius * 2),
		CFrame.new(centre.X, 0.15, centre.Z) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		transparency
	)
end

local function burst(centre: Vector3, radius: number, color: Color3)
	local d = disc(centre, radius * 0.4, color, 0.25)
	fadeOut(d, 0.35, Vector3.new(0.2, radius * 2, radius * 2))
end

local function bolt(from: Vector3, to: Vector3, color: Color3, speed: number, size: number)
	local start = from + Vector3.new(0, 2.5, 0)
	local finish = to + Vector3.new(0, 2.5, 0)
	local p = part(Enum.PartType.Ball, Vector3.one * size, CFrame.new(start), color, 0)
	local seconds = math.max(0.05, (finish - start).Magnitude / math.max(1, speed))
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { CFrame = CFrame.new(finish) }):Play()
	Debris:AddItem(p, seconds)
end

local function streaks(origin: Vector3, dir: Vector3, reach: number, arc: number, color: Color3)
	local count = 5
	for _, d in Shapes.fan(dir.X, dir.Z, count, arc / (count - 1)) do
		local v = Vector3.new(d.x, 0, d.z)
		local mid = origin + v * (reach / 2) + Vector3.new(0, 2, 0)
		local p = part(Enum.PartType.Block, Vector3.new(0.3, 0.3, reach), CFrame.lookAt(mid, mid + v), color, 0.3)
		fadeOut(p, 0.3)
	end
end

local function colorOf(class: Classes.Class): Color3
	return Color3.fromRGB(class.color[1], class.color[2], class.color[3])
end

-- Plays a cast's effects. `slot` -1 is a trap being sprung. `delay` is how long until it
-- resolves (projectile flight or a telegraph).
function AbilityFx.play(classId: string, slot: number, origin: Vector3, target: Vector3, dir: Vector3, delay: number)
	local class = Classes[classId]
	if class == nil then
		return
	end
	local color = colorOf(class)
	if slot == -1 then
		burst(target, 7, color)
		return
	end
	local ability = Abilities.slot(class, slot)
	if ability == nil then
		return
	end
	local shape = ability.shape
	local speed = ability.projectileSpeed
	if ability.trap then
		-- The server places the trap itself.
		return
	end
	if shape == nil then
		-- Ally heals: a soft glow on the caster.
		burst(origin, 4, color)
		return
	end
	if shape.kind == "line" then
		bolt(origin, target, color, speed or 200, if (ability.maxTargets or 1) > 1 then 1.2 else 0.8)
	elseif shape.kind == "cone" then
		streaks(origin, dir, shape.size, shape.width or 60, color)
	elseif ability.aim == "point" then
		if speed then
			bolt(origin, target, color, speed, 1.4)
		elseif delay > 0 then
			-- A ring marks where it will land.
			local ring = disc(target, shape.size, color, 0.7)
			Debris:AddItem(ring, delay)
		end
		task.delay(delay, function()
			burst(target, shape.size, color)
		end)
	else
		task.delay(delay, function()
			burst(target, shape.size, color)
		end)
	end
end

return AbilityFx
