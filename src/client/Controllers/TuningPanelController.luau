--!strict
-- Dev-only live tuning panel (` key; F7 is taken by Studio). Shows every Shared.Combat.Tuning value with - and + buttons;
-- changes go to the server (DevSetTuning), which clamps them and stores them as attributes that
-- the server and every client read immediately. Also shows input-to-swing latency.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local CombatController = require("./CombatController")

local TOGGLE_KEY = Enum.KeyCode.Backquote
local ROW_HEIGHT = 26
local REFRESH_SECONDS = 0.25

local TuningPanelController = {
	name = "TuningPanelController",
	dependencies = { "CombatController" },
}

type Row = { definition: Tuning.Definition, value: TextLabel }

local function button(text: string, parent: Instance, position: UDim2, size: UDim2, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = Color3.fromRGB(60, 64, 76)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	b.TextSize = 14
	b.AutoButtonColor = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = b
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

local function label(
	text: string,
	parent: Instance,
	position: UDim2,
	size: UDim2,
	align: Enum.TextXAlignment
): TextLabel
	local l = Instance.new("TextLabel")
	l.Text = text
	l.Size = size
	l.Position = position
	l.BackgroundTransparency = 1
	l.TextColor3 = Color3.new(1, 1, 1)
	l.FontFace = Font.fromEnum(Enum.Font.RobotoMono)
	l.TextSize = 13
	l.TextXAlignment = align
	l.Parent = parent
	return l
end

function TuningPanelController.start(_self: typeof(TuningPanelController))
	local player = Players.LocalPlayer :: Player
	if not DebugAccess.canView(player) then
		return
	end

	local definitions = Tuning.definitions
	local gui = Instance.new("ScreenGui")
	gui.Name = "TuningPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 900
	gui.Enabled = false

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -12, 0.5, 0)
	panel.Size = UDim2.fromOffset(330, (#definitions + 4) * ROW_HEIGHT + 16)
	panel.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	panel.BackgroundTransparency = 0.15
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel
	panel.Parent = gui

	label(
		"Combat tuning  [`]",
		panel,
		UDim2.fromOffset(12, 8),
		UDim2.new(1, -24, 0, ROW_HEIGHT),
		Enum.TextXAlignment.Left
	)

	local rows: { Row } = {}
	for i, definition in definitions do
		local y = 8 + i * ROW_HEIGHT
		label(
			definition.label,
			panel,
			UDim2.fromOffset(12, y),
			UDim2.fromOffset(170, ROW_HEIGHT),
			Enum.TextXAlignment.Left
		)
		local value =
			label("", panel, UDim2.fromOffset(182, y), UDim2.fromOffset(60, ROW_HEIGHT), Enum.TextXAlignment.Right)
		local function change(direction: number)
			local target = Tuning.clamp(definition, Tuning.get(definition.key) + direction * definition.step)
			Net.fireServer(Remotes.DevSetTuning, { key = definition.key, value = target })
		end
		button("-", panel, UDim2.fromOffset(250, y + 2), UDim2.fromOffset(32, ROW_HEIGHT - 4), function()
			change(-1)
		end)
		button("+", panel, UDim2.fromOffset(286, y + 2), UDim2.fromOffset(32, ROW_HEIGHT - 4), function()
			change(1)
		end)
		table.insert(rows, { definition = definition, value = value })
	end

	local footerY = 8 + (#definitions + 1) * ROW_HEIGHT
	local latency =
		label("", panel, UDim2.fromOffset(12, footerY), UDim2.new(1, -24, 0, ROW_HEIGHT), Enum.TextXAlignment.Left)
	button(
		"Reset to defaults",
		panel,
		UDim2.fromOffset(12, footerY + ROW_HEIGHT + 4),
		UDim2.new(1, -24, 0, ROW_HEIGHT - 2),
		function()
			Net.fireServer(Remotes.DevResetTuning, nil)
		end
	)

	gui.Parent = player:WaitForChild("PlayerGui")

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == TOGGLE_KEY then
			gui.Enabled = not gui.Enabled
		end
	end)

	while true do
		if gui.Enabled then
			for _, row in rows do
				local v = Tuning.get(row.definition.key)
				local default = Tuning.default(row.definition.key)
				row.value.Text = string.format("%g", v)
				row.value.TextColor3 = if math.abs(v - default) > 1e-6
					then Color3.fromRGB(255, 210, 90)
					else Color3.new(1, 1, 1)
			end
			local avg, max, count = CombatController.swingLatency()
			latency.Text = string.format("swing latency avg %.1f / max %.1f ms (%d)", avg, max, count)
		end
		task.wait(REFRESH_SECONDS)
	end
end

return TuningPanelController
