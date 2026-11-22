--!strict
-- Builds the greybox map at runtime from Shared.Map (which is built from Config.MapLayout).
-- Every part is a plain anchored block (simple collision), created in one model and parented
-- once. The model is Persistent for streaming: the greybox is small, and dev cameras need to see
-- all of it. Final art (Phase 13) is built in Studio and uses normal streaming.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Map = require(ReplicatedStorage.Shared.Map)

local MapService = {
	name = "MapService",
}

-- Roblox parts can be at most 2048 studs on a side; larger blocks are tiled.
local MAX_PART_SIZE = 2000

local function teamColor(team: number): BrickColor
	-- Cast: the engine types only accept literal BrickColor names.
	return BrickColor.new(Config.get().teams[team].brickColor :: any)
end

local COLORS = {
	ground = Color3.fromRGB(96, 128, 82),
	lane = Color3.fromRGB(196, 170, 120),
	wall = Color3.fromRGB(70, 74, 80),
	boundary = Color3.fromRGB(45, 48, 54),
	hatchery = Color3.fromRGB(240, 200, 60),
	camp = Color3.fromRGB(150, 80, 200),
	minionSpawn = Color3.fromRGB(70, 210, 220),
}

type MarkerStyle = { size: Vector3, label: string }

local MARKER_STYLES: { [Map.MarkerKind]: MarkerStyle } = {
	titan = { size = Vector3.new(30, 40, 30), label = "Titan" },
	innerGuardian = { size = Vector3.new(14, 22, 14), label = "Inner guardian" },
	outerGuardian = { size = Vector3.new(14, 22, 14), label = "Outer guardian" },
	hatchery = { size = Vector3.new(26, 6, 26), label = "Hatchery" },
	camp = { size = Vector3.new(30, 3, 30), label = "Camp" },
	minionSpawn = { size = Vector3.new(10, 1, 10), label = "Minion spawn" },
}

local function newPart(name: string, cframe: CFrame, size: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = color
	part.Size = size
	part.CFrame = cframe
	part.Parent = parent
	return part
end

-- An axis-aligned block from y = bottom to y = bottom + height, tiled if it is too large.
local function block(name: string, rect: Map.Rect, bottom: number, height: number, color: Color3, parent: Instance)
	local tilesX = math.max(1, math.ceil(rect.size.x / MAX_PART_SIZE))
	local tilesZ = math.max(1, math.ceil(rect.size.z / MAX_PART_SIZE))
	local sx = rect.size.x / tilesX
	local sz = rect.size.z / tilesZ
	for i = 1, tilesX do
		for j = 1, tilesZ do
			local x = rect.center.x - rect.size.x / 2 + (i - 0.5) * sx
			local z = rect.center.z - rect.size.z / 2 + (j - 0.5) * sz
			local part =
				newPart(name, CFrame.new(x, bottom + height / 2, z), Vector3.new(sx, height, sz), color, parent)
			part.CastShadow = height > 2
		end
	end
end

local function label(part: BasePart, text: string)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(160, 28)
	gui.StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + 4, 0)
	gui.MaxDistance = 400
	gui.AlwaysOnTop = true
	local text_ = Instance.new("TextLabel")
	text_.Size = UDim2.fromScale(1, 1)
	text_.BackgroundTransparency = 1
	text_.TextColor3 = Color3.new(1, 1, 1)
	text_.TextStrokeTransparency = 0.3
	text_.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	text_.TextScaled = true
	text_.Text = text
	text_.Parent = gui
	gui.Parent = part
end

