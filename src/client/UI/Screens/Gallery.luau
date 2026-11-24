--!strict
-- Dev-only component gallery: every component in its main states, for visual review. Opened
-- with the /gallery chat command.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Badge = require("../Components/Badge")
local Button = require("../Components/Button")
local Card = require("../Components/Card")
local CooldownRing = require("../Components/CooldownRing")
local IconButton = require("../Components/IconButton")
local List = require("../Components/List")
local Modal = require("../Components/Modal")
local Panel = require("../Components/Panel")
local ProgressBar = require("../Components/ProgressBar")
local TabBar = require("../Components/TabBar")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local Toast = require("../Components/Toast")
local UiState = require("../UiState")

local Children = Fusion.Children

local function section(scope: UiState.Scope, title: string, order: number, children: { Fusion.Child }): Frame
	local inner: { Fusion.Child } = {
		scope:New("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, Theme.space.md),
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Wraps = true,
		}),
	}
	for _, child in children do
		table.insert(inner, child)
	end
	return scope:New("Frame")({
		Name = title,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		BackgroundTransparency = 1,
		[Children] = {
			scope:New("UIListLayout")({ Padding = UDim.new(0, Theme.space.xs), SortOrder = Enum.SortOrder.LayoutOrder }),
			Text(scope, {
				text = title,
				layoutOrder = 1,
				textSize = Theme.text.label,
				font = Theme.font.bold,
				color = Theme.color.textMuted,
			}),
			scope:New("Frame")({
				Name = "Items",
				LayoutOrder = 2,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				[Children] = inner,
			}),
		},
	}) :: Frame
end

local function Gallery(scope: UiState.Scope, open: Fusion.Value<boolean>): Frame
	local tab = scope:Value("One")
	local progress = scope:Value(0.35)
	-- An animated cooldown so the ring can be seen sweeping.
	local sweep = scope:Value(1)
	task.spawn(function()
		while true do
			if Fusion.peek(open) then
				local v = Fusion.peek(sweep) - 0.02
				sweep:set(if v < 0 then 1 else v)
			end
			task.wait(0.05)
		end
	end)

	local function noop() end

	return Modal(scope, {
		name = "Gallery",
		title = "Component gallery",
		open = open,
		size = UDim2.fromOffset(900, 620),
		children = {
			List(scope, {
				gap = Theme.space.lg,
				children = {
					section(scope, "Button", 1, {
						Button(scope, { text = "Primary", variant = "primary", onClick = noop }),
						Button(scope, { text = "Secondary", onClick = noop }),
						Button(scope, { text = "Danger", variant = "danger", onClick = noop }),
						Button(scope, { text = "Ghost", variant = "ghost", onClick = noop }),
						Button(scope, { text = "Disabled", disabled = true, onClick = noop }),
						Button(scope, { text = "Selected", selected = true, onClick = noop }),
					}),
					section(scope, "Icon button and tooltip (hover)", 2, {
						IconButton(scope, { icon = "⚙", tooltip = "Settings", onClick = noop }),
						IconButton(scope, { icon = "★", tooltip = "Favourite", onClick = noop }),
					}),
					section(scope, "Badge", 3, {
						Badge(scope, { text = "Lv 12" }),
						Badge(scope, { text = "Common", color = Theme.color.common }),
						Badge(scope, { text = "Rare", color = Theme.color.rare }),
						Badge(scope, { text = "Epic", color = Theme.color.epic }),
						Badge(scope, { text = "Legendary", color = Theme.color.legendary }),
					}),
					section(scope, "Progress bar", 4, {
						ProgressBar(scope, { value = 0, label = "0%" }),
						ProgressBar(scope, {
							value = progress,
							color = Theme.color.health,
							label = scope:Computed(function(use)
								return `{math.floor(use(progress) * 100)}%`
							end),
						}),
						ProgressBar(scope, { value = 1, color = Theme.color.warning, label = "Full" }),
						Button(scope, {
							text = "Change",
							onClick = function()
								progress:set(math.random())
							end,
						}),
					}),
					section(scope, "Cooldown ring", 5, {
						CooldownRing(scope, { remaining = 0.25 }),
						CooldownRing(scope, { remaining = 0.5 }),
						CooldownRing(scope, { remaining = 0.75 }),
						CooldownRing(scope, { remaining = sweep }),
					}),
					section(scope, "Card", 6, {
						Card(
							scope,
							{ title = "Ember Drake", body = "Fire monster. Burrows and resurfaces under a player." }
						),
						Card(scope, { title = "Rare egg", body = "Incubates in 120 s.", accent = Theme.color.rare }),
					}),
					section(scope, "Tab bar", 7, {
						scope:New("Frame")({
							Size = UDim2.fromOffset(420, Theme.minTouch),
							BackgroundTransparency = 1,
							[Children] = { TabBar(scope, { tabs = { "One", "Two", "Three" }, selected = tab }) },
						}),
						Text(scope, {
							text = scope:Computed(function(use)
								return `Selected: {use(tab)}`
							end),
							size = UDim2.fromOffset(160, 24),
						}),
					}),
					section(scope, "Panel and text scale", 8, {
						Panel(scope, {
							size = UDim2.fromOffset(360, 0),
							automaticSize = Enum.AutomaticSize.Y,
							listGap = Theme.space.xs,
							children = {
								Text(scope, {
									text = "Display",
									textSize = Theme.text.display,
									font = Theme.font.heavy,
									size = UDim2.new(1, 0, 0, 50),
								}),
								Text(
									scope,
									{ text = "Heading", textSize = Theme.text.heading, font = Theme.font.bold }
								),
								Text(scope, { text = "Title", textSize = Theme.text.title, font = Theme.font.bold }),
								Text(scope, { text = "Body text", textSize = Theme.text.body }),
								Text(scope, {
									text = "Caption text",
									textSize = Theme.text.caption,
									color = Theme.color.textMuted,
								}),
							},
						}),
					}),
					section(scope, "Toast", 9, {
						Button(scope, {
							text = "Info",
							onClick = function()
								Toast.show("Guardian under attack in the top lane", "info")
							end,
						}),
						Button(scope, {
							text = "Success",
							onClick = function()
								Toast.show("Egg delivered!", "success")
							end,
						}),
						Button(scope, {
							text = "Warning",
							onClick = function()
								Toast.show("Your hatchery is being raided", "warning")
							end,
						}),
						Button(scope, {
							text = "Danger",
							onClick = function()
								Toast.show("Titan below 25%", "danger")
							end,
						}),
					}),
				},
			}),
		},
	})
end

return Gallery
