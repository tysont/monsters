--!strict
-- A text label using the type scale.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

export type Props = {
	text: Fusion.UsedAs<string>,
	size: Fusion.UsedAs<UDim2>?,
	position: Fusion.UsedAs<UDim2>?,
	anchorPoint: Vector2?,
	textSize: number?,
	font: Font?,
	color: Fusion.UsedAs<Color3>?,
	transparency: Fusion.UsedAs<number>?,
	alignX: Enum.TextXAlignment?,
	alignY: Enum.TextYAlignment?,
	automaticSize: Enum.AutomaticSize?,
	wrapped: boolean?,
	layoutOrder: number?,
	name: string?,
	stroke: boolean?,
	visible: Fusion.UsedAs<boolean>?,
}

local function Text(scope: UiState.Scope, props: Props): TextLabel
	return scope:New("TextLabel")({
		Name = props.name or "Text",
		Text = props.text,
		Size = props.size or UDim2.new(1, 0, 0, (props.textSize or Theme.text.body) + 6),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		AutomaticSize = props.automaticSize,
		BackgroundTransparency = 1,
		TextColor3 = props.color or Theme.color.text,
		TextTransparency = props.transparency or 0,
		TextSize = props.textSize or Theme.text.body,
		FontFace = props.font or Theme.font.medium,
		TextXAlignment = props.alignX or Enum.TextXAlignment.Left,
		TextYAlignment = props.alignY or Enum.TextYAlignment.Center,
		TextWrapped = props.wrapped or false,
		TextStrokeTransparency = if props.stroke then 0.5 else 1,
		LayoutOrder = props.layoutOrder,
		Visible = props.visible,
	}) :: TextLabel
end

return Text
