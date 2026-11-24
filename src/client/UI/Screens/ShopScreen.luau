--!strict
-- The shop (H): featured items, a tab per cosmetic kind, gold packs for Robux, and the daily
-- login streak and quests. Items can be previewed on your own character before buying, and
-- equipped straight from here once owned. Prices are always shown up front.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require("../Components/Button")
local ItemCard = require("../Components/ItemCard")
local Modal = require("../Components/Modal")
local ProgressBar = require("../Components/ProgressBar")
local TabBar = require("../Components/TabBar")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type QuestInfo = { text: string, progress: number, target: number, gold: number, done: boolean }
export type PackInfo = { id: string, gold: number, robux: number }

export type Props = {
	open: Fusion.Value<boolean>,
	gold: Fusion.UsedAs<number>,
	owned: Fusion.UsedAs<{ [string]: boolean }>,
	loadout: Fusion.UsedAs<{ [string]: string }>,
	quests: Fusion.UsedAs<{ QuestInfo }>,
	streak: Fusion.UsedAs<number>,
	-- Gold packs that exist on Roblox (configured product IDs).
	packs: { PackInfo },
	buy: (itemId: string) -> (),
	equip: (slot: string, itemId: string?) -> (),
	preview: (itemId: string) -> (),
	buyPack: (packId: string) -> (),
}

local TABS = { "Featured", "Weapons", "Armour", "Pets", "Trails", "Effects", "Emotes", "Titles", "Gold", "Daily" }
local TAB_KIND: { [string]: string } = {
	Weapons = "weaponSkin",
	Armour = "armourSkin",
	Pets = "petSkin",
	Trails = "trail",
	Effects = "killEffect",
	Emotes = "emote",
	Titles = "title",
}

local WIDTH, HEIGHT = 1060, 620

