--!strict
-- Developer tools for players allowed by DebugAccess:
--   F3  top-down overview of the whole map (press again to return)
--   F4  free camera: WASD to move, E/Q up/down, Shift for speed, hold right mouse to look
--   F6  toggle 4x walk speed for traversal testing

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Map = require(ReplicatedStorage.Shared.Map)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local OVERVIEW_KEY = Enum.KeyCode.F3
local FREE_KEY = Enum.KeyCode.F4
local SPEED_KEY = Enum.KeyCode.F6
local SPEED_MULTIPLIER = 4
local FREE_SPEED = 60
local FREE_FAST = 4
local LOOK_SENSITIVITY = 0.0035

type Mode = "player" | "overview" | "free"

local DevToolsController = {
	name = "DevToolsController",
}

local enabled = false
local mode: Mode = "player"
local fast = false

-- Free camera state.
local freePosition = Vector3.zero
local yaw = 0
local pitch = 0

local function camera(): Camera
	return workspace.CurrentCamera
end

-- Freezes the character while a dev camera is active so WASD only moves the camera. This place
-- has no PlayerModule (character controls are built into the engine), so instead of disabling
-- controls the root part is anchored on this client, which owns its character's physics.
local function setCharacterFrozen(frozen: boolean)
	local character = (Players.LocalPlayer :: Player).Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = frozen
	end
end

local function overviewCFrame(cam: Camera): CFrame
	local map = Map.get()
	local viewport = cam.ViewportSize
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
	local halfFov = math.rad(cam.FieldOfView) / 2
	local height = math.max(map.halfDepth / math.tan(halfFov), map.halfWidth / (math.tan(halfFov) * aspect)) * 1.08
	-- Look straight down with north (negative z) at the top of the screen.
	return CFrame.lookAt(Vector3.new(0, height, 0), Vector3.zero, Vector3.new(0, 0, -1))
end

-- The scene's Atmosphere hazes the map into grey from high up, so dev cameras thin it locally
-- (client-only change) and restore it when returning to the player camera.
local savedDensity: number? = nil

local function setHaze(clear: boolean)
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere == nil then
		return
	end
	if clear and savedDensity == nil then
		savedDensity = atmosphere.Density
		atmosphere.Density = 0
	elseif not clear and savedDensity ~= nil then
		atmosphere.Density = savedDensity
		savedDensity = nil
	end
end

local function setMode(newMode: Mode)
	local cam = camera()
	if newMode == mode then
		newMode = "player"
	end
	mode = newMode
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	setHaze(mode ~= "player")
	if mode == "player" then
		cam.CameraType = Enum.CameraType.Custom
		local character = (Players.LocalPlayer :: Player).Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			cam.CameraSubject = humanoid
		end
		setCharacterFrozen(false)
		return
	end

	setCharacterFrozen(true)
	cam.CameraType = Enum.CameraType.Scriptable
	if mode == "overview" then
		cam.CFrame = overviewCFrame(cam)
	else
		freePosition = cam.CFrame.Position
		local look = cam.CFrame.LookVector
		yaw = math.atan2(-look.X, -look.Z)
		pitch = math.asin(math.clamp(look.Y, -1, 1))
	end
end

local function updateFree(dt: number)
	local cam = camera()
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		local delta = UserInputService:GetMouseDelta()
		yaw -= delta.X * LOOK_SENSITIVITY
		pitch = math.clamp(pitch - delta.Y * LOOK_SENSITIVITY, -1.5, 1.5)
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	local rotation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local move = Vector3.zero
	local function key(code: Enum.KeyCode): number
		return if UserInputService:IsKeyDown(code) then 1 else 0
	end
	move += rotation.LookVector * (key(Enum.KeyCode.W) - key(Enum.KeyCode.S))
	move += rotation.RightVector * (key(Enum.KeyCode.D) - key(Enum.KeyCode.A))
	move += Vector3.yAxis * (key(Enum.KeyCode.E) - key(Enum.KeyCode.Q))
	if move.Magnitude > 0 then
		local speed = FREE_SPEED * (if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then FREE_FAST else 1)
		freePosition += move.Unit * speed * dt
	end
	cam.CFrame = CFrame.new(freePosition) * rotation
end

function DevToolsController.init(_self: typeof(DevToolsController))
	enabled = DebugAccess.canView(Players.LocalPlayer :: Player)
end

function DevToolsController.start(_self: typeof(DevToolsController))
	if not enabled then
		return
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == OVERVIEW_KEY then
			setMode("overview")
		elseif input.KeyCode == FREE_KEY then
			setMode("free")
		elseif input.KeyCode == SPEED_KEY then
			fast = not fast
			Net.fireServer(Remotes.DevSetSpeedMultiplier, if fast then SPEED_MULTIPLIER else 1)
		end
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		-- Other camera code (Roblox's camera scripts, Studio tools) can reset the camera type.
		if mode ~= "player" and camera().CameraType ~= Enum.CameraType.Scriptable then
			camera().CameraType = Enum.CameraType.Scriptable
		end
		if mode == "free" then
			updateFree(dt)
		elseif mode == "overview" then
			camera().CFrame = overviewCFrame(camera())
		end
	end)

	-- A respawn returns to the normal character camera.
	local player = Players.LocalPlayer :: Player
	player.CharacterAdded:Connect(function()
		if mode ~= "player" then
			setMode("player")
		end
	end)
end

-- Current state, for the debug overlay.
function DevToolsController.describe(): string
	return `cam {mode}  speed {if fast then SPEED_MULTIPLIER else 1}x  [F3] map [F4] free [F6] speed`
end

return DevToolsController
