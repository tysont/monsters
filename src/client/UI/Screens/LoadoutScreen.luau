--!strict
-- Inventory and loadout (J): pick the preset to wear (one free, three with the game pass), and for
-- each slot cycle through the cosmetics you own; set a skin on each of your pets. Changes apply at
-- once and everyone sees them. Cosmetics never change stats.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require("../Components/Button")
local Modal = require("../Components/Modal")
local PetsScreen = require("./PetsScreen")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	open: Fusion.Value<boolean>,
	owned: Fusion.UsedAs<{ [string]: boolean }>,
	loadout: Fusion.UsedAs<{ [string]: string }>,
	loadoutIndex: Fusion.UsedAs<number>,
	loadoutCount: Fusion.UsedAs<number>,
	pets: Fusion.UsedAs<{ PetsScreen.PetInfo }>,
	-- Whether the extra loadouts game pass exists on Roblox.
	passAvailable: boolean,
	equip: (slot: string, itemId: string?) -> (),
	selectLoadout: (index: number) -> (),
	buyPass: () -> (),
	setPetSkin: (petId: number, itemId: string?) -> (),
}

local SLOT_LABELS: { [string]: string } = {
	weaponSkin = "Weapon skin",
	armourSkin = "Armour",
	trail = "Trail",
	killEffect = "Kill effect",
	emote = "Emote (G)",
	title = "Title",
}

-- Owned items of a kind, in catalogue order.
local function ownedOf(owned: { [string]: boolean }, kind: string): { string }
	local out: { string } = {}
	for _, item in Cosmetics.list do
		if item.kind == kind and owned[item.id] then
			table.insert(out, item.id)
		end
	end
	return out
end

-- The next choice after `current` in owned items of `kind`, cycling through "none".
local function nextOf(owned: { [string]: boolean }, kind: string, current: string?, step: number): string?
	local choices = ownedOf(owned, kind)
	local index = if current then table.find(choices, current) or 0 else 0
	local count = #choices + 1
	local nextIndex = (index + step) % count
	return if nextIndex == 0 then nil else choices[nextIndex]
end

local function nameOf(id: string?): string
	local item = if id then Cosmetics.get(id) else nil
	return if item then item.name else "None"
end

local function arrows(scope: UiState.Scope, onStep: (step: number) -> ()): Frame
	return scope:New("Frame")({
		Name = "Arrows",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -Theme.space.md, 0.5, 0),
		Size = UDim2.fromOffset(110, 36),
		BackgroundTransparency = 1,
		[Children] = {
			scope:New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, Theme.space.sm),
			}),
			scope:New("Frame")({
				Size = UDim2.fromOffset(50, 36),
				BackgroundTransparency = 1,
				[Children] = {
					Button(scope, {
						text = "<",
						size = UDim2.fromScale(1, 1),
						onClick = function()
							onStep(-1)
						end,
					}),
				},
			}),
			scope:New("Frame")({
				Size = UDim2.fromOffset(50, 36),
				BackgroundTransparency = 1,
				[Children] = {
					Button(scope, {
						text = ">",
						size = UDim2.fromScale(1, 1),
						onClick = function()
							onStep(1)
						end,
					}),
				},
			}),
		},
	}) :: Frame
end

local function row(
	scope: UiState.Scope,
	order: number,
	label: string,
	value: Fusion.UsedAs<string>,
	onStep: (number) -> ()
): Frame
	return scope:New("Frame")({
		Name = label,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = Theme.color.surfaceRaised,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.sm }),
			Text(scope, {
				text = label,
				position = UDim2.fromOffset(Theme.space.md, 0),
				size = UDim2.new(0, 180, 1, 0),
				textSize = Theme.text.label,
				font = Theme.font.bold,
				alignY = Enum.TextYAlignment.Center,
			}),
			Text(scope, {
				text = value,
				position = UDim2.fromOffset(200, 0),
				size = UDim2.new(1, -330, 1, 0),
				textSize = Theme.text.label,
				color = Theme.color.textMuted,
				alignY = Enum.TextYAlignment.Center,
			}),
			arrows(scope, onStep),
		},
	}) :: Frame
end

local function LoadoutScreen(scope: UiState.Scope, props: Props): Frame
	local maxLoadouts = Config.get().economy.loadouts.withPass
	local presetButtons: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Theme.space.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i = 1, maxLoadouts do
		table.insert(
			presetButtons,
			scope:New("Frame")({
				LayoutOrder = i,
				Size = UDim2.fromOffset(120, 40),
				BackgroundTransparency = 1,
				[Children] = {
					Button(scope, {
						text = `Loadout {i}`,
						variant = "ghost",
						selected = scope:Computed(function(use)
							return use(props.loadoutIndex) == i
						end),
						disabled = scope:Computed(function(use)
							return i > use(props.loadoutCount)
						end),
						size = UDim2.fromScale(1, 1),
						onClick = function()
							if i <= Fusion.peek(props.loadoutCount) then
								props.selectLoadout(i)
							end
						end,
					}),
				},
			})
		)
	end
	if props.passAvailable then
		table.insert(
			presetButtons,
			scope:New("Frame")({
				LayoutOrder = maxLoadouts + 1,
				Size = UDim2.fromOffset(240, 40),
				BackgroundTransparency = 1,
				Visible = scope:Computed(function(use)
					return use(props.loadoutCount) < maxLoadouts
				end),
				[Children] = {
					Button(scope, {
						text = `More loadouts (R$ {Config.get().economy.extraLoadoutsPass.robux})`,
						variant = "primary",
						size = UDim2.fromScale(1, 1),
						onClick = props.buyPass,
					}),
				},
			})
		)
	end

	local rows: { Fusion.Child } = {
		scope:New("UIListLayout")({ Padding = UDim.new(0, Theme.space.sm), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	for order, slot in Cosmetics.SLOTS do
		table.insert(
			rows,
			row(
				scope,
				order,
				SLOT_LABELS[slot] or slot,
				scope:Computed(function(use)
					return nameOf(use(props.loadout)[slot])
				end),
				function(step: number)
					local choice = nextOf(Fusion.peek(props.owned), slot, Fusion.peek(props.loadout)[slot], step)
					props.equip(slot, choice)
				end
			)
		)
	end
	-- Pet skins: one row per pet slot.
	for i = 1, 3 do
		local pet = scope:Computed(function(use): PetsScreen.PetInfo?
			return use(props.pets)[i]
		end)
		local r = row(
			scope,
			100 + i,
			`Pet {i} skin`,
			scope:Computed(function(use)
				local p: PetsScreen.PetInfo? = use(pet)
				if p == nil then
					return "No pet"
				end
				local def = Config.get().monsters[p.kind]
				return `{if def then def.name else p.kind}: {nameOf(p.skin)}`
			end),
			function(step: number)
				local p = Fusion.peek(pet)
				if p then
					props.setPetSkin(p.id, nextOf(Fusion.peek(props.owned), "petSkin", p.skin, step))
				end
			end
		)
		table.insert(rows, r)
	end

	return Modal(scope, {
		name = "LoadoutScreen",
		title = "Loadout",
		open = props.open,
		size = UDim2.fromOffset(720, 640),
		children = {
			scope:New("Frame")({
				Name = "Presets",
				Size = UDim2.new(1, 0, 0, 40),
				BackgroundTransparency = 1,
				[Children] = presetButtons,
			}),
			scope:New("ScrollingFrame")({
				Name = "Slots",
				Position = UDim2.fromOffset(0, 52),
				Size = UDim2.new(1, 0, 1, -52),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 6,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(),
				[Children] = rows,
			}),
		},
	})
end

return LoadoutScreen
