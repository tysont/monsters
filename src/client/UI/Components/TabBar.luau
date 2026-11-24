--!strict
-- A row of tabs bound to a selected-tab value, with a sliding underline.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Motion = require("../Motion")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children, OnEvent = Fusion.Children, Fusion.OnEvent

export type Props = {
	tabs: { string },
	selected: Fusion.Value<string>,
	size: UDim2?,
	layoutOrder: number?,
}

local function TabBar(scope: UiState.Scope, props: Props): Frame
	local count = #props.tabs
	local index = scope:Computed(function(use)
		return table.find(props.tabs, use(props.selected)) or 1
	end)
	local underline = Motion.spring(
		scope,
		scope:Computed(function(use)
			return (use(index) - 1) / count
		end),
		Theme.motion.moveSpeed
	)

	local children: { Fusion.Child } = {
		scope:New("Frame")({
			Name = "Underline",
			AnchorPoint = Vector2.new(0, 1),
			Size = UDim2.new(1 / count, 0, 0, 3),
			Position = scope:Computed(function(use)
				return UDim2.fromScale(use(underline), 1)
			end),
			BackgroundColor3 = Theme.color.accent,
			[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.pill }) },
		}),
	}
	for i, tab in props.tabs do
		table.insert(
			children,
			scope:New("TextButton")({
				Name = tab,
				Size = UDim2.new(1 / count, 0, 1, -3),
				Position = UDim2.fromScale((i - 1) / count, 0),
				BackgroundTransparency = 1,
				Selectable = true,
				Text = tab,
				TextSize = Theme.text.label,
				FontFace = Theme.font.bold,
				TextColor3 = scope:Computed(function(use)
					return if use(props.selected) == tab then Theme.color.text else Theme.color.textMuted
				end),
				[OnEvent("Activated")] = function()
					props.selected:set(tab)
				end,
			})
		)
	end
	return scope:New("Frame")({
		Name = "TabBar",
		Size = props.size or UDim2.new(1, 0, 0, Theme.minTouch),
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		[Children] = children,
	}) :: Frame
end

return TabBar
