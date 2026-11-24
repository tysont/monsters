--!strict
-- Text button with variants, hover and press feedback (spring scale), a disabled state, and
-- keyboard/gamepad selection (Selectable; Enter or A activates through Activated).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Motion = require("../Motion")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children, OnEvent = Fusion.Children, Fusion.OnEvent

export type Variant = "primary" | "secondary" | "danger" | "ghost"

export type Props = {
	text: Fusion.UsedAs<string>,
	onClick: () -> (),
	variant: Variant?,
	disabled: Fusion.UsedAs<boolean>?,
	-- Shows an accent outline (the chosen option in a group).
	selected: Fusion.UsedAs<boolean>?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	name: string?,
}

local BASE: { [Variant]: Color3 } = {
	primary = Theme.color.accent,
	secondary = Theme.color.surfaceRaised,
	danger = Theme.color.danger,
	ghost = Theme.color.surface,
}

local function Button(scope: UiState.Scope, props: Props): TextButton
	local variant: Variant = props.variant or "secondary"
	local hovered = scope:Value(false)
	local pressed = scope:Value(false)
	local disabled = props.disabled or false
	local selected = props.selected or false

	local color = scope:Computed(function(use)
		local base = BASE[variant]
		if use(disabled) then
			return base:Lerp(Theme.color.background, 0.6)
		end
		if use(hovered) then
			return base:Lerp(Color3.new(1, 1, 1), 0.12)
		end
		return base
	end)
	local scaleGoal = scope:Computed(function(use)
		return if use(pressed) then 0.94 else 1
	end)

	return scope:New("TextButton")({
		Name = props.name or "Button",
		Size = props.size or UDim2.fromOffset(160, Theme.minTouch),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
		AutoButtonColor = false,
		Selectable = scope:Computed(function(use)
			return not use(disabled)
		end),
		Active = scope:Computed(function(use)
			return not use(disabled)
		end),
		BackgroundColor3 = Motion.spring(scope, color, Theme.motion.moveSpeed),
		BackgroundTransparency = if variant == "ghost" then 1 else 0,
		Text = props.text,
		TextColor3 = scope:Computed(function(use)
			return if use(disabled) then Theme.color.textMuted else Theme.color.text
		end),
		FontFace = Theme.font.bold,
		TextSize = Theme.text.label,

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
			if not Fusion.peek(disabled) then
				props.onClick()
			end
		end,

		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
			scope:New("UIScale")({
				Scale = Motion.spring(scope, scaleGoal, Theme.motion.pressSpeed, Theme.motion.pressDamping),
			}),
			scope:New("UIStroke")({
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = scope:Computed(function(use)
					return if use(selected) then Theme.color.accent else Theme.color.stroke
				end),
				Thickness = scope:Computed(function(use)
					return if use(selected) then Theme.stroke.thick else Theme.stroke.thin
				end),
				Transparency = scope:Computed(function(use)
					if use(selected) then
						return 0
					end
					return if variant == "secondary" then 0.4 else 1
				end),
			}),
		},
	}) :: TextButton
end

return Button
