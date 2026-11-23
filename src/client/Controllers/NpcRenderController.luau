--!strict
-- Renders server NPC rows: one local model per NPC, placed from packed snapshots
-- (Shared.Combat.NpcCodec) and interpolated 100 ms behind the server clock. Draws health bars,
-- telegraph circles and impacts. Placeholder art (Phase 13 replaces it).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local NpcCodec = require(ReplicatedStorage.Shared.Combat.NpcCodec)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Feedback = require("../Feedback")

-- Render this far behind the newest snapshot time so there are two samples to blend.
local INTERPOLATION_DELAY = 0.1
local MAX_SAMPLES = 4

type Sample = { t: number, x: number, z: number, yaw: number, health: number, state: number }

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
	samples: { Sample },
	position: Vector3,
	swingUntil: number,
}

local NpcRenderController = {
	name = "NpcRenderController",
}

local npcs: { [number]: Npc } = {}
-- Kind by NPC ID, kept after despawn so kill-feed names resolve for NPCs that are already gone.
local kinds: { [number]: string } = {}
local telegraphs: { [number]: { Instance } } = {}
local container: Folder

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

local function healthBar(adornee: BasePart, height: number): Frame
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.fromOffset(60, 8)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height / 2 + 1.5, 0)
	gui.MaxDistance = 150
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

local function buildModel(event: Remotes.NpcSpawnEvent): (Model, BasePart, number, BasePart?)
	local model = Instance.new("Model")
	model.Name = `{event.kind}_{event.id}`
	local root: BasePart
	local height: number
	local sword: BasePart? = nil
	if event.kind == "dummy" then
		height = 6
		root = part("Body", Vector3.new(4, height, 4), Color3.fromRGB(190, 160, 110), model)
	elseif event.kind == "weak" then
		height = 3
		root = part("Body", Vector3.new(3, 3, 3), Color3.fromRGB(230, 110, 60), model, Enum.PartType.Ball)
	elseif event.kind == "slammer" then
		height = 8
		root = part("Body", Vector3.new(8, 8, 8), Color3.fromRGB(130, 70, 190), model)
		local eye = part("Eye", Vector3.new(4, 1, 0.2), Color3.fromRGB(255, 230, 90), model)
		eye.Material = Enum.Material.Neon
		eye:SetAttribute("Offset", CFrame.new(0, 2, -4.05))
	else -- bot
		height = 5
		root = part("Body", Vector3.new(2, height, 1.2), teamColor(event.team), model)
		local head = part("Head", Vector3.new(1.6, 1.6, 1.6), Color3.fromRGB(240, 220, 190), model, Enum.PartType.Ball)
		head:SetAttribute("Offset", CFrame.new(0, height / 2 + 0.8, 0))
		local blade = part("Sword", Vector3.new(0.25, 0.25, 4), Color3.fromRGB(200, 205, 215), model)
		blade.Material = Enum.Material.Metal
		blade:SetAttribute("Offset", CFrame.new(1.2, 0, -2))
		sword = blade
	end
	model.PrimaryPart = root
	model.Parent = container
	return model, root, height, sword
end

local function place(npc: Npc, x: number, z: number, yaw: number)
	local base = CFrame.new(x, npc.height / 2, z) * CFrame.Angles(0, yaw, 0)
	npc.root.CFrame = base
	npc.position = base.Position
	for _, child in npc.model:GetChildren() do
		if child:IsA("BasePart") and child ~= npc.root then
			local offset = child:GetAttribute("Offset")
			if typeof(offset) == "CFrame" then
				local o = offset
				if child == npc.sword and os.clock() < npc.swingUntil then
					-- Swing the bot's sword across its front.
					local p = 1 - (npc.swingUntil - os.clock()) / 0.25
					o = CFrame.new(0, 0.5, 0) * CFrame.Angles(0, (0.5 - p) * 2.4, 0) * CFrame.new(0, 0, -2.2)
				end
				child.CFrame = base * o
			end
		end
	end
end

local function onSpawn(event: Remotes.NpcSpawnEvent)
	if npcs[event.id] then
		return
	end
	local model, root, height, sword = buildModel(event)
	local npc: Npc = {
		id = event.id,
		kind = event.kind,
		team = event.team,
		radius = event.radius,
		maxHealth = event.maxHealth,
		model = model,
		root = root,
		height = height,
		bar = healthBar(root, height),
		sword = sword,
		samples = {},
		position = Vector3.zero,
		swingUntil = 0,
	}
	npcs[event.id] = npc
	kinds[event.id] = event.kind
end

local function clearTelegraph(id: number)
	local parts = telegraphs[id]
	if parts then
		for _, p in parts do
			p:Destroy()
		end
		telegraphs[id] = nil
	end
end

local function onDespawn(id: number)
	local npc = npcs[id]
	if npc then
		npc.model:Destroy()
		npcs[id] = nil
	end
	clearTelegraph(id)
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
				table.insert(samples, { t = time, x = e.x, z = e.z, yaw = e.yaw, health = e.health, state = e.state })
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

local function disc(name: string, center: Vector3, radius: number, color: Color3, transparency: number): Part
	local p = part(name, Vector3.new(0.2, radius * 2, radius * 2), color, container, Enum.PartType.Cylinder)
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	-- Cylinders run along X; stand the disc flat on the ground.
	p.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	return p
end

local function onAction(event: Remotes.NpcActionEvent)
	local center = Vector3.new(event.x, 0.12, event.z)
	if event.action == "telegraph" then
		clearTelegraph(event.id)
		local ring = disc("Telegraph", center, event.radius, Color3.fromRGB(255, 60, 40), 0.7)
		local fill = disc("TelegraphFill", center + Vector3.new(0, 0.02, 0), 0.1, Color3.fromRGB(255, 120, 60), 0.45)
		local fullSize = Vector3.new(0.2, event.radius * 2, event.radius * 2)
		TweenService:Create(fill, TweenInfo.new(event.duration, Enum.EasingStyle.Linear), { Size = fullSize }):Play()
		telegraphs[event.id] = { ring, fill }
	elseif event.action == "impact" then
		clearTelegraph(event.id)
		local blast = disc("Impact", center, event.radius, Color3.new(1, 1, 1), 0.3)
		TweenService:Create(blast, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		task.delay(0.35, function()
			blast:Destroy()
		end)
		Feedback.playSound(Config.get().combat.sounds.slam, center, 0.9)
		local character = (Players.LocalPlayer :: Player).Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(event.x, 0, event.z)).Magnitude
			if d < event.radius * 3 then
				Feedback.shake(0.8 * (1 - d / (event.radius * 3)) + 0.2, 0.35)
			end
		end
	end
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
	Net.onClientEvent(Remotes.NpcAction, onAction)
	RunService.RenderStepped:Connect(render)
	Net.fireServer(Remotes.NpcReady, nil)
end

return NpcRenderController
