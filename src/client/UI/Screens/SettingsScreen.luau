--!strict
-- Settings shell: effects quality, audio, controls and accessibility. Every control is a button,
-- so the whole screen works with mouse, keyboard (arrows + Enter) and gamepad. Settings are kept
-- for the session until Phase 9 saves them to the profile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Button = require("../Components/Button")
local Modal = require("../Components/Modal")
local ProgressBar = require("../Components/ProgressBar")
local TabBar = require("../Components/TabBar")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

local TABS = { "Graphics", "Audio", "Controls", "Accessibility" }
local ROW_HEIGHT = Theme.minTouch + Theme.space.sm

local function row(scope: UiState.Scope, label: string, order: number, controls: { Fusion.Child }): Frame
	local children: { Fusion.Child } = {
		Text(scope, {
			text = label,
			size = UDim2.fromScale(0.42, 1),
			textSize = Theme.text.body,
		}),
		scope:New("Frame")({
			Name = "Controls",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromScale(0.58, 1),
			BackgroundTransparency = 1,
			[Children] = {
				scope:New("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Theme.space.sm),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				controls :: any,
			},
		}),
	}
	return scope:New("Frame")({
		Name = label,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = order,
		BackgroundTransparency = 1,
		[Children] = children,
	}) :: Frame
end

-- A 0-1 value adjusted in 10% steps with - and + buttons, shown as a bar.
local function stepper(scope: UiState.Scope, value: Fusion.Value<number>): { Fusion.Child }
	local function change(delta: number)
		value:set(math.clamp(math.floor((Fusion.peek(value) + delta) * 10 + 0.5) / 10, 0, 1))
	end
	return {
		Button(scope, {
			text = "-",
			size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch),
			layoutOrder = 1,
			onClick = function()
				change(-0.1)
			end,
		}),
		ProgressBar(scope, {
			value = value,
			size = UDim2.fromOffset(150, 14),
			layoutOrder = 2,
			label = scope:Computed(function(use)
				return `{math.floor(use(value) * 100 + 0.5)}%`
			end),
		}),
		Button(scope, {
			text = "+",
			size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch),
			layoutOrder = 3,
			onClick = function()
				change(0.1)
			end,
		}),
	}
end

local function toggle(scope: UiState.Scope, value: Fusion.Value<boolean>): { Fusion.Child }
	return {
		Button(scope, {
			text = scope:Computed(function(use)
				return if use(value) then "On" else "Off"
			end),
			variant = "secondary",
			size = UDim2.fromOffset(96, Theme.minTouch),
			onClick = function()
				value:set(not Fusion.peek(value))
			end,
		}),
	}
end

local function choice(scope: UiState.Scope, value: Fusion.Value<UiState.EffectsQuality>): { Fusion.Child }
	local options: { UiState.EffectsQuality } = { "Low", "Medium", "High" }
	local buttons: { Fusion.Child } = {}
	for i, option in options do
		table.insert(
			buttons,
			Button(scope, {
				text = option,
				size = UDim2.fromOffset(84, Theme.minTouch),
				layoutOrder = i,
				selected = scope:Computed(function(use)
					return use(value) == option
				end),
				onClick = function()
					value:set(option :: UiState.EffectsQuality)
				end,
			})
		)
	end
	return buttons
end

local function page(scope: UiState.Scope, selected: Fusion.Value<string>, tab: string, rows: { Fusion.Child }): Frame
	local children: { Fusion.Child } = {
		scope:New("UIListLayout")({ Padding = UDim.new(0, Theme.space.xs), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	for _, r in rows do
		table.insert(children, r)
	end
	return scope:New("Frame")({
		Name = tab,
		Position = UDim2.fromOffset(0, Theme.minTouch + Theme.space.md),
		Size = UDim2.new(1, 0, 1, -(Theme.minTouch + Theme.space.md)),
		BackgroundTransparency = 1,
		Visible = scope:Computed(function(use)
			return use(selected) == tab
		end),
		[Children] = children,
	}) :: Frame
end

local function SettingsScreen(scope: UiState.Scope, open: Fusion.Value<boolean>): Frame
	local s = UiState.settings
	local selected = scope:Value(TABS[1])
	return Modal(scope, {
		name = "Settings",
		title = "Settings",
		open = open,
		size = UDim2.fromOffset(680, 460),
		children = {
			TabBar(scope, { tabs = TABS, selected = selected }),
			page(scope, selected, "Graphics", {
				row(scope, "Effects quality", 1, choice(scope, s.effectsQuality)),
				Text(scope, {
					text = "Controls the game's own effects (shake, hit flash). Roblox's graphics level is set in the Roblox menu.",
					layoutOrder = 2,
					wrapped = true,
					size = UDim2.new(1, 0, 0, 40),
					textSize = Theme.text.caption,
					color = Theme.color.textMuted,
				}),
			}),
			page(scope, selected, "Audio", {
				row(scope, "Master volume", 1, stepper(scope, s.masterVolume)),
				row(scope, "Effects volume", 2, stepper(scope, s.sfxVolume)),
				row(scope, "Music volume", 3, stepper(scope, s.musicVolume)),
			}),
			page(scope, selected, "Controls", {
				row(scope, "Aim attacks with camera", 1, toggle(scope, s.aimWithCamera)),
				Text(scope, {
					text = "Attack: left mouse / R2 / X     Dodge: Q / B     Settings: P",
					layoutOrder = 2,
					size = UDim2.new(1, 0, 0, 30),
					textSize = Theme.text.caption,
					color = Theme.color.textMuted,
				}),
			}),
			page(scope, selected, "Accessibility", {
				row(scope, "Reduced motion", 1, toggle(scope, s.reducedMotion)),
				Text(scope, {
					text = "Turns off camera shake and makes menus appear without animation.",
					layoutOrder = 2,
					size = UDim2.new(1, 0, 0, 30),
					textSize = Theme.text.caption,
					color = Theme.color.textMuted,
				}),
			}),
		},
	})
end

return SettingsScreen
