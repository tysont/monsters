--!strict
-- A horizontal bar for a 0-1 value (health, XP, cooldowns). The fill moves on a spring and an
-- optional label sits on top.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Motion = require("../Motion")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	value: Fusion.UsedAs<number>,
	color: Fusion.UsedAs<Color3>?,
	label: Fusion.UsedAs<string>?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	name: string?,
}

local function ProgressBar(scope: UiState.Scope, props: Props): Frame
	local fraction = scope:Computed(function(use)
		return math.clamp(use(props.value), 0, 1)
	end)
	local shown = Motion.spring(scope, fraction, Theme.motion.moveSpeed)
	return scope:New("Frame")({
		Name = props.name or "ProgressBar",
		Size = props.size or UDim2.fromOffset(240, 18),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
		BackgroundColor3 = Theme.color.background,
		BackgroundTransparency = 0.2,
		ClipsDescendants = true,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.pill }),
			scope:New("Frame")({
				Name = "Fill",
				Size = scope:Computed(function(use)
					return UDim2.fromScale(math.clamp(use(shown), 0, 1), 1)
				end),
				BackgroundColor3 = props.color or Theme.color.accent,
				[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.pill }) },
			}),
			scope:New("TextLabel")({
				Name = "Label",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Text = props.label or "",
				TextColor3 = Theme.color.text,
				TextStrokeTransparency = 0.5,
				TextSize = Theme.text.caption,
				FontFace = Theme.font.bold,
				ZIndex = 2,
			}),
		},
	}) :: Frame
end

return ProgressBar
