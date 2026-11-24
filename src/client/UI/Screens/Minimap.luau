--!strict
-- Minimap v1: lanes, bases and teammates (you in white). Static geometry is built once from
-- Shared.Map; only the dots change, at the HUD refresh rate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local LanePath = require(ReplicatedStorage.Shared.Map.LanePath)
local Map = require(ReplicatedStorage.Shared.Map)

local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

-- Teammates shown at once (a full team of 20, with room to spare).
local MAX_DOTS = 24

-- A player: you (white), a teammate (blue), carrying an egg (gold), or an enemy egg carrier
-- seen by your team (red).
export type Dot = { id: number, x: number, z: number, me: boolean, carrier: boolean?, enemy: boolean? }

-- Front of a minion wave: `front` is progress from the owning team's base (0) to the enemy (1).
export type Wave = { lane: string, team: number, count: number, front: number }

-- A guardian or Titan: health 0 to 1, destroyed, or locked by lane gating.
export type StructureInfo = {
	key: string,
	kind: string,
	team: number,
	lane: string?,
	x: number,
	z: number,
	health: number,
	dead: boolean,
	locked: boolean,
}

-- A jungle camp: alive, or seconds until it respawns.
export type CampInfo = {
	x: number,
	z: number,
	tier: number,
	alive: boolean,
	respawnIn: number,
}

export type Props = {
	dots: Fusion.UsedAs<{ Dot }>,
	waves: Fusion.UsedAs<{ Wave }>?,
	structures: Fusion.UsedAs<{ StructureInfo }>?,
	camps: Fusion.UsedAs<{ CampInfo }>?,
	width: number,
	position: UDim2?,
	anchorPoint: Vector2?,
	teamColors: { Color3 },
}

