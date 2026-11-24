--!strict
-- Attaches a tooltip to a GUI object: shown after a short hover or when the object is selected
-- with keyboard/gamepad navigation, positioned above the object.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Motion = require("../Motion")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

local DELAY = 0.35

local function Tooltip(scope: UiState.Scope, target: GuiObject, text: Fusion.UsedAs<string>): TextLabel
	local shown = scope:Value(false)
	local token = 0
	local function show()
		token += 1
		local mine = token
		task.delay(DELAY, function()
			if token == mine then
				shown:set(true)
			end
		end)
	end
	local function hide()
		token += 1
		shown:set(false)
	end
	table.insert(scope, target.MouseEnter:Connect(show))
	table.insert(scope, target.MouseLeave:Connect(hide))
	table.insert(scope, target.SelectionGained:Connect(show))
	table.insert(scope, target.SelectionLost:Connect(hide))

	local alpha = Motion.spring(
		scope,
		scope:Computed(function(use)
			return if use(shown) then 0 else 1
		end),
		Theme.motion.moveSpeed
	)
	return scope:New("TextLabel")({
		Name = "Tooltip",
		Parent = target,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -6),
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = Theme.color.surfaceRaised,
		BackgroundTransparency = scope:Computed(function(use)
			return 0.05 + use(alpha) * 0.95
		end),
		TextTransparency = alpha,
		Text = text,
		TextColor3 = Theme.color.text,
		TextSize = Theme.text.caption,
		FontFace = Theme.font.medium,
		ZIndex = 50,
		Visible = scope:Computed(function(use)
			return use(alpha) < 0.99
		end),
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.sm }),
			scope:New("UIPadding")({
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingTop = UDim.new(0, 4),
				PaddingBottom = UDim.new(0, 4),
			}),
		},
	}) :: TextLabel
end

return Tooltip
