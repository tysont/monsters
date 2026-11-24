--!strict
-- Renders server NPC rows: one local model per NPC, placed from packed snapshots
-- (Shared.Combat.NpcCodec) and interpolated 100 ms behind the server clock, with health bars.
-- Monsters (any kind with a Config.monsters definition) get a model sized from their definition,
-- show their state (telegraph glow, swing, stagger slump) and sink into the ground when they die.
-- Telegraphs and projectiles are drawn by MonsterFxController. Placeholder art (Phase 13
-- replaces it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local NpcCodec = require(ReplicatedStorage.Shared.Combat.NpcCodec)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

-- Render this far behind the newest snapshot time so there are two samples to blend.
local INTERPOLATION_DELAY = 0.1
local MAX_SAMPLES = 4
local SINK_SECONDS = 1.2

local S = NpcCodec.States

type Sample = { t: number, x: number, z: number, yaw: number, health: number, state: number, aux: number }

type Npc = {
	id: number,
	kind: string,
	team: number?,
	radius: number,
	maxHealth: number,
	model: Model,
	root: BasePart,
	height: number,
	bar: Frame,
	sword: BasePart?,
	eyes: BasePart?,
	samples: { Sample },
	position: Vector3,
	yaw: number,
	swingUntil: number,
	-- Latest interpolated values.
	health: number,
	state: number,
	aux: number,
	definition: Config.MonsterDefinition?,
	-- A pet (drawn small; no boss bar).
	pet: boolean,
	-- Server time it died (sinking), or nil.
	sinkingSince: number?,
}

local NpcRenderController = {
	name = "NpcRenderController",
}

local npcs: { [number]: Npc } = {}
-- Kind by NPC ID, kept after despawn so kill-feed names resolve for NPCs that are already gone.
local kinds: { [number]: string } = {}
local teamsById: { [number]: number? } = {}
local container: Folder

local EYE_IDLE = Color3.fromRGB(255, 230, 90)
local EYE_ANGRY = Color3.fromRGB(255, 60, 40)

local function teamColor(team: number?): Color3
	if team then
		for _, t in Teams:GetTeams() do
			if t:GetAttribute("TeamIndex") == team then
				return t.TeamColor.Color
			end
		end
	end
	return Color3.fromRGB(200, 60, 60)
end

local function part(name: string, size: Vector3, color: Color3, parent: Instance, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Material = Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function offsetPart(
	name: string,
	size: Vector3,
	color: Color3,
	parent: Instance,
	offset: CFrame,
	shape: Enum.PartType?
): Part
	local p = part(name, size, color, parent, shape)
	p:SetAttribute("Offset", offset)
	return p
end

local function healthBar(adornee: BasePart, height: number, width: number, maxDistance: number): Frame
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.fromOffset(width, 8)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height / 2 + 1.5, 0)
	gui.MaxDistance = maxDistance
	gui.Adornee = adornee
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	back.BorderSizePixel = 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(90, 220, 90)
	fill.BorderSizePixel = 0
	fill.Parent = back
	gui.Parent = adornee
	return fill
end

type Built = { root: BasePart, height: number, sword: BasePart?, eyes: BasePart? }

-- A blocky monster sized from its definition: body, head, glowing eyes, arms; guardians get a
-- team-coloured band and Titans a crown.
local function eyePart(model: Model, width: number, height: number, offset: CFrame): BasePart
	local e = offsetPart("Eyes", Vector3.new(width, height, 0.2), EYE_IDLE, model, offset)
	e.Material = Enum.Material.Neon
	return e
end

-- Jungle placeholder looks from the definition's `look`: blob, shell or worm.
local function lookModel(model: Model, def: Config.MonsterDefinition): Built?
	local look = def.look
	if look == nil or look.shape == "blocky" then
		return nil
	end
	local c = look.color
	local color = Color3.fromRGB(c[1], c[2], c[3])
	local dark = color:Lerp(Color3.new(0, 0, 0), 0.3)
	local r, h = def.radius, def.height
	if look.shape == "blob" then
		local size = r * 2
		local root = part("Body", Vector3.new(size, size, size), color, model, Enum.PartType.Ball)
		root.Material = Enum.Material.Glass
		root.Transparency = 0.15
		offsetPart("Core", Vector3.one * r, dark, model, CFrame.new(0, -r * 0.2, 0), Enum.PartType.Ball)
		local e = eyePart(model, r * 0.9, r * 0.25, CFrame.new(0, r * 0.3, -r * 0.92))
		return { root = root :: BasePart, height = size, sword = nil, eyes = e }
	elseif look.shape == "shell" then
		local bodyHeight = h * 0.45
		local root = part("Body", Vector3.new(r * 1.8, bodyHeight, r * 2.2), dark, model)
		local shell = offsetPart(
			"Shell",
			Vector3.new(r * 2.3, r * 2.3, r * 2.3),
			color,
			model,
			CFrame.new(0, bodyHeight * 0.45, r * 0.25),
			Enum.PartType.Ball
		)
		shell.Material = Enum.Material.Slate
		offsetPart("Head", Vector3.new(r * 0.9, bodyHeight * 0.8, r * 0.8), dark, model, CFrame.new(0, 0, -r * 1.3))
		local e = eyePart(model, r * 0.7, h * 0.06, CFrame.new(0, bodyHeight * 0.15, -r * 1.72))
		return { root = root :: BasePart, height = bodyHeight, sword = nil, eyes = e }
	end
	-- Worm: a tall body and a head segment with a glowing maw.
	local bodyHeight = h * 0.6
	local root = part("Body", Vector3.new(r * 1.6, bodyHeight, r * 1.6), color, model)
	offsetPart(
		"Head",
		Vector3.new(r * 1.9, r * 1.9, r * 1.9),
		dark,
		model,
		CFrame.new(0, bodyHeight / 2 + r * 0.6, -r * 0.3),
		Enum.PartType.Ball
	)
	local e = eyePart(model, r * 1.1, r * 0.35, CFrame.new(0, bodyHeight / 2 + r * 0.5, -r * 1.25))
	return { root = root :: BasePart, height = bodyHeight, sword = nil, eyes = e }
end

local function monsterModel(model: Model, kind: string, def: Config.MonsterDefinition, team: number?): Built
	local looked = lookModel(model, def)
	if looked then
		return looked
	end
	local r, h = def.radius, def.height
	local tint = if team then teamColor(team):Lerp(Color3.fromRGB(70, 70, 80), 0.45) else Color3.fromRGB(130, 70, 190)
	local bodyHeight = h * 0.7
	local root = part("Body", Vector3.new(r * 1.9, bodyHeight, r * 1.5), tint, model)
	local top = bodyHeight / 2
	offsetPart(
		"Head",
		Vector3.new(r * 1.2, h * 0.24, r * 1.1),
		tint:Lerp(Color3.new(0, 0, 0), 0.15),
		model,
		CFrame.new(0, top + h * 0.12, -r * 0.15)
	)
	local eyes = offsetPart(
		"Eyes",
		Vector3.new(r * 0.9, h * 0.05, 0.2),
		EYE_IDLE,
		model,
		CFrame.new(0, top + h * 0.14, -r * 0.7 - 0.1)
	)
	eyes.Material = Enum.Material.Neon
	for side = -1, 1, 2 do
		offsetPart(
			if side < 0 then "ArmL" else "ArmR",
			Vector3.new(r * 0.5, bodyHeight * 0.8, r * 0.5),
			tint:Lerp(Color3.new(0, 0, 0), 0.25),
			model,
			CFrame.new(side * r * 1.2, -bodyHeight * 0.05, 0)
		)
	end
	if team then
		local band = offsetPart(
			"Band",
			Vector3.new(r * 1.9 + 0.2, h * 0.05, r * 1.5 + 0.2),
			teamColor(team),
			model,
			CFrame.new(0, -bodyHeight * 0.15, 0)
		)
		band.Material = Enum.Material.Neon
	end
	if kind == "titan" then
		for i = -1, 1 do
			local spike = offsetPart(
				"Crown",
				Vector3.new(r * 0.25, h * 0.12, r * 0.25),
				Color3.fromRGB(255, 210, 80),
				model,
				CFrame.new(i * r * 0.4, top + h * 0.3, -r * 0.15)
			)
			spike.Material = Enum.Material.Neon
		end
	end
	return { root = root, height = bodyHeight, sword = nil, eyes = eyes }
end

-- The monster definition for a spawn, resized for its scale (pets are smaller) and recoloured
-- for a pet skin.
local function definitionFor(event: Remotes.NpcSpawnEvent): Config.MonsterDefinition?
	local def = Config.get().monsters[event.kind]
	local scale = event.scale
	local tint = event.tint
	if def == nil or ((scale == nil or scale == 1) and tint == nil) then
		return def
	end
	local resized = table.clone(def)
	resized.radius = def.radius * (scale or 1)
	resized.height = def.height * (scale or 1)
	if tint then
		-- Pet skin: same shape, the skin's colour.
		local color = { bit32.rshift(tint, 16) % 256, bit32.rshift(tint, 8) % 256, tint % 256 }
		local look = def.look
		resized.look = { shape = if look then look.shape else "blocky", color = color }
	end
	return resized
end

local function buildModel(event: Remotes.NpcSpawnEvent): Built
	local model = Instance.new("Model")
	model.Name = `{event.kind}_{event.id}`
	local built: Built
	local def = definitionFor(event)
	if def then
		built = monsterModel(model, event.kind, def, event.team)
	elseif event.kind == "dummy" then
		built = { root = part("Body", Vector3.new(4, 6, 4), Color3.fromRGB(190, 160, 110), model), height = 6 }
	elseif event.kind == "weak" then
		built = {
			root = part("Body", Vector3.new(3, 3, 3), Color3.fromRGB(230, 110, 60), model, Enum.PartType.Ball),
			height = 3,
		}
	else -- bot
		local height = 5
		local root = part("Body", Vector3.new(2, height, 1.2), teamColor(event.team), model)
		offsetPart(
			"Head",
			Vector3.new(1.6, 1.6, 1.6),
			Color3.fromRGB(240, 220, 190),
			model,
			CFrame.new(0, height / 2 + 0.8, 0),
			Enum.PartType.Ball
		)
		local blade = offsetPart(
			"Sword",
			Vector3.new(0.25, 0.25, 4),
			Color3.fromRGB(200, 205, 215),
			model,
			CFrame.new(1.2, 0, -2)
		)
		blade.Material = Enum.Material.Metal
		built = { root = root, height = height, sword = blade }
	end
	model.PrimaryPart = built.root
	model.Parent = container
	return built
end

local function place(npc: Npc, x: number, z: number, yaw: number)
	local sink = 0
	if npc.sinkingSince then
		sink = math.clamp((workspace:GetServerTimeNow() - (npc.sinkingSince :: number)) / SINK_SECONDS, 0, 1)
	elseif npc.state == S.hidden then
		-- Burrowed: fully underground.
		sink = 1
	end
	local tilt = CFrame.identity
	if npc.definition then
		if npc.state == S.stagger then
			tilt = CFrame.Angles(math.rad(-14), 0, math.rad(6))
		elseif npc.state == S.telegraph then
			-- Wind-up: lean back.
			tilt = CFrame.Angles(math.rad(8), 0, 0)
		elseif npc.state == S.attack then
			tilt = CFrame.Angles(math.rad(-10), 0, 0)
		end
	end
	local depth = (npc.height + (if npc.definition then npc.definition.height else 0)) * 1.1
	local base = CFrame.new(x, npc.height / 2 - sink * depth, z) * CFrame.Angles(0, yaw, 0) * tilt
	npc.root.CFrame = base
	npc.position = Vector3.new(x, npc.height / 2, z)
	npc.yaw = yaw
	local swinging = os.clock() < npc.swingUntil
	for _, child in npc.model:GetChildren() do
		if child:IsA("BasePart") and child ~= npc.root then
			local offset = child:GetAttribute("Offset")
			if typeof(offset) == "CFrame" then
				local o = offset
				if child == npc.sword and swinging then
					-- Swing the bot's sword across its front.
					local p = 1 - (npc.swingUntil - os.clock()) / 0.25
					o = CFrame.new(0, 0.5, 0) * CFrame.Angles(0, (0.5 - p) * 2.4, 0) * CFrame.new(0, 0, -2.2)
				elseif npc.definition and (child.Name == "ArmL" or child.Name == "ArmR") then
					if npc.state == S.telegraph then
						-- Arms raised.
						o = o * CFrame.new(0, npc.height * 0.25, 0) * CFrame.Angles(math.rad(-60), 0, 0)
					elseif npc.state == S.attack then
						o = o * CFrame.new(0, 0, -npc.radius * 0.6) * CFrame.Angles(math.rad(-90), 0, 0)
					end
				end
				child.CFrame = base * o
			end
		end
	end
	if npc.eyes then
		local angry = npc.state == S.telegraph or npc.state == S.attack
		npc.eyes.Color = if npc.state == S.stagger
			then Color3.fromRGB(90, 90, 110)
			elseif angry then EYE_ANGRY
			else EYE_IDLE
	end
end

local function onSpawn(event: Remotes.NpcSpawnEvent)
	if npcs[event.id] then
		return
	end
	local built = buildModel(event)
	local def = definitionFor(event)
	local npc: Npc = {
		id = event.id,
		kind = event.kind,
		team = event.team,
		radius = event.radius,
		maxHealth = event.maxHealth,
		model = built.root.Parent :: Model,
		root = built.root,
		height = built.height,
		bar = healthBar(
			built.root,
			built.height + (if def then def.height * 0.6 else 0),
			if def then 120 else 60,
			if def then 250 else 150
		),
		sword = built.sword,
		eyes = built.eyes,
		samples = {},
		position = Vector3.zero,
		yaw = 0,
		swingUntil = 0,
		health = 1,
		state = 0,
		aux = 0,
		definition = def,
		sinkingSince = nil,
		pet = event.scale ~= nil and event.scale < 1,
	}
	npcs[event.id] = npc
	if npc.pet then
		-- Pets cannot be hurt: no health bar.
		local gui = (npc.bar.Parent :: Instance).Parent :: BillboardGui
		gui.Enabled = false
	end
	kinds[event.id] = event.kind
	teamsById[event.id] = event.team
end

local function onDespawn(id: number)
	local npc = npcs[id]
	if npc == nil then
		return
	end
	npcs[id] = nil
	if npc.definition and npc.health <= 0.001 then
		-- Defeated monsters sink into the ground.
		npc.sinkingSince = workspace:GetServerTimeNow()
		local gui = (npc.bar.Parent :: Instance).Parent :: BillboardGui
		gui.Enabled = false
		local x, z, yaw = npc.position.X, npc.position.Z, npc.yaw
		local connection: RBXScriptConnection
		connection = RunService.RenderStepped:Connect(function()
			place(npc, x, z, yaw)
			if workspace:GetServerTimeNow() - (npc.sinkingSince :: number) >= SINK_SECONDS then
				connection:Disconnect()
				npc.model:Destroy()
			end
		end)
	else
		npc.model:Destroy()
	end
end

local function onSnapshot(chunk: buffer)
	local time, entities = NpcCodec.unpack(chunk)
	if time == nil or entities == nil then
		return
	end
	for _, e in entities do
		local npc = npcs[e.id]
		if npc then
			local samples = npc.samples
			local newest = samples[#samples]
			if newest == nil or time > newest.t then
				table.insert(samples, {
					t = time,
					x = e.x,
					z = e.z,
					yaw = e.yaw,
					health = e.health,
					state = e.state,
					aux = e.aux or 0,
				})
				if #samples > MAX_SAMPLES then
					table.remove(samples, 1)
				end
			end
		end
	end
end

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function render()
	local renderTime = workspace:GetServerTimeNow() - INTERPOLATION_DELAY
	for _, npc in npcs do
		local samples = npc.samples
		local count = #samples
		if count > 0 then
			local a, b = samples[1], samples[count]
			for i = 1, count - 1 do
				if samples[i].t <= renderTime and samples[i + 1].t >= renderTime then
					a, b = samples[i], samples[i + 1]
					break
				end
			end
			local alpha = 1
			if b.t > a.t then
				alpha = math.clamp((renderTime - a.t) / (b.t - a.t), 0, 1)
			end
			if renderTime >= samples[count].t then
				a, b, alpha = samples[count], samples[count], 1
			end
			npc.health, npc.state, npc.aux = b.health, b.state, b.aux
			place(npc, a.x + (b.x - a.x) * alpha, a.z + (b.z - a.z) * alpha, lerpAngle(a.yaw, b.yaw, alpha))
			npc.bar.Size = UDim2.fromScale(b.health, 1)
		end
	end
end

-- Public API for other controllers ----------------------------------------------------------

export type Target = { id: number, position: Vector3, radius: number, team: number?, model: Model }

-- Rendered NPCs as combat targets. `id` is the combatant ID (negative NPC ID).
function NpcRenderController.targets(): { Target }
	local list: { Target } = {}
	for id, npc in npcs do
		table.insert(
			list,
			{ id = -id, position = npc.position, radius = npc.radius, team = npc.team, model = npc.model }
		)
	end
	return list
end

export type MonsterInfo = {
	-- NPC ID.
	id: number,
	kind: string,
	team: number?,
	position: Vector3,
	radius: number,
	health: number,
	maxHealth: number,
	-- Stagger bar (0 to 1) and whether it is staggered now.
	stagger: number,
	staggered: boolean,
	definition: Config.MonsterDefinition,
}

-- The nearest living monster within `range` of `position` (edge distance), or nil.
function NpcRenderController.monsterNear(position: Vector3, range: number): MonsterInfo?
	local best: Npc? = nil
	local bestDistance = math.huge
	for _, npc in npcs do
		if npc.definition and npc.health > 0 and not npc.pet then
			local d = (Vector3.new(npc.position.X, 0, npc.position.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
				- npc.radius
			if d <= range and d < bestDistance then
				best, bestDistance = npc, d
			end
		end
	end
	if best == nil then
		return nil
	end
	local npc = best :: Npc
	return {
		id = npc.id,
		kind = npc.kind,
		team = npc.team,
		position = npc.position,
		radius = npc.radius,
		health = npc.health,
		maxHealth = npc.maxHealth,
		stagger = npc.aux,
		staggered = npc.state == S.stagger,
		definition = npc.definition :: Config.MonsterDefinition,
	}
end

-- Position of an NPC by NPC ID, if rendered.
function NpcRenderController.positionOf(npcId: number): Vector3?
	local npc = npcs[npcId]
	return npc and npc.position
end

-- Team of an NPC by NPC ID (kept after despawn).
function NpcRenderController.teamOf(npcId: number): number?
	return teamsById[npcId]
end

function NpcRenderController.model(combatantId: number): Model?
	local npc = npcs[-combatantId]
	return npc and npc.model
end

function NpcRenderController.kindOf(combatantId: number): string?
	return kinds[-combatantId]
end

function NpcRenderController.playSwing(combatantId: number)
	local npc = npcs[-combatantId]
	if npc then
		npc.swingUntil = os.clock() + 0.25
	end
end

function NpcRenderController.start(_self: typeof(NpcRenderController))
	local folder = Instance.new("Folder")
	folder.Name = "NpcModels"
	folder.Parent = workspace
	container = folder

	Net.onClientEvent(Remotes.NpcSpawn, onSpawn)
	Net.onClientEvent(Remotes.NpcDespawn, onDespawn)
	Net.onClientEvent(Remotes.NpcSnapshot, onSnapshot)
	RunService.RenderStepped:Connect(render)
	Net.fireServer(Remotes.NpcReady, nil)
end

return NpcRenderController