local function ShopScreen(scope: UiState.Scope, props: Props): Frame
	local tab = scope:Value("Featured")
	local featured = Economy.featured(Economy.day(os.time()), Config.get().economy)

	local cards: { Fusion.Child } = {
		scope:New("UIGridLayout")({
			CellSize = UDim2.fromOffset(240, 160),
			CellPadding = UDim2.fromOffset(Theme.space.md, Theme.space.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for order, item in Cosmetics.list do
		local isFeatured = table.find(featured, item.id) ~= nil
		local owned = scope:Computed(function(use)
			return use(props.owned)[item.id] == true
		end)
		local equipped = scope:Computed(function(use)
			return use(props.loadout)[item.kind] == item.id
		end)
		table.insert(
			cards,
			ItemCard(scope, {
				item = item,
				layoutOrder = order,
				visible = scope:Computed(function(use)
					local t = use(tab)
					return (t == "Featured" and isFeatured) or TAB_KIND[t] == item.kind
				end),
				status = scope:Computed(function(use)
					if use(equipped) then
						return "Equipped"
					elseif use(owned) then
						return if item.kind == "petSkin" then "Owned: set it on a pet in Loadout (J)" else "Owned"
					end
					return `{item.price} gold`
				end),
				action = scope:Computed(function(use)
					if not use(owned) then
						return "Buy"
					elseif item.kind == "petSkin" then
						return ""
					end
					return if use(equipped) then "Unequip" else "Equip"
				end),
				actionEnabled = scope:Computed(function(use)
					return use(owned) or use(props.gold) >= item.price
				end),
				onAction = function()
					if not Fusion.peek(owned) then
						props.buy(item.id)
					elseif Fusion.peek(equipped) then
						props.equip(item.kind, nil)
					else
						props.equip(item.kind, item.id)
					end
				end,
				onPreview = function()
					props.preview(item.id)
				end,
			})
		)
	end

	-- Gold packs.
	local packChildren: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Theme.space.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, pack in props.packs do
		table.insert(
			packChildren,
			scope:New("Frame")({
				Name = pack.id,
				LayoutOrder = i,
				Size = UDim2.fromOffset(200, 140),
				BackgroundColor3 = Theme.color.surfaceRaised,
				[Children] = {
					scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
					Text(scope, {
						text = `{pack.gold} gold`,
						position = UDim2.fromOffset(0, 20),
						size = UDim2.new(1, 0, 0, 30),
						textSize = Theme.text.title,
						font = Theme.font.heavy,
						alignX = Enum.TextXAlignment.Center,
					}),
					scope:New("Frame")({
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.new(0.5, 0, 1, -Theme.space.md),
						Size = UDim2.fromOffset(160, 44),
						BackgroundTransparency = 1,
						[Children] = {
							Button(scope, {
								text = `R$ {pack.robux}`,
								variant = "primary",
								size = UDim2.fromScale(1, 1),
								onClick = function()
									props.buyPack(pack.id)
								end,
							}),
						},
					}),
				},
			})
		)
	end

	-- Daily login and quests: three fixed rows.
	local questRows: { Fusion.Child } = {
		scope:New("UIListLayout")({ Padding = UDim.new(0, Theme.space.sm), SortOrder = Enum.SortOrder.LayoutOrder }),
		Text(scope, {
			text = scope:Computed(function(use)
				return `Login streak: day {use(props.streak)} of {Config.get().economy.daily.streakDays}. Come back tomorrow for more.`
			end),
			layoutOrder = 0,
			size = UDim2.new(1, 0, 0, 24),
			textSize = Theme.text.label,
			font = Theme.font.bold,
		}),
	}
	for i = 1, Config.get().economy.daily.questCount do
		local quest = scope:Computed(function(use): QuestInfo?
			return use(props.quests)[i]
		end)
		table.insert(
			questRows,
			scope:New("Frame")({
				Name = `Quest{i}`,
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 56),
				BackgroundColor3 = Theme.color.surfaceRaised,
				[Children] = {
					scope:New("UICorner")({ CornerRadius = Theme.radius.sm }),
					Text(scope, {
						text = scope:Computed(function(use)
							local q: QuestInfo? = use(quest)
							if q == nil then
								return ""
							end
							return `{q.text}  ·  {q.gold} gold{if q.done then "  ·  done" else ""}`
						end),
						position = UDim2.fromOffset(Theme.space.md, 6),
						size = UDim2.new(1, -Theme.space.md * 2, 0, 20),
						textSize = Theme.text.label,
					}),
					ProgressBar(scope, {
						value = scope:Computed(function(use)
							local q: QuestInfo? = use(quest)
							return if q and q.target > 0 then q.progress / q.target else 0
						end),
						label = scope:Computed(function(use)
							local q: QuestInfo? = use(quest)
							return if q then `{math.floor(q.progress)} / {q.target}` else ""
						end),
						color = Theme.color.warning,
						position = UDim2.fromOffset(Theme.space.md, 30),
						size = UDim2.new(1, -Theme.space.md * 2, 0, 16),
					}),
				},
			})
		)
	end

	return Modal(scope, {
		name = "ShopScreen",
		title = scope:Computed(function(use)
			return `Shop  ·  {use(props.gold)} gold`
		end),
		open = props.open,
		size = UDim2.fromOffset(WIDTH, HEIGHT),
		children = {
			TabBar(scope, { tabs = TABS, selected = tab, size = UDim2.new(1, 0, 0, 40) }),
			scope:New("ScrollingFrame")({
				Name = "Items",
				Position = UDim2.fromOffset(0, 52),
				Size = UDim2.new(1, 0, 1, -52),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 6,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(),
				Visible = scope:Computed(function(use)
					local t = use(tab)
					return t ~= "Gold" and t ~= "Daily"
				end),
				[Children] = cards,
			}),
			scope:New("Frame")({
				Name = "Packs",
				Position = UDim2.fromOffset(0, 60),
				Size = UDim2.new(1, 0, 0, 160),
				BackgroundTransparency = 1,
				Visible = scope:Computed(function(use)
					return use(tab) == "Gold"
				end),
				[Children] = if #props.packs > 0
					then packChildren
					else {
						Text(scope, {
							text = "Gold packs are not on sale yet. Gold comes from playing, daily rewards and quests.",
							size = UDim2.new(1, 0, 0, 24),
							color = Theme.color.textMuted,
						}),
					},
			}),
			scope:New("Frame")({
				Name = "Daily",
				Position = UDim2.fromOffset(0, 60),
				Size = UDim2.new(1, 0, 0, 260),
				BackgroundTransparency = 1,
				Visible = scope:Computed(function(use)
					return use(tab) == "Daily"
				end),
				[Children] = questRows,
			}),
		},
	})
end

return ShopScreen