local function buildLanes(map: Map.MapData, parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Lanes"
	for _, lane in map.lanes do
		local points = lane.path.points
		for i = 1, #points - 1 do
			local a = Vector3.new(points[i].x, 0, points[i].z)
			local b = Vector3.new(points[i + 1].x, 0, points[i + 1].z)
			local length = (b - a).Magnitude
			local center = (a + b) / 2
			-- Extend each segment by half the lane width at both ends so corners are filled.
			-- The top sits just above the ground to avoid z-fighting.
			local cframe = CFrame.lookAt(center, b) + Vector3.new(0, -0.45, 0)
			local part = newPart(
				`{lane.id}_{i}`,
				cframe,
				Vector3.new(map.laneWidth, 1, length + map.laneWidth),
				COLORS.lane,
				folder
			)
			part.CastShadow = false
		end
	end
	folder.Parent = parent
end

local function buildMarkers(map: Map.MapData, parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Markers"
	for _, marker in map.markers do
		local style = MARKER_STYLES[marker.kind]
		local color = if marker.kind == "hatchery"
			then COLORS.hatchery
			elseif marker.kind == "camp" then COLORS.camp
			elseif marker.kind == "minionSpawn" then COLORS.minionSpawn
			else teamColor(marker.team :: number).Color
		local name = if marker.team then `T{marker.team}_{marker.lane or "base"}_{marker.kind}` else marker.kind
		local cframe = CFrame.new(marker.position.x, style.size.Y / 2, marker.position.z)
		local part = newPart(name, cframe, style.size, color, folder)
		-- Markers stand in for NPCs and structures that later phases simulate as data, so they
		-- do not block movement.
		part.CanCollide = false
		part.CanQuery = false
		part.Transparency = 0.25
		part:SetAttribute("Kind", marker.kind)
		part:SetAttribute("Team", marker.team)
		part:SetAttribute("Lane", marker.lane)
		local text = style.label
		if marker.team then
			text = `T{marker.team} {if marker.lane then marker.lane .. " " else ""}{style.label}`
		end
		label(part, text)
	end
	folder.Parent = parent
end

local function buildBases(map: Map.MapData, parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Bases"
	for team = 1, 2 do
		local base = map.bases[team]
		local color = teamColor(team).Color:Lerp(COLORS.ground, 0.55)
		block(`Base{team}`, base, -0.9, 1, color, folder)

		-- Team spawn: players spawn at the SpawnLocation matching their team colour, with a
		-- ForceField for the spawn protection time.
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = `Spawn{team}`
		spawn.Anchored = true
		spawn.Neutral = false
		spawn.TeamColor = teamColor(team)
		spawn.BrickColor = teamColor(team)
		spawn.Duration = Config.get().respawn.protectionSeconds
		spawn.AllowTeamChangeOnTouch = false
		spawn.Material = Enum.Material.SmoothPlastic
		spawn.Size = Vector3.new(12, 1, 12)
		-- Spawn on the side of the base away from the lanes, clear of the Titan marker.
		local offset = if team == 1 then -1 else 1
		spawn.CFrame = CFrame.new(base.center.x + offset * base.size.x * 0.3, 0.5, base.center.z)
		spawn.Parent = folder
	end
	folder.Parent = parent
end

-- Builds the map model without parenting it to the workspace.
function MapService.build(map: Map.MapData): Model
	local model = Instance.new("Model")
	model.Name = "Map"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local t = 16 -- ground extends under the boundary walls
	block(
		"Ground",
		{ center = { x = 0, z = 0 }, size = { x = 2 * map.halfWidth + 2 * t, z = 2 * map.halfDepth + 2 * t } },
		-1,
		1,
		COLORS.ground,
		model
	)

	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	for i, wall in map.walls do
		block(
			if wall.boundary then `Boundary{i}` else `JungleWall{i}`,
			wall,
			-1,
			wall.height + 1,
			if wall.boundary then COLORS.boundary else COLORS.wall,
			walls
		)
	end
	walls.Parent = model

	buildLanes(map, model)
	buildBases(map, model)
	buildMarkers(map, model)
	return model
end

function MapService.init(_self: typeof(MapService))
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end
	local model = MapService.build(Map.get())
	model.Parent = workspace
end

return MapService
