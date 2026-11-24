--!strict
-- Toast notifications: short messages stacked at the top centre that fade out on their own.
-- `Toast.mount(scope, parent)` creates the container once; `Toast.show(text, kind)` adds one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Kind = "info" | "success" | "warning" | "danger"

type Item = { id: number, text: string, kind: Kind }

local MAX_TOASTS = 4

local COLORS: { [Kind]: Color3 } = {
	info = Theme.color.info,
	success = Theme.color.success,
	warning = Theme.color.warning,
	danger = Theme.color.danger,
}

local Toast = {}

local items: Fusion.Value<{ Item }>? = nil
local nextId = 1

function Toast.mount(scope: UiState.Scope, parent: Instance): Frame
	local list = scope:Value({} :: { Item })
	items = list
	return scope:New("Frame")({
		Name = "Toasts",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(420, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		[Children] = {
			scope:New("UIListLayout")({
				Padding = UDim.new(0, Theme.space.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
			}),
			scope:ForValues(list :: any, function(_use: any, inner: any, item: Item): any
				return inner:New("TextLabel")({
					Name = "Toast",
					LayoutOrder = item.id,
					AutomaticSize = Enum.AutomaticSize.XY,
					Size = UDim2.fromOffset(0, 0),
					BackgroundColor3 = Theme.color.surfaceRaised,
					BackgroundTransparency = 0.05,
					Text = item.text,
					TextColor3 = Theme.color.text,
					TextSize = Theme.text.body,
					FontFace = Theme.font.medium,
					[Children] = {
						inner:New("UICorner")({ CornerRadius = Theme.radius.md }),
						inner:New("UIStroke")({
							ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
							Color = COLORS[item.kind],
							Thickness = Theme.stroke.thick,
						}),
						inner:New("UIPadding")({
							PaddingLeft = UDim.new(0, 14),
							PaddingRight = UDim.new(0, 14),
							PaddingTop = UDim.new(0, 8),
							PaddingBottom = UDim.new(0, 8),
						}),
					},
				})
			end) :: any,
		},
	}) :: Frame
end

function Toast.show(text: string, kind: Kind?)
	local list = items
	if list == nil then
		return
	end
	local item: Item = { id = nextId, text = text, kind = kind or "info" }
	nextId += 1
	local current = table.clone(Fusion.peek(list))
	table.insert(current, item)
	while #current > MAX_TOASTS do
		table.remove(current, 1)
	end
	list:set(current)
	task.delay(Theme.motion.toastSeconds, function()
		local now = table.clone(Fusion.peek(list))
		local index = table.find(now, item)
		if index then
			table.remove(now, index)
			list:set(now)
		end
	end)
end

return Toast
