--!strict
-- The class picker: the four classes side by side with their role, stats, abilities (and the
-- class level each unlocks at), and your level in each. Shown on first join (Knight is the
-- default), from the class station at your base, and from the respawn screen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Abilities = require(ReplicatedStorage.Shared.Abilities)
local Classes = require(ReplicatedStorage.Shared.Classes)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require("../Components/Button")
local Modal = require("../Components/Modal")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	open: Fusion.Value<boolean>,
	-- The active class ID.
	current: Fusion.UsedAs<string>,
	-- Class level per class ID (missing = 1).
	levels: Fusion.UsedAs<{ [string]: number }>,
	-- First join: the title says so.
	firstPick: Fusion.UsedAs<boolean>,
	choose: (classId: string) -> (),
}

local ORDER = { "knight", "hunter", "mage", "healer" }
local CARD_WIDTH = 250

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function card(scope: UiState.Scope, props: Props, class: Classes.Class, order: number): Frame
	local color = rgb(class.color)
	local level = scope:Computed(function(use)
		return use(props.levels)[class.id] or 1
	end)
	local lines: { Fusion.Child } = {
		scope:New("UIListLayout")({
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local entries = { class.basic }
	for _, ability in class.abilities do
		table.insert(entries, ability)
	end
	for i, ability in entries do
		table.insert(
			lines,
			Text(scope, {
				name = ability.id,
				layoutOrder = i,
				text = scope:Computed(function(use)
					local key = if i == 1 then "LMB" else tostring(i - 1)
					local lock = if Abilities.unlocked(ability, use(level))
						then ""
						else `  (level {ability.unlockLevel})`
					return `[{key}] {ability.name}{lock}`
				end),
				size = UDim2.new(1, 0, 0, 18),
				textSize = Theme.text.caption,
				color = scope:Computed(function(use)
					return if Abilities.unlocked(ability, use(level)) then Theme.color.text else Theme.color.textMuted
				end),
			})
		)
	end
	return scope:New("Frame")({
		Name = class.id,
		LayoutOrder = order,
		Size = UDim2.fromOffset(CARD_WIDTH, 400),
		BackgroundColor3 = Theme.color.surfaceRaised,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
			scope:New("UIStroke")({
				Color = color,
				Thickness = Theme.stroke.thick,
				Transparency = scope:Computed(function(use)
					return if use(props.current) == class.id then 0 else 0.8
				end),
			}),
			scope:New("Frame")({
				Name = "Accent",
				Size = UDim2.new(1, 0, 0, 6),
				BackgroundColor3 = color,
				[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.sm }) },
			}),
			scope:New("UIPadding")({
				PaddingLeft = UDim.new(0, Theme.space.md),
				PaddingRight = UDim.new(0, Theme.space.md),
				PaddingTop = UDim.new(0, Theme.space.md),
			}),
			Text(scope, {
				name = "Name",
				text = class.name,
				position = UDim2.fromOffset(0, 8),
				size = UDim2.new(1, 0, 0, 28),
				textSize = Theme.text.title,
				font = Theme.font.heavy,
			}),
			Text(scope, {
				name = "Role",
				text = scope:Computed(function(use)
					return `{class.role}  ·  level {use(level)}`
				end),
				position = UDim2.fromOffset(0, 38),
				size = UDim2.new(1, 0, 0, 18),
				textSize = Theme.text.label,
				font = Theme.font.bold,
				color = color,
			}),
			Text(scope, {
				name = "Description",
				text = class.description,
				position = UDim2.fromOffset(0, 62),
				size = UDim2.new(1, 0, 0, 64),
				textSize = Theme.text.caption,
				color = Theme.color.textMuted,
				wrapped = true,
				alignY = Enum.TextYAlignment.Top,
			}),
			Text(scope, {
				name = "Stats",
				text = `Health {class.stats.maxHealth}  ·  Damage {class.stats.damage}  ·  Defence {class.stats.defence}`,
				position = UDim2.fromOffset(0, 130),
				size = UDim2.new(1, 0, 0, 18),
				textSize = Theme.text.caption,
			}),
			scope:New("Frame")({
				Name = "Abilities",
				Position = UDim2.fromOffset(0, 158),
				Size = UDim2.new(1, 0, 0, 90),
				BackgroundTransparency = 1,
				[Children] = lines,
			}),
			Button(scope, {
				name = "Choose",
				text = scope:Computed(function(use)
					return if use(props.current) == class.id then "Playing" else `Play {class.name}`
				end),
				variant = "primary",
				disabled = scope:Computed(function(use)
					return use(props.current) == class.id and not use(props.firstPick)
				end),
				anchorPoint = Vector2.new(0.5, 1),
				position = UDim2.new(0.5, 0, 1, -Theme.space.md),
				size = UDim2.new(1, 0, 0, 44),
				onClick = function()
					props.choose(class.id)
				end,
			}),
		},
	}) :: Frame
end

local function ClassPicker(scope: UiState.Scope, props: Props): Frame
	local cards: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.space.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i, id in ORDER do
		local class = Classes[id]
		if class then
			table.insert(cards, card(scope, props, class, i))
		end
	end
	return Modal(scope, {
		name = "ClassPicker",
		title = scope:Computed(function(use)
			return if use(props.firstPick) then "Choose your class" else "Change class"
		end),
		open = props.open,
		size = UDim2.fromOffset(4 * CARD_WIDTH + 3 * Theme.space.md + 2 * Theme.space.lg, 520),
		children = {
			Text(scope, {
				text = "Each class levels up on its own. Switch at your base's class station or while respawning.",
				size = UDim2.new(1, 0, 0, 20),
				textSize = Theme.text.caption,
				color = Theme.color.textMuted,
				alignX = Enum.TextXAlignment.Center,
			}),
			scope:New("Frame")({
				Name = "Cards",
				Position = UDim2.fromOffset(0, 28),
				Size = UDim2.new(1, 0, 0, 400),
				BackgroundTransparency = 1,
				[Children] = cards,
			}),
		},
	})
end

return ClassPicker
