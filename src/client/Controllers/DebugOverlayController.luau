--!strict
-- Developer overlay: client frame rate, ping, memory, instances and network, plus server stats
-- from DebugStatsService. Only exists for players allowed by DebugAccess.
--
-- Toggle with F2, or tap the overlay (phones and tablets). Collapsed, it shows only the frame rate.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local DevToolsController = require("./DevToolsController")
local MinionRenderController = require("./MinionRenderController")
local UiController = require("./UiController")

local TOGGLE_KEY = Enum.KeyCode.F2
local REFRESH_SECONDS = 0.5
-- Server stats older than this are shown as missing.
local SERVER_STALE_SECONDS = 3

local DebugOverlayController = {
	name = "DebugOverlayController",
	dependencies = { "DevToolsController", "UiController", "MinionRenderController" },
}

local enabled = false
local expanded = false
local label: TextButton? = nil

local serverStats: Remotes.ServerStats? = nil
local serverStatsAt = 0

-- Frame samples since the last refresh.
local frameCount = 0
local frameTotal = 0
local frameMax = 0

local function buildGui(): TextButton
	local gui = Instance.new("ScreenGui")
	gui.Name = "DebugOverlay"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets

	local button = Instance.new("TextButton")
	button.Name = "Panel"
	button.AutoButtonColor = false
	-- Not a keyboard/gamepad navigation target.
	button.Selectable = false
	button.AutomaticSize = Enum.AutomaticSize.XY
	button.Size = UDim2.fromOffset(0, 0)
	button.Position = UDim2.fromOffset(8, 8)
	button.BackgroundColor3 = Color3.new(0, 0, 0)
	button.BackgroundTransparency = 0.35
	button.FontFace = Font.fromEnum(Enum.Font.RobotoMono)
	button.TextSize = 13
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.TextYAlignment = Enum.TextYAlignment.Top
	button.Text = ""
	button.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = button

	gui.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
	return button
end

local function format(n: number, places: number): string
	return string.format(`%.{places}f`, n)
end

local function render()
	local button = label
	if button == nil then
		return
	end

	local count = frameCount
	local fps = if frameTotal > 0 then count / frameTotal else 0
	local worstMs = frameMax * 1000
	frameCount, frameTotal, frameMax = 0, 0, 0

	if not expanded then
		button.Text = `FPS {format(fps, 0)}`
		return
	end

	local player = Players.LocalPlayer :: Player
	local lines = {
		`FPS     {format(fps, 0)}  (worst {format(worstMs, 1)} ms)`,
		`ping    {format(player:GetNetworkPing() * 1000, 0)} ms`,
		`memory  {format(Stats:GetTotalMemoryUsageMb(), 0)} MB`,
		`inst    {Stats.InstanceCount}`,
		`net     in {format(Stats.DataReceiveKbps, 1)}  out {format(Stats.DataSendKbps, 1)} KB/s`,
	}

	local s = serverStats
	if s ~= nil and os.clock() - serverStatsAt <= SERVER_STALE_SECONDS then
		local hz = if s.frameMs > 0 then 1000 / s.frameMs else 0
		table.insert(lines, "-- server --")
		table.insert(lines, `frame   {format(hz, 0)} Hz  avg {s.frameMs} / max {s.frameMaxMs} ms`)
		table.insert(lines, `beat    {s.heartbeatMs} ms`)
		table.insert(lines, `net     in {s.receiveKBps}  out {s.sendKBps} KB/s`)
		table.insert(lines, `memory  {s.memoryMb} MB   inst {s.instances}`)
		table.insert(lines, `players {s.players}`)
		table.insert(lines, `sim     {s.simMs} ms/frame (NPCs + minions)`)
	else
		table.insert(lines, "-- server: no data --")
	end
	table.insert(lines, `ui      {format(UiController.averageCostMs, 3)} ms/frame (HUD updates)`)
	local m = MinionRenderController.stats
	table.insert(lines, `minions {m.minions} known  {m.full} full  {m.simple} simple`)
	table.insert(lines, "-- dev --")
	table.insert(lines, DevToolsController.describe())
	table.insert(lines, if UserInputService.KeyboardEnabled then "[F2] collapse" else "[tap] collapse")
	button.Text = table.concat(lines, "\n")
end

local function setExpanded(value: boolean)
	expanded = value
	Net.fireServer(Remotes.DebugOverlayExpanded, value)
	render()
end

function DebugOverlayController.init(_self: typeof(DebugOverlayController))
	enabled = DebugAccess.canView(Players.LocalPlayer :: Player)
	if not enabled then
		return
	end
	expanded = Config.get().debug.overlayExpandedByDefault

	RunService.RenderStepped:Connect(function(dt: number)
		frameCount += 1
		frameTotal += dt
		if dt > frameMax then
			frameMax = dt
		end
	end)
end

function DebugOverlayController.start(_self: typeof(DebugOverlayController))
	if not enabled then
		return
	end

	Net.onClientEvent(Remotes.DebugServerStats, function(stats: Remotes.ServerStats)
		serverStats = stats
		serverStatsAt = os.clock()
	end)

	local button = buildGui()
	label = button
	button.Activated:Connect(function()
		setExpanded(not expanded)
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == TOGGLE_KEY then
			setExpanded(not expanded)
		end
	end)

	setExpanded(expanded)
	while true do
		task.wait(REFRESH_SECONDS)
		render()
	end
end

return DebugOverlayController
