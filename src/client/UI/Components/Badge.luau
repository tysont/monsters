--!strict
-- A small pill label (level, counts, rarity).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	text: Fusion.UsedAs<string>,
	color: Fusion.UsedAs<Color3>?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	name: string?,
}

local function Badge(scope: UiState.Scope, props: Props): GuiObject
	return scope:New("TextLabel")({
		Name = props.name or "Badge",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder,
		BackgroundColor3 = props.color or Theme.color.accent,
		Text = props.text,
		TextColor3 = Theme.color.textOnAccent,
		TextSize = Theme.text.caption,
		FontFace = Theme.font.heavy,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.pill }),
			scope:New("UIPadding")({ PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9) }),
		},
	}) :: GuiObject
end

return Badge
