--!strict
-- Renders minions from interest-filtered snapshots (Shared.Combat.MinionCodec).
--
--   Models come from pools per kind and level of detail, coloured per team, and are reused;
--   nothing is created per frame once the pools are warm.
--   Positions are interpolated 100 ms behind the server clock.
--   Level of detail by distance from the camera: full model (with health bar when damaged)
--   within FULL_DISTANCE, a single block up to SIMPLE_DISTANCE, hidden beyond (the minimap
--   shows waves).
--   Dying minions shrink and fade; minions not heard from for STALE_SECONDS (left the interest
--   area) are released.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MinionCodec = require(ReplicatedStorage.Shared.Combat.MinionCodec)
local Minions = require(ReplicatedStorage.Shared.Combat.Minions)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Theme = require("../UI/Theme")

local INTERPOLATION_DELAY = 0.1
local MAX_SAMPLES = 4
local STALE_SECONDS = 2.5
local DEATH_SECONDS = 0.5
local FULL_DISTANCE = 120
local SIMPLE_DISTANCE = 250
local HEIGHT = 3

type Lod = "full" | "simple" | "hidden"
type Sample = { t: number, x: number, z: number, yaw: number, health: number, state: number }

type Visual = {
	model: Model,
	root: BasePart,
	parts: { BasePart },
	bar: Frame?,
	barGui: BillboardGui?,
	key: string,
}

type Minion = {
	id: number,
	kind: number,
	team: number,
	samples: { Sample },
	seenAt: number,
	visual: Visual?,
	lod: Lod,
	deadAt: number?,
	position: Vector3,
	health: number,
}

local MinionRenderController = {
	name = "MinionRenderController",
	-- Live counts for the debug overlay.
	stats = { minions = 0, full = 0, simple = 0 },
}

local minions: { [number]: Minion } = {}
local pools: { [string]: { Visual } } = {}
local container: Folder

local TEAM_COLORS = { Theme.color.team1, Theme.color.team2 }

