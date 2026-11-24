--!strict
-- Launch pads on the client: shows the launch prompt only on your own team's pads that still
-- have a guardian to fly to (and not while carrying an egg), and flies the arc the server sends
-- (Remotes.Launch). The local player owns its character's physics, so the flight sets the root
-- part's position and velocity every physics step until it lands.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Launchers = require(ReplicatedStorage.Shared.Launchers)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Feedback = require("../Feedback")
local Toast = require("../UI/Components/Toast")

local REFRESH_SECONDS = 0.25
-- Downward speed handed back to physics when the flight ends, so the character drops onto the
-- ground instead of hovering for a frame.
local LANDING_DROP = 20

local LauncherController = {
	name = "LauncherController",
}

local player = Players.LocalPlayer :: Player
local flying: RBXScriptConnection? = nil

local function myTeam(): number?
	local team = player.Team
	local index = team and team:GetAttribute("TeamIndex")
	return if type(index) == "number" then index else nil
end

local function refresh()
	local folder = workspace:FindFirstChild("Launchers")
	if folder == nil then
		return
	end
	local team = myTeam()
	local carrying = player:GetAttribute("CarryingEgg") ~= nil
	local launching = player:GetAttribute("Launching") ~= nil
	for _, model in folder:GetChildren() do
		local ring = model:FindFirstChild("Ring")
		local prompt = ring and ring:FindFirstChild("Launch")
		if prompt and prompt:IsA("ProximityPrompt") then
			local destination = model:GetAttribute("Destination")
			local enabled = model:GetAttribute("Team") == team
				and type(destination) == "string"
				and destination ~= ""
				and not carrying
				and not launching
			if prompt.Enabled ~= enabled then
				prompt.Enabled = enabled
			end
		end
	end
end

local function stop()
	local connection = flying
	if connection then
		connection:Disconnect()
		flying = nil
	end
end

local function fly(event: Remotes.LaunchEvent)
	stop()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		return
	end
	local part = root :: BasePart
	local hum = humanoid :: Humanoid
	local from, to = event.from, event.to
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local facing = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local started = os.clock()
	Toast.show(`Launching to your {event.label}`, "info")
	Feedback.shake(0.6, 0.2)
	hum:ChangeState(Enum.HumanoidStateType.Freefall)
	flying = RunService.PreSimulation:Connect(function()
		if hum.Health <= 0 or part.Parent == nil then
			stop()
			return
		end
		local s = math.clamp((os.clock() - started) / event.duration, 0, 1)
		local horizontal = from:Lerp(Vector3.new(to.X, from.Y, to.Z), s)
		local y = Launchers.height(s, from.Y, to.Y, event.apex)
		local position = Vector3.new(horizontal.X, y, horizontal.Z)
		part.CFrame = CFrame.lookAt(position, position + facing)
		if s >= 1 then
			part.AssemblyLinearVelocity = Vector3.new(0, -LANDING_DROP, 0)
			stop()
			Feedback.shake(0.5, 0.2)
			return
		end
		local climb = Launchers.climb(s, from.Y, to.Y, event.apex)
		part.AssemblyLinearVelocity = Vector3.new(flat.X, climb, flat.Z) / event.duration
	end)
end

function LauncherController.start(_self: typeof(LauncherController))
	Net.onClientEvent(Remotes.Launch, fly)
	player.CharacterAdded:Connect(stop)
	while true do
		task.wait(REFRESH_SECONDS)
		refresh()
	end
end

return LauncherController
