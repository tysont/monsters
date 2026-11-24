--!strict
-- A centred dialog over a dimmed background. Opening selects the first selectable control so the
-- keyboard (arrows + Enter) and gamepad can drive it; Backspace, B or the close button closes it
-- (Escape is reserved by Roblox for its own menu).
-- Fades and scales in on a spring.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local IconButton = require("./IconButton")
local Motion = require("../Motion")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	title: Fusion.UsedAs<string>,
	open: Fusion.Value<boolean>,
	size: UDim2?,
	children: { any },
	name: string?,
}

local function firstSelectable(root: Instance): GuiObject?
	local best: GuiObject? = nil
	local bestOrder = math.huge
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") and d.Selectable and d.Visible and d.Name ~= "Close" then
			local order = d.AbsolutePosition.Y * 10000 + d.AbsolutePosition.X
			if order < bestOrder then
				best, bestOrder = d, order
			end
		end
	end
	return best
end

local function Modal(scope: UiState.Scope, props: Props): Frame
	local panel: CanvasGroup? = nil
	local actionName = "ModalClose_" .. HttpService:GenerateGUID(false)
	local alpha = Motion.spring(
		scope,
		scope:Computed(function(use)
			return if use(props.open) then 1 else 0
		end),
		Theme.motion.moveSpeed
	)

	local function close()
		props.open:set(false)
	end

	scope:Observer(props.open):onBind(function()
		if Fusion.peek(props.open) then
			ContextActionService:BindActionAtPriority(actionName, function(_, state)
				if state == Enum.UserInputState.Begin then
					close()
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
			-- Select once the dialog is on screen; invisible objects cannot take selection.
			task.delay(0.05, function()
				if panel and Fusion.peek(props.open) then
					GuiService.SelectedObject = firstSelectable(panel)
				end
			end)
		else
			ContextActionService:UnbindAction(actionName)
			local selected = GuiService.SelectedObject
			if selected and panel and selected:IsDescendantOf(panel) then
				GuiService.SelectedObject = nil
			end
		end
	end)
	table.insert(scope, function()
		ContextActionService:UnbindAction(actionName)
	end)

	local contents: { Fusion.Child } = {
		scope:New("UICorner")({ CornerRadius = Theme.radius.lg }),
		scope:New("UIStroke")({ Color = Theme.color.stroke, Transparency = 0.4 }),
		scope:New("UIScale")({
			Scale = scope:Computed(function(use)
				return 0.92 + 0.08 * use(alpha)
			end),
		}),
		scope:New("TextLabel")({
			Name = "Title",
			Position = UDim2.fromOffset(Theme.space.lg, Theme.space.md),
			Size = UDim2.new(1, -Theme.space.lg * 2 - Theme.minTouch, 0, Theme.minTouch),
			BackgroundTransparency = 1,
			Text = props.title,
			TextColor3 = Theme.color.text,
			TextSize = Theme.text.title,
			FontFace = Theme.font.bold,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		IconButton(scope, {
			name = "Close",
			icon = "X",
			tooltip = "Close (Backspace)",
			onClick = close,
			position = UDim2.new(1, -Theme.space.md, 0, Theme.space.md),
			anchorPoint = Vector2.new(1, 0),
		}),
		scope:New("Frame")({
			Name = "Body",
			Position = UDim2.fromOffset(Theme.space.lg, Theme.minTouch + Theme.space.lg),
			Size = UDim2.new(1, -Theme.space.lg * 2, 1, -(Theme.minTouch + Theme.space.lg * 2)),
			BackgroundTransparency = 1,
			[Children] = props.children,
		}),
	}

	local group = scope:New("CanvasGroup")({
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = props.size or UDim2.fromOffset(640, 440),
		BackgroundColor3 = Theme.color.surface,
		GroupTransparency = scope:Computed(function(use)
			return 1 - use(alpha)
		end),
		ZIndex = 21,
		[Children] = contents,
	}) :: CanvasGroup
	panel = group

	return scope:New("Frame")({
		Name = props.name or "Modal",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.overlay,
		BackgroundTransparency = scope:Computed(function(use)
			return 1 - 0.5 * use(alpha)
		end),
		-- Visible at once when opened (so its controls can take selection), and until faded out.
		Visible = scope:Computed(function(use)
			return use(props.open) or use(alpha) > 0.01
		end),
		Active = true,
		ZIndex = 20,
		[Children] = { group },
	}) :: Frame
end

return Modal
