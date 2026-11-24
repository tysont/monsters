--!strict
-- A vertically scrolling list that sizes its canvas to its contents.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	size: UDim2?,
	position: UDim2?,
	gap: number?,
	layoutOrder: number?,
	children: { any },
	name: string?,
}

local function List(scope: UiState.Scope, props: Props): ScrollingFrame
	local children: { Fusion.Child } = {
		scope:New("UIListLayout")({
			Padding = UDim.new(0, props.gap or Theme.space.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		scope:New("UIPadding")({ PaddingRight = UDim.new(0, Theme.space.sm) }),
	}
	for _, child in props.children do
		table.insert(children, child)
	end
	return scope:New("ScrollingFrame")({
		Name = props.name or "List",
		Size = props.size or UDim2.fromScale(1, 1),
		Position = props.position,
		LayoutOrder = props.layoutOrder,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.color.stroke,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Selectable = false,
		[Children] = children,
	}) :: ScrollingFrame
end

return List
