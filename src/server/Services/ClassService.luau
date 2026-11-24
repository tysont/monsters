--!strict
-- Choosing a class (Phase 10).
--
--   First join: until a profile has picked a class, the player has the `NeedsClass` attribute
--   and the client shows the class picker (Knight is preselected; closing it keeps Knight).
--   Switching: at your base's class station (a prompt in the spawn area), or while dead (the
--   respawn screen), including mid-round. Never in the field.
--   A switch changes the active class in the profile (each class keeps its own level and XP)
--   and applies its stats and weapon at once (alive at the station) or on respawn.
--
-- Stations are small Persistent models in workspace.ClassStations with Team attributes; the
-- client opens the picker from the prompt (the server re-checks range here).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Map = require(ReplicatedStorage.Shared.Map)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DataService = require("./DataService")
local ProgressionService = require("./ProgressionService")
local TeamService = require("./TeamService")

local ClassService = {
	name = "ClassService",
	dependencies = { "DataService", "ProgressionService", "TeamService" },
}

local stations: { [number]: Vector3 } = {}

-- Where a team's class station stands: beside its spawn, on the side away from the lanes.
local function stationPosition(team: number): Vector3
	local base = Map.get().bases[team]
	local side = if team == 1 then -1 else 1
	return Vector3.new(base.center.x + side * base.size.x * 0.3, 0, base.center.z + 22)
end

local function buildStation(team: number, parent: Instance)
	local position = stationPosition(team)
	stations[team] = position
	local teamColor = BrickColor.new(Config.get().teams[team].brickColor :: any).Color
	local model = Instance.new("Model")
	model.Name = `Station{team}`
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local plinth = Instance.new("Part")
	plinth.Name = "Plinth"
	plinth.Size = Vector3.new(6, 3, 6)
	plinth.CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0))
	plinth.Material = Enum.Material.Slate
	plinth.Color = teamColor:Lerp(Color3.fromRGB(60, 60, 64), 0.6)
	plinth.Parent = model
	local crystal = Instance.new("Part")
	crystal.Name = "Crystal"
	crystal.Size = Vector3.new(2, 4, 2)
	crystal.CFrame = CFrame.new(position + Vector3.new(0, 5.5, 0)) * CFrame.Angles(0, math.rad(45), 0)
	crystal.Material = Enum.Material.Neon
	crystal.Color = teamColor
	crystal.Parent = model
	for _, part in { plinth, crystal } do
		part.Anchored = true
		part.CanTouch = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
	end
	crystal.CanCollide = false
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ChangeClass"
	prompt.ActionText = "Change class"
	prompt.ObjectText = "Class station"
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = Config.get().classes.stationRange - 4
	prompt.RequiresLineOfSight = false
	prompt.Parent = plinth
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 26)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	gui.MaxDistance = 120
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	label.TextScaled = true
	label.Text = "Class station"
	label.Parent = gui
	gui.Parent = crystal
	model:SetAttribute("Team", team)
	model.Parent = parent
end

-- Whether a player may switch class now, and why not.
function ClassService.canSwitch(player: Player): (boolean, string?)
	if player:GetAttribute("NeedsClass") then
		return true, nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		-- Dead (or not spawned): the respawn screen.
		return true, nil
	end
	local team = TeamService.teamOf(player)
	local station = if team then stations[team] else nil
	if
		station
		and (Vector3.new(root.Position.X, 0, root.Position.Z) - station).Magnitude
			<= Config.get().classes.stationRange
	then
		return true, nil
	end
	return false, "Switch class at your base's class station or while respawning."
end

-- Makes `classId` the player's active class. Returns nil on success or the reason it failed.
function ClassService.choose(player: Player, classId: string, force: boolean?): string?
	local data = DataService.get(player)
	if data == nil then
		return "profile not loaded"
	end
	if Config.get().classDefinitions[classId] == nil then
		return `unknown class {classId}`
	end
	if not force then
		local ok, reason = ClassService.canSwitch(player)
		if not ok then
			return reason
		end
	end
	data.classChosen = true
	player:SetAttribute("NeedsClass", nil)
	if data.activeClass == classId then
		return nil
	end
	data.activeClass = classId
	if data.classes[classId] == nil then
		data.classes[classId] = { level = 1, xp = 0 }
	end
	-- Stats and weapon now (alive at the station) and the HUD attributes; otherwise on respawn.
	ProgressionService.refresh(player)
	return nil
end

function ClassService.stationPosition(team: number): Vector3
	return stationPosition(team)
end

function ClassService.init(_self: typeof(ClassService))
	DataService.loaded:connect(function(player: Player, data)
		if not data.classChosen then
			player:SetAttribute("NeedsClass", true)
		end
	end)
	Net.onServerEvent(Remotes.ChooseClass, function(player: Player, classId: string)
		local reason = ClassService.choose(player, classId)
		if reason then
			warn(`[Classes] {player.Name} could not switch to {classId}: {reason}`)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		player:SetAttribute("NeedsClass", nil)
	end)
end

function ClassService.start(_self: typeof(ClassService))
	local folder = Instance.new("Folder")
	folder.Name = "ClassStations"
	for team = 1, 2 do
		buildStation(team, folder)
	end
	folder.Parent = workspace
end

return ClassService
