--!strict
-- Launch pads (rules in Shared.Launchers): three per base, one by each lane's gate. A player
-- uses their own team's pad (prompt, E) and flies to the furthest guardian their team still holds
-- in that lane. The server checks the request (team, range, alive, not frozen, not carrying an
-- egg, cooldown), picks the landing spot and tells the client to fly the arc; the client moves
-- its own character (it owns its physics). The player has the `Launching` attribute while in the
-- air (no attacking or dodging). If the client has not arrived shortly after the flight should
-- have ended, the server puts the character at the landing spot.
--
-- Pads publish attributes for the client: Team, Lane, and Destination ("outerGuardian",
-- "innerGuardian" or "" for none). The client shows the prompt only on its own team's live pads.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Launchers = require(ReplicatedStorage.Shared.Launchers)
local Map = require(ReplicatedStorage.Shared.Map)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Structures = require(ReplicatedStorage.Shared.Combat.Structures)

local CharacterService = require("./CharacterService")
local EggService = require("./EggService")
local MonsterService = require("./MonsterService")
local TeamService = require("./TeamService")

-- Root part height above the ground for a standing character.
local ROOT_HEIGHT = 3
-- The server corrects a flight that has not arrived this long after it should have.
local ARRIVAL_GRACE = 0.75
local ARRIVAL_TOLERANCE = 40
local REFRESH_SECONDS = 0.5

type PadState = {
	pad: Launchers.Pad,
	model: Model,
	prompt: ProximityPrompt,
	label: TextLabel,
	destination: Structures.Kind?,
}

local LauncherService = {
	name = "LauncherService",
	dependencies = { "CharacterService", "EggService", "MonsterService", "TeamService" },
}

local pads: { [string]: PadState } = {}
local lastLaunch: { [Player]: number } = {}
local flights: { [Player]: number } = {}
local nextFlight = 0

local function config(): Config.LauncherConfig
	return Config.get().launchers
end

local LABELS: { [string]: string } = { outerGuardian = "outer guardian", innerGuardian = "inner guardian" }

local function destinationOf(team: number, lane: Map.LaneId): Structures.Kind?
	local dead: { [string]: boolean } = {}
	for _, kind in { "outerGuardian", "innerGuardian" } do
		local key = Structures.key(kind :: Structures.Kind, team, lane)
		dead[key] = MonsterService.isDead(key)
	end
	return Launchers.destination(team, lane, dead)
end

local function guardianPosition(kind: Structures.Kind, team: number, lane: Map.LaneId): Map.Point?
	local m = MonsterService.structure(Structures.key(kind, team, lane))
	local s = m and m.structure
	return if s then s.position else nil
end

local function refresh(state: PadState)
	local pad = state.pad
	local destination: Structures.Kind? = destinationOf(pad.team, pad.lane)
	if destination == state.destination and state.model:GetAttribute("Destination") ~= nil then
		return
	end
	state.destination = destination
	state.model:SetAttribute("Destination", destination or "")
	state.prompt.ObjectText = `Launch pad ({pad.lane})`
	state.prompt.ActionText = if destination then `Fly to {LABELS[destination]}` else "No guardian left"
	state.label.Text = if destination
		then `Launch: {pad.lane} {LABELS[destination]}`
		else `Launch pad: {pad.lane} lane fallen`
end

