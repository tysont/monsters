--!strict
-- A circular cooldown sweep. `remaining` is the fraction of the cooldown left (1 = just used,
-- 0 = ready). Built from two clipped half-discs whose gradients rotate, so it needs no images.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

export type Props = {
	remaining: Fusion.UsedAs<number>,
	size: number?,
	color: Color3?,
	position: UDim2?,
	anchorPoint: Vector2?,
	zIndex: number?,
}

-- Opaque on one side of the gradient, transparent on the other, with a hard edge.
local HALF = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.4999, 0),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(1, 1),
})

local function CooldownRing(scope: UiState.Scope, props: Props): Frame
	local size = props.size or 56
	local color = props.color or Theme.color.overlay

	-- The dark sweep starts at 12 o'clock and runs clockwise over `remaining` of the circle.
	-- Each half-disc shows the part of an opaque half-plane (the gradient) on its side: the right
	-- half covers the first 180 degrees (gradient rotation 0 to 180), the left half the rest
	-- (rotation 180 to 360).
	local function half(side: "Left" | "Right"): Frame
		local isRight = side == "Right"
		local rotation = scope:Computed(function(use)
			local degrees = math.clamp(use(props.remaining), 0, 1) * 360
			if isRight then
				return math.clamp(degrees, 0, 180)
			end
			return 180 + math.clamp(degrees - 180, 0, 180)
		end)
		return scope:New("Frame")({
			Name = side,
			Size = UDim2.fromScale(0.5, 1),
			Position = if isRight then UDim2.fromScale(0.5, 0) else UDim2.fromScale(0, 0),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			ZIndex = props.zIndex,
			[Children] = {
				scope:New("Frame")({
					Size = UDim2.fromScale(2, 1),
					Position = if isRight then UDim2.fromScale(-1, 0) else UDim2.fromScale(0, 0),
					BackgroundColor3 = color,
					BackgroundTransparency = 0.35,
					ZIndex = props.zIndex,
					[Children] = {
						scope:New("UICorner")({ CornerRadius = Theme.radius.pill }),
						scope:New("UIGradient")({
							Transparency = HALF,
							Rotation = rotation,
						}),
					},
				}),
			},
		}) :: Frame
	end

	return scope:New("Frame")({
		Name = "CooldownRing",
		Size = UDim2.fromOffset(size, size),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		BackgroundTransparency = 1,
		ZIndex = props.zIndex,
		Visible = scope:Computed(function(use)
			return use(props.remaining) > 0.001
		end),
		[Children] = { half("Left"), half("Right") },
	}) :: Frame
end

return CooldownRing