local function newPart(name: string, size: Vector3, color: Color3, parent: Instance, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function buildVisual(kind: number, team: number, lod: Lod): Visual
	local color = TEAM_COLORS[team] or Theme.color.textMuted
	local model = Instance.new("Model")
	model.Name = `minion_{Minions.KIND_NAMES[kind]}_{lod}`
	local parts: { BasePart } = {}
	local root: BasePart
	local bar: Frame? = nil
	local barGui: BillboardGui? = nil
	local siege = Minions.KIND_NAMES[kind] == "siege"
	if siege then
		-- Siege minions (late in a round): a heavy block with a ram.
		local dark = color:Lerp(Color3.new(0, 0, 0), 0.35)
		root = newPart("Body", Vector3.new(3.2, HEIGHT, 3.2), dark, model)
		table.insert(parts, root)
		if lod ~= "simple" then
			local ram = newPart("Ram", Vector3.new(1.2, 1.2, 2.6), Color3.fromRGB(120, 90, 60), model)
			ram:SetAttribute("Offset", CFrame.new(0, 0, -2.6))
			table.insert(parts, ram)
		end
	elseif lod == "simple" then
		root = newPart("Body", Vector3.new(1.8, HEIGHT, 1.8), color, model)
		table.insert(parts, root)
	else
		local ranged = Minions.KIND_NAMES[kind] == "ranged"
		root = newPart("Body", Vector3.new(1.8, HEIGHT - 0.6, 1.4), color, model)
		local head = newPart(
			"Head",
			Vector3.new(1.4, 1.4, 1.4),
			color:Lerp(Color3.new(1, 1, 1), 0.35),
			model,
			Enum.PartType.Ball
		)
		head:SetAttribute("Offset", CFrame.new(0, (HEIGHT - 0.6) / 2 + 0.6, 0))
		local weapon = if ranged
			then newPart("Staff", Vector3.new(0.2, 2.6, 0.2), Color3.fromRGB(150, 110, 70), model)
			else newPart("Blade", Vector3.new(0.18, 0.18, 2), Color3.fromRGB(200, 205, 215), model)
		weapon:SetAttribute("Offset", if ranged then CFrame.new(0.9, 0.3, 0) else CFrame.new(0.9, 0, -1))
		table.insert(parts, root)
		table.insert(parts, head)
		table.insert(parts, weapon)

		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(36, 5)
		gui.StudsOffsetWorldSpace = Vector3.new(0, HEIGHT / 2 + 1.4, 0)
		gui.MaxDistance = 60
		gui.Adornee = root
		gui.Enabled = false
		local back = Instance.new("Frame")
		back.Size = UDim2.fromScale(1, 1)
		back.BorderSizePixel = 0
		back.BackgroundColor3 = Theme.color.background
		back.Parent = gui
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(1, 1)
		fill.BorderSizePixel = 0
		fill.BackgroundColor3 = color:Lerp(Color3.new(1, 1, 1), 0.2)
		fill.Parent = back
		gui.Parent = root
		bar = fill
		barGui = gui
	end
	model.PrimaryPart = root
	return { model = model, root = root, parts = parts, bar = bar, barGui = barGui, key = `{kind}:{team}:{lod}` }
end

local function acquire(kind: number, team: number, lod: Lod): Visual
	local key = `{kind}:{team}:{lod}`
	local pool = pools[key]
	local visual = if pool then table.remove(pool) else nil
	if visual == nil then
		visual = buildVisual(kind, team, lod)
	end
	local v = visual :: Visual
	for _, part in v.parts do
		part.Transparency = 0
		part:SetAttribute("Shrink", nil)
	end
	v.model.Parent = container
	return v
end

local function release(visual: Visual)
	visual.model.Parent = nil
	local highlight = visual.model:FindFirstChild("HitFlash")
	if highlight and highlight:IsA("Highlight") then
		highlight.Enabled = false
	end
	local pool = pools[visual.key]
	if pool == nil then
		pool = {}
		pools[visual.key] = pool
	end
	table.insert(pool, visual)
end

local function drop(id: number)
	local m = minions[id]
	if m then
		if m.visual then
			release(m.visual)
		end
		minions[id] = nil
	end
end

local function onSnapshot(chunk: buffer)
	local time, entities = MinionCodec.unpack(chunk)
	if time == nil or entities == nil then
		return
	end
	local clock = os.clock()
	for _, e in entities do
		local m: Minion? = minions[e.id]
		-- A reused ID with a different kind or team is a new minion.
		if m and (m.kind ~= e.kind or m.team ~= e.team) then
			drop(e.id)
			m = nil
		end
		if m == nil then
			local created: Minion = {
				id = e.id,
				kind = e.kind,
				team = e.team,
				samples = {},
				seenAt = clock,
				visual = nil,
				lod = "hidden",
				deadAt = nil,
				position = Vector3.new(e.x, HEIGHT / 2, e.z),
				health = e.health,
			}
			minions[e.id] = created
			m = created
		end
		local minion = m :: Minion
		minion.seenAt = clock
		local samples = minion.samples
		local newest = samples[#samples]
		if newest == nil or time > newest.t then
			table.insert(samples, { t = time, x = e.x, z = e.z, yaw = e.yaw, health = e.health, state = e.state })
			if #samples > MAX_SAMPLES then
				table.remove(samples, 1)
			end
		end
		if e.state == MinionCodec.States.dead and minion.deadAt == nil then
			minion.deadAt = clock
		end
	end
end

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function placeVisual(visual: Visual, cframe: CFrame)
	visual.root.CFrame = cframe
	for _, part in visual.parts do
		if part ~= visual.root then
			local offset = part:GetAttribute("Offset")
			if typeof(offset) == "CFrame" then
				part.CFrame = cframe * offset
			end
		end
	end
end

local function render()
	local clock = os.clock()
	local renderTime = workspace:GetServerTimeNow() - INTERPOLATION_DELAY
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	local full, simple, count = 0, 0, 0
	for id, m in minions do
		local dead = m.deadAt
		if clock - m.seenAt > STALE_SECONDS or (dead and clock - dead > DEATH_SECONDS) then
			drop(id)
			continue
		end
		count += 1
		local samples = m.samples
		local n = #samples
		if n == 0 then
			continue
		end
		local a, b, alpha = samples[n], samples[n], 1
		for i = 1, n - 1 do
			if samples[i].t <= renderTime and samples[i + 1].t >= renderTime then
				a, b = samples[i], samples[i + 1]
				alpha = if b.t > a.t then (renderTime - a.t) / (b.t - a.t) else 1
				break
			end
		end
		local x = a.x + (b.x - a.x) * alpha
		local z = a.z + (b.z - a.z) * alpha
		local yaw = lerpAngle(a.yaw, b.yaw, alpha)
		m.position = Vector3.new(x, HEIGHT / 2, z)
		m.health = b.health

		local distance = (m.position - eye).Magnitude
		local lod: Lod = if distance < FULL_DISTANCE
			then "full"
			elseif distance < SIMPLE_DISTANCE then "simple"
			else "hidden"
		if lod ~= m.lod then
			if m.visual then
				release(m.visual)
				m.visual = nil
			end
			if lod ~= "hidden" then
				m.visual = acquire(m.kind, m.team, lod)
			end
			m.lod = lod
		end
		local visual = m.visual
		if visual then
			if lod == "full" then
				full += 1
			else
				simple += 1
			end
			-- Fighting minions bob; dying ones shrink and fade.
			local lift = 0
			if b.state == MinionCodec.States.fight then
				lift = math.abs(math.sin(clock * 9 + id)) * 0.4
			end
			local cframe = CFrame.new(x, HEIGHT / 2 + lift, z) * CFrame.Angles(0, yaw, 0)
			if dead then
				local p = math.clamp((clock - dead) / DEATH_SECONDS, 0, 1)
				cframe = CFrame.new(x, HEIGHT / 2 * (1 - p), z) * CFrame.Angles(0, yaw, 0)
				for _, part in visual.parts do
					part.Transparency = p
				end
			end
			placeVisual(visual, cframe)
			local barGui = visual.barGui
			local bar = visual.bar
			if barGui and bar then
				local damaged = m.health < 0.999 and dead == nil
				barGui.Enabled = damaged
				if damaged then
					bar.Size = UDim2.fromScale(m.health, 1)
				end
			end
		end
	end
	local stats = MinionRenderController.stats
	stats.minions, stats.full, stats.simple = count, full, simple
end

-- Public API for other controllers ----------------------------------------------------------

export type Target = { id: number, position: Vector3, radius: number, team: number, model: Model? }

-- Living minions within `range` of `origin`, as combat targets (combatant IDs).
function MinionRenderController.targetsNear(origin: Vector3, range: number): { Target }
	local list: { Target } = {}
	for id, m in minions do
		if m.deadAt == nil and (m.position - origin).Magnitude <= range then
			table.insert(list, {
				id = Minions.combatantId(id),
				position = m.position,
				radius = 1.4,
				team = m.team,
				model = if m.visual then m.visual.model else nil,
			})
		end
	end
	return list
end

-- The model drawn for a minion combatant ID (nil when hidden by distance or unknown).
function MinionRenderController.model(combatantId: number): Model?
	local id = Minions.networkId(combatantId)
	local m = if id then minions[id] else nil
	return if m and m.visual then m.visual.model else nil
end

-- Display name for a minion combatant ID (nil if not a minion).
function MinionRenderController.nameOf(combatantId: number): string?
	local id = Minions.networkId(combatantId)
	if id == nil then
		return nil
	end
	local m = minions[id]
	local kind = if m then Minions.KIND_NAMES[m.kind] else nil
	return if kind == "ranged" then "Ranged minion" elseif kind == "siege" then "Siege minion" else "Minion"
end

function MinionRenderController.start(_self: typeof(MinionRenderController))
	local folder = Instance.new("Folder")
	folder.Name = "MinionModels"
	folder.Parent = workspace
	container = folder
	Net.onClientEvent(Remotes.MinionSnapshot, onSnapshot)
	RunService.RenderStepped:Connect(render)
end

return MinionRenderController