local function rootOf(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

local function endFlight(player: Player, flight: number)
	if flights[player] == flight then
		flights[player] = nil
		player:SetAttribute("Launching", nil)
	end
end

-- Starts a flight for `player` from pad `key`. Returns nil on success or the reason it refused.
function LauncherService.launch(player: Player, key: string, skipRangeCheck: boolean?): string?
	local state = pads[key]
	if state == nil then
		return "no such pad"
	end
	local pad = state.pad
	if TeamService.teamOf(player) ~= pad.team then
		return "not your team's pad"
	end
	local humanoid, root = rootOf(player)
	if humanoid == nil or root == nil then
		return "not alive"
	end
	if CharacterService.isFrozen() or humanoid.WalkSpeed <= 0 then
		return "frozen"
	end
	if flights[player] then
		return "already flying"
	end
	if EggService.carrying(player) then
		return "carrying an egg"
	end
	local t = os.clock()
	if t - (lastLaunch[player] or -math.huge) < config().cooldownSeconds then
		return "cooldown"
	end
	local padPosition = Vector3.new(pad.position.x, root.Position.Y, pad.position.z)
	if not skipRangeCheck and (root.Position - padPosition).Magnitude > config().padRange + 4 then
		return "too far from the pad"
	end
	local destination: Structures.Kind? = destinationOf(pad.team, pad.lane)
	local guardian = destination and guardianPosition(destination, pad.team, pad.lane)
	if destination == nil or guardian == nil then
		return "no guardian left in this lane"
	end
	local landing = Launchers.landing(Map.get(), pad.team, pad.lane, guardian, config())
	local from = root.Position
	local to = Vector3.new(landing.x, ROOT_HEIGHT, landing.z)
	local distance = Vector3.new(to.X - from.X, 0, to.Z - from.Z).Magnitude
	local duration = Launchers.flightSeconds(distance, config())
	lastLaunch[player] = t
	nextFlight += 1
	local flight = nextFlight
	flights[player] = flight
	player:SetAttribute("Launching", true)
	Net.fireClient(Remotes.Launch, player, {
		from = from,
		to = to,
		duration = duration,
		apex = Launchers.apex(distance, config()),
		label = `{pad.lane} {LABELS[destination]}`,
	})
	task.delay(duration + ARRIVAL_GRACE, function()
		if flights[player] ~= flight then
			return
		end
		local _, current = rootOf(player)
		if current and (current.Position - to).Magnitude > ARRIVAL_TOLERANCE then
			-- The client did not fly (or is lagging badly): put them where they were going.
			local character = current.Parent :: Model
			current.AssemblyLinearVelocity = Vector3.zero
			character:PivotTo(CFrame.new(to))
		end
		endFlight(player, flight)
	end)
	return nil
end

local function buildPad(pad: Launchers.Pad, parent: Instance): PadState
	local teamColor = BrickColor.new(Config.get().teams[pad.team].brickColor :: any).Color
	local position = Vector3.new(pad.position.x, 0, pad.position.z)
	-- Barrels point down the lane.
	local lane = Map.get().laneById[pad.lane]
	local first, second = lane.points[1], lane.points[2]
	local along = Vector3.new(second.x - first.x, 0, second.z - first.z).Unit
	if pad.team == 2 then
		along = Vector3.new(-along.X, 0, along.Z)
	end

	local model = Instance.new("Model")
	model.Name = pad.key
	-- Six small models: always streamed in, so the prompt and label exist for every client.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Shape = Enum.PartType.Cylinder
	base.Size = Vector3.new(0.6, 12, 12)
	base.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	base.Material = Enum.Material.Metal
	base.Color = teamColor:Lerp(Color3.fromRGB(50, 52, 58), 0.55)
	base.Parent = model
	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.7, 8, 8)
	ring.CFrame = base.CFrame
	ring.Material = Enum.Material.Neon
	ring.Color = teamColor
	ring.Parent = model
	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Size = Vector3.new(7, 4, 4)
	-- A short barrel tilted 45 degrees up towards the lane, at the back of the pad.
	barrel.CFrame = CFrame.lookAt(
		position - along * 4 + Vector3.new(0, 3, 0),
		position + along * 4 + Vector3.new(0, 11, 0)
	) * CFrame.Angles(0, math.rad(90), 0)
	barrel.Material = Enum.Material.Metal
	barrel.Color = Color3.fromRGB(70, 74, 82)
	barrel.Parent = model
	for _, part in { base, ring, barrel } do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
	end
	model.PrimaryPart = base

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Launch"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = config().padRange
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Parent = ring

	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(220, 26)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
	gui.MaxDistance = 160
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	label.TextScaled = true
	label.Parent = gui
	gui.Parent = ring

	model:SetAttribute("Team", pad.team)
	model:SetAttribute("Lane", pad.lane)
	model.Parent = parent
	local state: PadState = { pad = pad, model = model, prompt = prompt, label = label, destination = nil }
	prompt.Triggered:Connect(function(player: Player)
		LauncherService.launch(player, pad.key)
	end)
	return state
end

function LauncherService.pads(): { Launchers.Pad }
	local out: { Launchers.Pad } = {}
	for _, state in pads do
		table.insert(out, state.pad)
	end
	return out
end

function LauncherService.init(_self: typeof(LauncherService))
	Players.PlayerRemoving:Connect(function(player: Player)
		lastLaunch[player] = nil
		flights[player] = nil
	end)
	CharacterService.characterSpawned:connect(function(player: Player, character: Model)
		-- A new character is never mid-flight.
		local flight = flights[player]
		if flight then
			endFlight(player, flight)
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Died:Connect(function()
				local current = flights[player]
				if current then
					endFlight(player, current)
				end
			end)
		end
	end)
end

function LauncherService.start(_self: typeof(LauncherService))
	local folder = Instance.new("Folder")
	folder.Name = "Launchers"
	folder.Parent = workspace
	for _, pad in Launchers.pads(Map.get(), config()) do
		local state = buildPad(pad, folder)
		pads[pad.key] = state
		refresh(state)
	end
	MonsterService.structureDestroyed:connect(function()
		for _, state in pads do
			refresh(state)
		end
	end)
	-- Structures respawn on round reset; a slow poll keeps pads right without another signal.
	while true do
		task.wait(REFRESH_SECONDS)
		for _, state in pads do
			refresh(state)
		end
	end
end

return LauncherService
