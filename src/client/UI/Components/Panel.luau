--!strict
-- A surface with rounded corners, a subtle stroke, padding and an optional shadow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	size: Fusion.UsedAs<UDim2>?,
	position: Fusion.UsedAs<UDim2>?,
	anchorPoint: Vector2?,
	automaticSize: Enum.AutomaticSize?,
	color: Fusion.UsedAs<Color3>?,
	transparency: Fusion.UsedAs<number>?,
	padding: number?,
	layoutOrder: number?,
	name: string?,
	visible: Fusion.UsedAs<boolean>?,
	-- Lays children out vertically (or horizontally) with this gap.
	listGap: number?,
	horizontal: boolean?,
	children: { any }?,
}

local function Panel(scope: UiState.Scope, props: Props): Frame
	local padding = UDim.new(0, props.padding or Theme.space.md)
	local children: { Fusion.Child } = {
		scope:New("UICorner")({ CornerRadius = Theme.radius.lg }),
		scope:New("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.color.stroke,
			Transparency = 0.55,
			Thickness = Theme.stroke.thin,
		}),
		scope:New("UIPadding")({
			PaddingTop = padding,
			PaddingBottom = padding,
			PaddingLeft = padding,
			PaddingRight = padding,
		}),
	}
	if props.listGap then
		table.insert(
			children,
			scope:New("UIListLayout")({
				Padding = UDim.new(0, props.listGap),
				FillDirection = if props.horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				VerticalAlignment = if props.horizontal then Enum.VerticalAlignment.Center else nil,
			})
		)
	end
	local extra: { Fusion.Child } = props.children or {}
	for _, child in extra do
		table.insert(children, child)
	end
	return scope:New("Frame")({
		Name = props.name or "Panel",
		Size = props.size or UDim2.fromOffset(200, 100),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		AutomaticSize = props.automaticSize,
		BackgroundColor3 = props.color or Theme.color.surface,
		BackgroundTransparency = props.transparency or 0.08,
		LayoutOrder = props.layoutOrder,
		Visible = props.visible,
		[Children] = children,
	}) :: Frame
end

return Panel
