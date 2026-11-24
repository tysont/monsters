--!strict
-- A cosmetic item card (shop and inventory): rarity strip, name, kind, price or owned state, and
-- up to two action buttons (Buy / Equip / Unequip, and Preview).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require("./Button")
local Text = require("./Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	item: Cosmetics.Item,
	-- What the main button says ("" hides it) and whether it can be pressed.
	action: Fusion.UsedAs<string>,
	actionEnabled: Fusion.UsedAs<boolean>,
	onAction: () -> (),
	-- Second line: price, "Owned" or "Equipped".
	status: Fusion.UsedAs<string>,
	onPreview: (() -> ())?,
	visible: Fusion.UsedAs<boolean>?,
	layoutOrder: number?,
}

local KIND_LABELS: { [string]: string } = {
	weaponSkin = "Weapon skin",
	armourSkin = "Armour",
	petSkin = "Pet skin",
	trail = "Trail",
	killEffect = "Kill effect",
	emote = "Emote (G)",
	title = "Title",
}

local function rarityColor(rarity: string): Color3
	return (Theme.color :: any)[rarity] or Theme.color.common
end

local function ItemCard(scope: UiState.Scope, props: Props): Frame
	local item = props.item
	local suffix = if item.weapon then ` ({item.weapon})` else ""
	local children: { Fusion.Child } = {
		scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
		scope:New("Frame")({
			Name = "Rarity",
			Size = UDim2.new(1, 0, 0, 5),
			BackgroundColor3 = rarityColor(item.rarity),
			[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.sm }) },
		}),
		scope:New("Frame")({
			Name = "Swatch",
			Position = UDim2.fromOffset(Theme.space.md, 16),
			Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = if item.look.color
				then Color3.fromRGB(item.look.color[1], item.look.color[2], item.look.color[3])
				else Theme.color.surfaceHover,
			[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.sm }) },
		}),
		Text(scope, {
			name = "Name",
			text = item.name,
			position = UDim2.fromOffset(Theme.space.md + 44, 12),
			size = UDim2.new(1, -(Theme.space.md * 2 + 44), 0, 20),
			textSize = Theme.text.label,
			font = Theme.font.bold,
		}),
		Text(scope, {
			name = "Kind",
			text = `{string.upper(string.sub(item.rarity, 1, 1))}{string.sub(item.rarity, 2)} {KIND_LABELS[item.kind] or item.kind}{suffix}`,
			position = UDim2.fromOffset(Theme.space.md + 44, 32),
			size = UDim2.new(1, -(Theme.space.md * 2 + 44), 0, 16),
			textSize = Theme.text.caption,
			color = rarityColor(item.rarity),
		}),
		Text(scope, {
			name = "Description",
			text = item.description,
			position = UDim2.fromOffset(Theme.space.md, 58),
			size = UDim2.new(1, -Theme.space.md * 2, 0, 30),
			textSize = Theme.text.caption,
			color = Theme.color.textMuted,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
		}),
		Text(scope, {
			name = "Status",
			text = props.status,
			position = UDim2.fromOffset(Theme.space.md, 92),
			size = UDim2.new(1, -Theme.space.md * 2, 0, 18),
			textSize = Theme.text.caption,
			font = Theme.font.bold,
		}),
		scope:New("Frame")({
			Name = "Buttons",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, Theme.space.md, 1, -Theme.space.sm),
			Size = UDim2.new(1, -Theme.space.md * 2, 0, 36),
			BackgroundTransparency = 1,
			[Children] = {
				scope:New("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					Padding = UDim.new(0, Theme.space.sm),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				scope:New("Frame")({
					Name = "ActionSlot",
					LayoutOrder = 1,
					Size = UDim2.new(0.6, -Theme.space.sm, 1, 0),
					BackgroundTransparency = 1,
					Visible = scope:Computed(function(use)
						return use(props.action) ~= ""
					end),
					[Children] = {
						Button(scope, {
							name = "Action",
							text = props.action,
							variant = "primary",
							disabled = scope:Computed(function(use)
								return not use(props.actionEnabled)
							end),
							size = UDim2.fromScale(1, 1),
							onClick = function()
								if Fusion.peek(props.actionEnabled) then
									props.onAction()
								end
							end,
						}),
					},
				}),
				scope:New("Frame")({
					Name = "PreviewSlot",
					LayoutOrder = 2,
					Size = UDim2.fromScale(0.4, 1),
					BackgroundTransparency = 1,
					Visible = props.onPreview ~= nil,
					[Children] = {
						Button(scope, {
							name = "Preview",
							text = "Preview",
							variant = "ghost",
							size = UDim2.fromScale(1, 1),
							onClick = function()
								local preview = props.onPreview
								if preview then
									preview()
								end
							end,
						}),
					},
				}),
			},
		}),
	}
	return scope:New("Frame")({
		Name = item.id,
		LayoutOrder = props.layoutOrder,
		Size = UDim2.fromOffset(240, 160),
		BackgroundColor3 = Theme.color.surfaceRaised,
		Visible = props.visible or true,
		[Children] = children,
	}) :: Frame
end

return ItemCard
