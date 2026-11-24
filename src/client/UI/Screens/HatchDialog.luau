--!strict
-- The hatch choice: when an egg you incubated hatches, choose what it becomes.
--   Claim as pet: joins your stable; if every unlocked slot is full, pick the pet it replaces.
--   Feed to pet: becomes pet XP for the pet you pick (more for the same type).
--   Unleash: sends it down that hatchery's lane.
-- Your pets are listed for comparison. With no choice before the countdown ends, the server
-- unleashes it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)

local Button = require("../Components/Button")
local Modal = require("../Components/Modal")
local PetsScreen = require("./PetsScreen")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	open: Fusion.Value<boolean>,
	pending: Fusion.UsedAs<Remotes.HatchReadyEvent?>,
	-- Seconds left to choose (UiController ticks it).
	secondsLeft: Fusion.UsedAs<number>,
	pets: Fusion.UsedAs<{ PetsScreen.PetInfo }>,
	slots: Fusion.UsedAs<number>,
	choose: (choice: string, target: number?) -> (),
}

local function nameOf(kind: string): string
	local def = Config.get().monsters[kind]
	return if def then def.name else kind
end

local function HatchDialog(scope: UiState.Scope, props: Props): Frame
	-- The pet picked for feeding or replacing (defaults to the active pet).
	local picked = scope:Value(0)
	scope:Observer(props.open):onBind(function()
		local active = 0
		for _, pet in Fusion.peek(props.pets) do
			if pet.active then
				active = pet.id
			end
		end
		picked:set(active)
	end)
	local full = scope:Computed(function(use)
		return #use(props.pets) >= use(props.slots)
	end)
	local title = scope:Computed(function(use)
		local p = use(props.pending)
		return if p then `Your {p.rarity} {nameOf(p.kind)} egg hatched!` else "Egg hatched"
	end)

	local petButtons: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.space.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for i = 1, 3 do
		local pet = scope:Computed(function(use)
			return use(props.pets)[i]
		end)
		table.insert(
			petButtons,
			scope:New("Frame")({
				Name = `Pick{i}`,
				LayoutOrder = i,
				Size = UDim2.fromOffset(170, 48),
				BackgroundTransparency = 1,
				Visible = scope:Computed(function(use)
					return use(pet) ~= nil
				end),
				[Children] = {
					Button(scope, {
						text = scope:Computed(function(use)
							local p = use(pet)
							if p == nil then
								return ""
							end
							local pending = use(props.pending)
							local gain = ""
							if pending then
								local xp =
									Progression.feedXp(pending.rarity, pending.kind, p.kind, Config.get().progression)
								gain = `  +{xp} XP`
							end
							return `{nameOf(p.kind)}{gain}`
						end),
						variant = "ghost",
						selected = scope:Computed(function(use)
							local p = use(pet)
							return p ~= nil and use(picked) == p.id
						end),
						size = UDim2.fromScale(1, 1),
						onClick = function()
							local p = Fusion.peek(pet)
							if p then
								picked:set(p.id)
							end
						end,
					}),
				},
			})
		)
	end

	local function target(): number?
		local id = Fusion.peek(picked)
		return if id ~= 0 then id else nil
	end

	return Modal(scope, {
		name = "HatchDialog",
		title = title,
		open = props.open,
		size = UDim2.fromOffset(620, 360),
		children = {
			Text(scope, {
				text = scope:Computed(function(use)
					return `Choose what it becomes. Unleashed automatically in {Round.formatClock(
						use(props.secondsLeft)
					)}.`
				end),
				size = UDim2.new(1, 0, 0, 24),
				textSize = Theme.text.body,
				color = Theme.color.textMuted,
				wrapped = true,
			}),
			scope:New("Frame")({
				Name = "Choices",
				Position = UDim2.fromOffset(0, 34),
				Size = UDim2.new(1, 0, 0, 56),
				BackgroundTransparency = 1,
				[Children] = {
					scope:New("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0, Theme.space.md),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
					Button(scope, {
						name = "Claim",
						text = scope:Computed(function(use)
							return if use(full) then "Claim (replace picked)" else "Claim as pet"
						end),
						variant = "secondary",
						size = UDim2.fromOffset(180, 56),
						layoutOrder = 1,
						onClick = function()
							props.choose("claim", if Fusion.peek(full) then target() else nil)
						end,
					}),
					Button(scope, {
						name = "Feed",
						text = "Feed to picked pet",
						variant = "secondary",
						disabled = scope:Computed(function(use)
							return #use(props.pets) == 0
						end),
						size = UDim2.fromOffset(180, 56),
						layoutOrder = 2,
						onClick = function()
							props.choose("feed", target())
						end,
					}),
					Button(scope, {
						name = "Unleash",
						text = "Unleash on lane",
						size = UDim2.fromOffset(180, 56),
						layoutOrder = 3,
						onClick = function()
							props.choose("unleash", nil)
						end,
					}),
				},
			}),
			Text(scope, {
				text = scope:Computed(function(use)
					if #use(props.pets) == 0 then
						return "You have no pets yet: claim this one to start your stable."
					end
					return if use(full)
						then "Your stable is full: pick a pet to replace or to feed."
						else "Pick a pet to feed (same type gives more XP)."
				end),
				position = UDim2.fromOffset(0, 100),
				size = UDim2.new(1, 0, 0, 22),
				textSize = Theme.text.caption,
				color = Theme.color.textMuted,
				alignX = Enum.TextXAlignment.Center,
			}),
			scope:New("Frame")({
				Name = "Pets",
				Position = UDim2.fromOffset(0, 128),
				Size = UDim2.new(1, 0, 0, 48),
				BackgroundTransparency = 1,
				[Children] = petButtons,
			}),
		},
	})
end

return HatchDialog
