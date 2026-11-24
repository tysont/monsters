--!strict
-- The pet stable: your pets (up to your unlocked slots), each with its pet XP and power bonus,
-- and which one is active. Choosing the active pet works at your base (the server checks).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require("../Components/Button")
local Modal = require("../Components/Modal")
local ProgressBar = require("../Components/ProgressBar")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type PetInfo = { id: number, kind: string, xp: number, multiplier: number, active: boolean }

export type Props = {
	open: Fusion.Value<boolean>,
	pets: Fusion.UsedAs<{ PetInfo }>,
	slots: Fusion.UsedAs<number>,
	setActive: (id: number) -> (),
}

local MAX_ROWS = 3

local function nameOf(kind: string): string
	local def = Config.get().monsters[kind]
	return if def then def.name else kind
end

local function PetsScreen(scope: UiState.Scope, props: Props): Frame
	local rows: { Fusion.Child } = {
		scope:New("UIListLayout")({
			Padding = UDim.new(0, Theme.space.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local bonus = Config.get().progression.petBonus
	-- A fixed set of rows (three slots), filled from the pet list.
	for i = 1, MAX_ROWS do
		local pet = scope:Computed(function(use)
			return use(props.pets)[i]
		end)
		table.insert(
			rows,
			scope:New("Frame")({
				Name = `Pet{i}`,
				LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 64),
				BackgroundColor3 = Theme.color.surfaceRaised,
				[Children] = {
					scope:New("UICorner")({ CornerRadius = Theme.radius.sm }),
					scope:New("UIStroke")({
						Color = Theme.color.accent,
						Thickness = Theme.stroke.thick,
						Transparency = scope:Computed(function(use)
							local p: PetInfo? = use(pet)
							return if p and p.active then 0 else 1
						end),
					}),
					Text(scope, {
						text = scope:Computed(function(use)
							local p: PetInfo? = use(pet)
							if p == nil then
								return if i <= use(props.slots) then "Empty slot" else "Locked slot (account level)"
							end
							return nameOf(p.kind) .. (if p.active then "  ·  active" else "")
						end),
						position = UDim2.fromOffset(Theme.space.md, 6),
						size = UDim2.new(1, -200, 0, 22),
						textSize = Theme.text.label,
						font = Theme.font.bold,
					}),
					Text(scope, {
						text = scope:Computed(function(use)
							local p: PetInfo? = use(pet)
							if p == nil then
								return ""
							end
							return `{p.xp} pet XP  ·  +{math.floor((p.multiplier - 1) * 1000 + 0.5) / 10}% power`
						end),
						position = UDim2.fromOffset(Theme.space.md, 28),
						size = UDim2.new(1, -200, 0, 18),
						textSize = Theme.text.caption,
						color = Theme.color.textMuted,
					}),
					ProgressBar(scope, {
						value = scope:Computed(function(use)
							local p: PetInfo? = use(pet)
							return if p then (p.multiplier - 1) / bonus else 0
						end),
						color = Theme.color.epic,
						position = UDim2.fromOffset(Theme.space.md, 48),
						size = UDim2.new(1, -200, 0, 6),
					}),
					scope:New("Frame")({
						Name = "Action",
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(1, -Theme.space.md, 0.5, 0),
						Size = UDim2.fromOffset(150, 44),
						BackgroundTransparency = 1,
						Visible = scope:Computed(function(use)
							local p: PetInfo? = use(pet)
							return p ~= nil and not p.active
						end),
						[Children] = {
							Button(scope, {
								text = "Make active",
								variant = "secondary",
								size = UDim2.fromScale(1, 1),
								onClick = function()
									local p = Fusion.peek(pet)
									if p then
										props.setActive(p.id)
									end
								end,
							}),
						},
					}),
				},
			})
		)
	end
	return Modal(scope, {
		name = "PetsScreen",
		title = scope:Computed(function(use)
			return `Pet stable  ({#use(props.pets)}/{use(props.slots)})`
		end),
		open = props.open,
		size = UDim2.fromOffset(600, 360),
		children = {
			scope:New("Frame")({
				Name = "Rows",
				Size = UDim2.new(1, 0, 0, 3 * 72),
				BackgroundTransparency = 1,
				[Children] = rows,
			}),
			Text(scope, {
				text = "Your active pet fights beside you and adds to your power. Switch pets at your base.",
				position = UDim2.fromOffset(0, 3 * 72 + 4),
				size = UDim2.new(1, 0, 0, 36),
				textSize = Theme.text.caption,
				color = Theme.color.textMuted,
				wrapped = true,
			}),
		},
	})
end

return PetsScreen
