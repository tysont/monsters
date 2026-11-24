--!strict
-- A content card: accent strip, title, body text and optional children (pets, shop items,
-- round summaries).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	title: Fusion.UsedAs<string>,
	body: Fusion.UsedAs<string>?,
	accent: Fusion.UsedAs<Color3>?,
	size: UDim2?,
	layoutOrder: number?,
	children: { any }?,
}

local function Card(scope: UiState.Scope, props: Props): Frame
	local children: { Fusion.Child } = {
		scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
		scope:New("Frame")({
			Name = "Accent",
			Size = UDim2.new(0, 4, 1, 0),
			BackgroundColor3 = props.accent or Theme.color.accent,
			[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.sm }) },
		}),
		scope:New("TextLabel")({
			Name = "Title",
			Position = UDim2.fromOffset(Theme.space.lg, Theme.space.sm),
			Size = UDim2.new(1, -Theme.space.xl, 0, 22),
			BackgroundTransparency = 1,
			Text = props.title,
			TextColor3 = Theme.color.text,
			TextSize = Theme.text.label,
			FontFace = Theme.font.bold,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		scope:New("TextLabel")({
			Name = "Body",
			Position = UDim2.fromOffset(Theme.space.lg, 32),
			Size = UDim2.new(1, -Theme.space.xl, 1, -40),
			BackgroundTransparency = 1,
			Text = props.body or "",
			TextColor3 = Theme.color.textMuted,
			TextSize = Theme.text.caption,
			FontFace = Theme.font.regular,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
	}
	local extra: { Fusion.Child } = props.children or {}
	for _, child in extra do
		table.insert(children, child)
	end
	return scope:New("Frame")({
		Name = "Card",
		Size = props.size or UDim2.fromOffset(220, 110),
		LayoutOrder = props.layoutOrder,
		BackgroundColor3 = Theme.color.surfaceRaised,
		[Children] = children,
	}) :: Frame
end

return Card