local function Minimap(scope: UiState.Scope, props: Props): Frame
	local map = Map.get()
	local width = props.width
	local height = width * map.halfDepth / map.halfWidth
	local function toMap(x: number, z: number): UDim2
		return UDim2.fromOffset(
			(x + map.halfWidth) / (2 * map.halfWidth) * width,
			(z + map.halfDepth) / (2 * map.halfDepth) * height
		)
	end
	local s = width / (2 * map.halfWidth)

	local children: { Fusion.Child } = {
		scope:New("UICorner")({ CornerRadius = Theme.radius.md }),
		scope:New("UIStroke")({ Color = Theme.color.stroke, Transparency = 0.4 }),
	}
	for team = 1, 2 do
		local base = map.bases[team]
		table.insert(
			children,
			scope:New("Frame")({
				Name = `Base{team}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = toMap(base.center.x, base.center.z),
				Size = UDim2.fromOffset(base.size.x * s, base.size.z * s),
				BackgroundColor3 = props.teamColors[team],
				BackgroundTransparency = 0.45,
				BorderSizePixel = 0,
			})
		)
	end
	for _, lane in map.lanes do
		local points = lane.path.points
		for i = 1, #points - 1 do
			local a, b = points[i], points[i + 1]
			local dx, dz = b.x - a.x, b.z - a.z
			local length = math.sqrt(dx * dx + dz * dz) * s
			table.insert(
				children,
				scope:New("Frame")({
					Name = `{lane.id}{i}`,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = toMap((a.x + b.x) / 2, (a.z + b.z) / 2),
					Size = UDim2.fromOffset(length + 3, 3),
					Rotation = math.deg(math.atan2(dz, dx)),
					BackgroundColor3 = Theme.color.textMuted,
					BackgroundTransparency = 0.3,
					BorderSizePixel = 0,
				})
			)
		end
	end
	-- Wave fronts: one marker per lane and team (fixed pool), sized by how many minions remain.
	local waves = props.waves or {}
	for i = 1, 6 do
		local wave = scope:Computed(function(use)
			return use(waves)[i]
		end)
		table.insert(
			children,
			scope:New("Frame")({
				Name = `Wave{i}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = 45,
				Visible = scope:Computed(function(use)
					local w = use(wave)
					return w ~= nil and w.count > 0
				end),
				Position = scope:Computed(function(use)
					local w = use(wave)
					if w == nil then
						return UDim2.new()
					end
					local path = map.laneById[w.lane :: Map.LaneId]
					local progress = if w.team == 1 then w.front else 1 - w.front
					local p = LanePath.pointAtProgress(path, progress)
					return toMap(p.x, p.z)
				end),
				Size = scope:Computed(function(use)
					local w = use(wave)
					local markerSize = if w then math.clamp(5 + w.count * 0.4, 6, 14) else 6
					return UDim2.fromOffset(markerSize, markerSize)
				end),
				BackgroundColor3 = scope:Computed(function(use)
					local w = use(wave)
					return if w then props.teamColors[w.team] or Theme.color.text else Theme.color.text
				end),
				BorderSizePixel = 0,
				ZIndex = 2,
				[Children] = {
					scope:New("UIStroke")({ Color = Color3.new(1, 1, 1), Thickness = 1, Transparency = 0.3 }),
				},
			})
		)
	end

	-- Jungle camps: a purple dot (bigger for harder tiers) while alive, grey with the seconds
	-- left while respawning.
	local camps = props.camps or {}
	for i = 1, 12 do
		local info = scope:Computed(function(use)
			return use(camps)[i]
		end)
		table.insert(
			children,
			scope:New("Frame")({
				Name = `Camp{i}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Visible = scope:Computed(function(use)
					return use(info) ~= nil
				end),
				Position = scope:Computed(function(use)
					local c: CampInfo? = use(info)
					return if c then toMap(c.x, c.z) else UDim2.new()
				end),
				Size = scope:Computed(function(use)
					local c: CampInfo? = use(info)
					local size = if c then 4 + c.tier * 1.5 else 5
					return UDim2.fromOffset(size, size)
				end),
				BackgroundColor3 = scope:Computed(function(use)
					local c: CampInfo? = use(info)
					return if c and c.alive then Theme.color.epic else Color3.fromRGB(90, 90, 96)
				end),
				BorderSizePixel = 0,
				ZIndex = 2,
				[Children] = {
					scope:New("UICorner")({ CornerRadius = Theme.radius.pill }),
					scope:New("TextLabel")({
						Name = "Respawn",
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.fromScale(0.5, 0),
						Size = UDim2.fromOffset(24, 10),
						BackgroundTransparency = 1,
						TextColor3 = Theme.color.textMuted,
						TextSize = 9,
						FontFace = Theme.font.bold,
						Text = scope:Computed(function(use)
							local c: CampInfo? = use(info)
							return if c and not c.alive then tostring(math.max(0, math.ceil(c.respawnIn))) else ""
						end),
					}),
				},
			})
		)
	end

	-- Lane status: one icon per guardian and Titan (fixed positions; only colour changes).
	local structures = props.structures or {}
	for i = 1, 14 do
		local info = scope:Computed(function(use)
			return use(structures)[i]
		end)
		table.insert(
			children,
			scope:New("Frame")({
				Name = `Structure{i}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Visible = scope:Computed(function(use)
					return use(info) ~= nil
				end),
				Position = scope:Computed(function(use)
					local item = use(info)
					return if item then toMap(item.x, item.z) else UDim2.new()
				end),
				Size = scope:Computed(function(use)
					local item = use(info)
					local size = if item and item.kind == "titan" then 11 else 7
					return UDim2.fromOffset(size, size)
				end),
				BackgroundColor3 = scope:Computed(function(use)
					local item = use(info)
					if item == nil or item.dead then
						return Color3.fromRGB(60, 60, 66)
					end
					return props.teamColors[item.team] or Theme.color.text
				end),
				BackgroundTransparency = scope:Computed(function(use)
					local item = use(info)
					return if item and item.locked then 0.45 else 0
				end),
				BorderSizePixel = 0,
				ZIndex = 3,
				[Children] = {
					scope:New("UIStroke")({
						Color = scope:Computed(function(use)
							local item = use(info)
							return if item and item.dead then Theme.color.danger else Color3.new(1, 1, 1)
						end),
						Thickness = 1,
						Transparency = 0.2,
					}),
				},
			})
		)
	end

	-- A fixed pool of dot frames; updates only move and show/hide them (no instance churn).
	for i = 1, MAX_DOTS do
		local dot = scope:Computed(function(use)
			return use(props.dots)[i]
		end)
		table.insert(
			children,
			scope:New("Frame")({
				Name = `Dot{i}`,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Visible = scope:Computed(function(use)
					return use(dot) ~= nil
				end),
				Position = scope:Computed(function(use)
					local d = use(dot)
					return if d then toMap(d.x, d.z) else UDim2.new()
				end),
				Size = scope:Computed(function(use)
					local d = use(dot)
					return if d and (d.me or d.carrier) then UDim2.fromOffset(9, 9) else UDim2.fromOffset(6, 6)
				end),
				BackgroundColor3 = scope:Computed(function(use)
					local d = use(dot)
					if d and d.enemy then
						return Theme.color.danger
					elseif d and d.carrier then
						return Theme.color.warning
					end
					return if d and d.me then Color3.new(1, 1, 1) else Theme.color.info
				end),
				ZIndex = 2,
				[Children] = { scope:New("UICorner")({ CornerRadius = Theme.radius.pill }) },
			})
		)
	end

	return scope:New("Frame")({
		Name = "Minimap",
		Size = UDim2.fromOffset(width, height),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		BackgroundColor3 = Theme.color.background,
		BackgroundTransparency = 0.25,
		ClipsDescendants = true,
		[Children] = children,
	}) :: Frame
end

return Minimap
