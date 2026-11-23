--!strict
-- The dev-only combat gym: a walled arena away from the map for tuning combat (Phase 3 fun
-- gate) and, later, monster authoring (Phase 7). Built only when Config.combat.gym.enabled
-- (dev and test environments; off in production). Players get there with /gym.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local CombatService = require("./CombatService")

local WALL_HEIGHT = 16
local WALL_THICKNESS = 4

local GymService = {
	name = "GymService",
	dependencies = { "CombatService" },
}

local model: Model? = nil

function GymService.enabled(): boolean
	return Config.get().combat.gym.enabled
end

-- World position of a point given relative to the gym centre (ground level).
function GymService.point(dx: number, dz: number): Vector3
	local gym = Config.get().combat.gym
	return Vector3.new(gym.center.x + dx, 0, gym.center.z + dz)
end

-- Keeps a position inside the gym walls, `margin` studs from them.
function GymService.clamp(x: number, z: number, margin: number): (number, number)
	local gym = Config.get().combat.gym
	local half = gym.size / 2 - margin
	return math.clamp(x, gym.center.x - half, gym.center.x + half),
		math.clamp(z, gym.center.z - half, gym.center.z + half)
end

function GymService.teleport(player: Player): boolean
	local character = player.Character
	if character == nil or model == nil then
		return false
	end
	character:PivotTo(CFrame.new(GymService.point(0, 60) + Vector3.new(0, 4, 0)))
	return true
end

local function part(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Parent = parent
	return p
end

local function build()
	local gym = Config.get().combat.gym
	local c = GymService.point(0, 0)
	local s = gym.size
	local m = Instance.new("Model")
	m.Name = "Gym"
	m.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	part("Floor", Vector3.new(s, 1, s), CFrame.new(c + Vector3.new(0, -0.5, 0)), Color3.fromRGB(110, 110, 120), m)
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	local wallColor = Color3.fromRGB(60, 62, 70)
	local h = WALL_HEIGHT
	local t = WALL_THICKNESS
	part("North", Vector3.new(s + 2 * t, h, t), CFrame.new(c + Vector3.new(0, h / 2, -s / 2 - t / 2)), wallColor, walls)
	part("South", Vector3.new(s + 2 * t, h, t), CFrame.new(c + Vector3.new(0, h / 2, s / 2 + t / 2)), wallColor, walls)
	part("West", Vector3.new(t, h, s), CFrame.new(c + Vector3.new(-s / 2 - t / 2, h / 2, 0)), wallColor, walls)
	part("East", Vector3.new(t, h, s), CFrame.new(c + Vector3.new(s / 2 + t / 2, h / 2, 0)), wallColor, walls)
	-- A pillar to test line of sight.
	part("Pillar", Vector3.new(8, h, 8), CFrame.new(c + Vector3.new(-40, h / 2, -20)), wallColor, walls)
	walls.Parent = m

	local spawn =
		part("Arrival", Vector3.new(10, 0.2, 10), CFrame.new(GymService.point(0, 60)), Color3.fromRGB(80, 160, 90), m)
	spawn.CanCollide = false

	m.Parent = workspace
	model = m
	table.insert(CombatService.losBlockers, walls)
end

function GymService.init(_self: typeof(GymService))
	if GymService.enabled() then
		build()
	end
end

return GymService
