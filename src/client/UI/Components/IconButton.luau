--!strict
-- A square button with a glyph and a tooltip. Same feedback and selection behaviour as Button.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Motion = require("../Motion")
local Theme = require("../Theme")
local Tooltip = require("./Tooltip")
local UiState = require("../UiState")

local Children, OnEvent = Fusion.Children, Fusion.OnEvent

export type Props = {
	icon: Fusion.UsedAs<string>,
	tooltip: Fusion.UsedAs<string>,
	onClick: () -> (),
	size: number?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	name: string?,
}

local function IconButton(scope: UiState.Scope, props: Props): TextButton
	local size = math.max(props.size or Theme.minTouch, Theme.minTouch)
	local hovered = scope:Value(false)
	local pressed = scope:Value(false)
	local button = scope:New("TextButton")({
		Name = props.name or "IconButton",
		Size = UDim2.fromOffset(size, size),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
		AutoButtonColor = false,
		Selectable = true,
		BackgroundColor3 = Motion.spring(
			scope,
			scope:Computed(function(use)
				return if use(hovered) then Theme.color.surfaceHover else Theme.color.surfaceRaised
			end),
			Theme.motion.moveSpeed
		),
		BackgroundTransparency = 0.1,
		Text = props.icon,
		TextColor3 = Theme.color.text,
		TextSize = Theme.text.title,
		FontFace = Theme.font.bold,
		[OnEvent("MouseEnter")] = function()
			hovered:set(true)
		end,
		[OnEvent("MouseLeave")] = function()
			hovered:set(false)
			pressed:set(false)
		end,
		[OnEvent("SelectionGained")] = function()
			hovered:set(true)
		end,
		[OnEvent("SelectionLost")] = function()
			hovered:set(false)
		end,
		[OnEvent("MouseButton1Down")] = function()
			pressed:set(true)
		end,
		[OnEvent("MouseButton1Up")] = function()
			pressed:set(false)
		end,
		[OnEvent("Activated")] = function()
			props.onClick()
		end,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
			scope:New("UIScale")({
				Scale = Motion.spring(
					scope,
					scope:Computed(function(use)
						return if use(pressed) then 0.9 else 1
					end),
					Theme.motion.pressSpeed,
					Theme.motion.pressDamping
				),
			}),
		},
	}) :: TextButton
	Tooltip(scope, button, props.tooltip)
	return button
end

return IconButton
