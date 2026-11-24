--!strict
-- Monster attack effects from MonsterAction events: telegraphs drawn on the ground that fill up
-- until impact, impact flashes, flying bolts, and phase and stagger cues.
--
--   Telegraph shapes: circle (slam), cone (sweep, built from wedge triangles), line (bolt path;
--   fans for volleys). Each has a faint outline of the full area and a bright fill that grows
--   from the origin until it reaches the edge at impact, so how long is left reads at a glance.
--   Attacks by hostile monsters are red-orange; your own team's guardians draw faint blue, so in
--   a crowded fight the shapes that matter stand out.
--   Bolts are simulated locally from the launch event on the server clock; the server resolves
--   their hits.
-- Parts are created per event, never per frame, and removed when the effect ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Shapes = require(ReplicatedStorage.Shared.Combat.Shapes)

local Feedback = require("../Feedback")
local NpcRenderController = require("./NpcRenderController")
local Toast = require("../UI/Components/Toast")

local GROUND = 0.16
local THICKNESS = 0.1
local HOSTILE = Color3.fromRGB(255, 70, 40)
local HOSTILE_FILL = Color3.fromRGB(255, 140, 60)
local FRIENDLY = Color3.fromRGB(80, 160, 255)

local MonsterFxController = {
	name = "MonsterFxController",
	dependencies = { "NpcRenderController" },
}

type Telegraph = {
	id: number,
	event: Remotes.MonsterActionEvent,
	outline: Model,
	fill: Model,
	-- Updates the fill for progress p in [0, 1].
	update: (p: number) -> (),
}

type Bolt = {
	part: BasePart,
	x: number,
	z: number,
	dx: number,
	dz: number,
	startsAt: number,
	speed: number,
	reach: number,
}

local player = Players.LocalPlayer :: Player
local telegraphs: { Telegraph } = {}
local bolts: { Bolt } = {}
local container: Folder

local function myTeam(): number?
	local team = player.Team
	local index = team and team:GetAttribute("TeamIndex")
	return if type(index) == "number" then index else nil
end

local function hostile(npcId: number): boolean
	local team = NpcRenderController.teamOf(npcId)
	return team == nil or team ~= myTeam()
end

local function flat(name: string, color: Color3, transparency: number, parent: Instance, shape: Enum.PartType?): Part
	local p = Instance.new(if shape == Enum.PartType.Wedge then "WedgePart" else "Part") :: Part
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	if shape and shape ~= Enum.PartType.Wedge then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function disc(
	name: string,
	x: number,
	z: number,
	y: number,
	radius: number,
	color: Color3,
	transparency: number,
	parent: Instance
): Part
	local p = flat(name, color, transparency, parent, Enum.PartType.Cylinder)
	p.Size = Vector3.new(THICKNESS, radius * 2, radius * 2)
	-- Cylinders run along X; stand the disc flat on the ground.
	p.CFrame = CFrame.new(x, y, z) * CFrame.Angles(0, 0, math.rad(90))
	return p
end

-- A flat triangle on the ground from two wedges (a, b, c at the same height).
local function triangle(a: Vector3, b: Vector3, c: Vector3, color: Color3, transparency: number, parent: Instance)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- Make a-b... arrange so that bc is the longest side.
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local w1 = flat("Wedge", color, transparency, parent, Enum.PartType.Wedge)
	w1.Size = Vector3.new(THICKNESS, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	local w2 = flat("Wedge", color, transparency, parent, Enum.PartType.Wedge)
	w2.Size = Vector3.new(THICKNESS, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
end

local function cone(e: Remotes.MonsterActionEvent, y: number, color: Color3, transparency: number, parent: Model)
	local segments = math.max(2, math.ceil(e.arc / 15))
	local origin = Vector3.new(e.x, y, e.z)
	for i = 0, segments - 1 do
		local a1 = -e.arc / 2 + e.arc * i / segments
		local a2 = -e.arc / 2 + e.arc * (i + 1) / segments
		local x1, z1 = Shapes.rotate(e.dx, e.dz, a1)
		local x2, z2 = Shapes.rotate(e.dx, e.dz, a2)
		triangle(
			origin,
			origin + Vector3.new(x1, 0, z1) * e.reach,
			origin + Vector3.new(x2, 0, z2) * e.reach,
			color,
			transparency,
			parent
		)
	end
	parent.WorldPivot = CFrame.new(origin)
end

local function lines(
	e: Remotes.MonsterActionEvent,
	y: number,
	color: Color3,
	transparency: number,
	parent: Model
): { BasePart }
	local list: { BasePart } = {}
	for _, dir in Shapes.fan(e.dx, e.dz, math.max(1, e.count), e.spread) do
		local p = flat("Line", color, transparency, parent)
		p.Size = Vector3.new(e.radius * 2, THICKNESS, e.reach)
		local origin = Vector3.new(e.x, y, e.z)
		local d = Vector3.new(dir.x, 0, dir.z)
		p.CFrame = CFrame.lookAt(origin + d * e.reach / 2, origin + d * e.reach)
		p:SetAttribute("DirX", dir.x)
		p:SetAttribute("DirZ", dir.z)
		table.insert(list, p)
	end
	return list
end

local function clearTelegraphs(id: number)
	for i = #telegraphs, 1, -1 do
		local t = telegraphs[i]
		if t.id == id then
			t.outline:Destroy()
			t.fill:Destroy()
			table.remove(telegraphs, i)
		end
	end
end

local function onTelegraph(e: Remotes.MonsterActionEvent)
	clearTelegraphs(e.id)
	local enemy = hostile(e.id)
	local edge = if enemy then HOSTILE else FRIENDLY
	local fillColor = if enemy then HOSTILE_FILL else FRIENDLY
	local outlineAlpha = if enemy then 0.72 else 0.9
	local fillAlpha = if enemy then 0.45 else 0.85
	local outline = Instance.new("Model")
	outline.Name = "Telegraph"
	local fill = Instance.new("Model")
	fill.Name = "TelegraphFill"
	local update: (p: number) -> ()
	if e.shape == "circle" then
		disc("Area", e.x, e.z, GROUND, e.radius, edge, outlineAlpha, outline)
		-- A thin brighter rim so the edge is crisp.
		disc("Rim", e.x, e.z, GROUND - 0.02, e.radius + 0.3, edge, outlineAlpha - 0.2, outline)
		local f = disc("Fill", e.x, e.z, GROUND + 0.02, 0.1, fillColor, fillAlpha, fill)
		update = function(p: number)
			local r = math.max(0.1, e.radius * p)
			f.Size = Vector3.new(THICKNESS, r * 2, r * 2)
		end
	elseif e.shape == "cone" then
		cone(e, GROUND, edge, outlineAlpha, outline)
		cone(e, GROUND + 0.02, fillColor, fillAlpha, fill)
		fill:ScaleTo(0.05)
		update = function(p: number)
			fill:ScaleTo(math.max(0.05, p))
		end
	else
		lines(e, GROUND, edge, outlineAlpha, outline)
		local fills = lines(e, GROUND + 0.02, fillColor, fillAlpha, fill)
		update = function(p: number)
			local length = math.max(0.1, e.reach * p)
			for _, f in fills do
				local d = Vector3.new(f:GetAttribute("DirX") :: number, 0, f:GetAttribute("DirZ") :: number)
				local origin = Vector3.new(e.x, GROUND + 0.02, e.z)
				f.Size = Vector3.new(e.radius * 2, THICKNESS, length)
				f.CFrame = CFrame.lookAt(origin + d * length / 2, origin + d * e.reach)
			end
		end
	end
	update(0)
	outline.Parent = container
	fill.Parent = container
	table.insert(telegraphs, { id = e.id, event = e, outline = outline, fill = fill, update = update })
end

local function distanceToMe(x: number, z: number): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(x, 0, z)).Magnitude
	end
	return math.huge
end

local function onImpact(e: Remotes.MonsterActionEvent)
	clearTelegraphs(e.id)
	if e.shape == "none" then
		-- A charge starting: the monster itself moves (snapshots); just the sound.
		Feedback.playSound(Config.get().combat.sounds.swing, Vector3.new(e.x, 2, e.z), 0.8)
		return
	end
	local flash = Instance.new("Model")
	flash.Name = "Impact"
	if e.shape == "circle" then
		disc("Flash", e.x, e.z, GROUND + 0.04, e.radius, Color3.new(1, 1, 1), 0.3, flash)
	else
		cone(e, GROUND + 0.04, Color3.new(1, 1, 1), 0.3, flash)
	end
	flash.Parent = container
	for _, p in flash:GetChildren() do
		TweenService:Create(p, TweenInfo.new(0.3), { Transparency = 1 }):Play()
	end
	task.delay(0.35, function()
		flash:Destroy()
	end)
	local reach = math.max(e.radius, e.reach)
	Feedback.playSound(Config.get().combat.sounds.slam, Vector3.new(e.x, 0, e.z), 0.9)
	local d = distanceToMe(e.x, e.z)
	if d < reach * 3 then
		Feedback.shake(0.8 * (1 - d / (reach * 3)) + 0.2, 0.35)
	end
end

local function onProjectile(e: Remotes.MonsterActionEvent)
	clearTelegraphs(e.id)
	local enemy = hostile(e.id)
	for _, dir in Shapes.fan(e.dx, e.dz, math.max(1, e.count), e.spread) do
		local ball = flat("Bolt", if enemy then HOSTILE_FILL else FRIENDLY, 0, container, Enum.PartType.Ball)
		ball.Size = Vector3.one * e.radius * 2
		ball.CFrame = CFrame.new(e.x, 3, e.z)
		table.insert(bolts, {
			part = ball :: BasePart,
			x = e.x,
			z = e.z,
			dx = dir.x,
			dz = dir.z,
			startsAt = e.startsAt,
			speed = e.speed,
			reach = e.reach,
		})
	end
	Feedback.playSound(Config.get().combat.sounds.swing, Vector3.new(e.x, 3, e.z), 0.6)
end

local function monsterName(npcId: number): string
	local kind = NpcRenderController.kindOf(-npcId)
	local def = kind and Config.get().monsters[kind]
	return if def then def.name else "Monster"
end

local function onPhase(e: Remotes.MonsterActionEvent)
	local d = distanceToMe(e.x, e.z)
	if d < 150 then
		Toast.show(`{monsterName(e.id)} enters phase {e.value}!`, "warning")
		Feedback.shake(0.6, 0.5)
	end
end

local function onStagger(e: Remotes.MonsterActionEvent)
	clearTelegraphs(e.id)
	if distanceToMe(e.x, e.z) < 80 then
		Toast.show(`{monsterName(e.id)} is staggered: bonus damage!`, "success")
		local model = NpcRenderController.model(-e.id)
		Feedback.flash(model)
	end
end

local function render()
	local t = workspace:GetServerTimeNow()
	for i = #telegraphs, 1, -1 do
		local tg = telegraphs[i]
		local e = tg.event
		local length = e.endsAt - e.startsAt
		local p = if length > 0 then math.clamp((t - e.startsAt) / length, 0, 1) else 1
		tg.update(p)
		-- The impact event normally removes it; this is the fallback if it never arrives.
		if t > e.endsAt + 0.6 then
			tg.outline:Destroy()
			tg.fill:Destroy()
			table.remove(telegraphs, i)
		end
	end
	for i = #bolts, 1, -1 do
		local b = bolts[i]
		local travelled = math.max(0, (t - b.startsAt) * b.speed)
		if travelled >= b.reach then
			b.part:Destroy()
			table.remove(bolts, i)
		else
			b.part.CFrame = CFrame.new(b.x + b.dx * travelled, 3, b.z + b.dz * travelled)
		end
	end
end

function MonsterFxController.start(_self: typeof(MonsterFxController))
	local folder = Instance.new("Folder")
	folder.Name = "MonsterFx"
	folder.Parent = workspace
	container = folder

	Net.onClientEvent(Remotes.MonsterAction, function(e: Remotes.MonsterActionEvent)
		if e.action == "telegraph" then
			onTelegraph(e)
		elseif e.action == "impact" then
			onImpact(e)
		elseif e.action == "projectile" then
			onProjectile(e)
		elseif e.action == "phase" then
			onPhase(e)
		elseif e.action == "stagger" then
			onStagger(e)
		end
	end)
	Net.onClientEvent(Remotes.NpcDespawn, function(id: number)
		clearTelegraphs(id)
	end)
	RunService.RenderStepped:Connect(render)
end

return MonsterFxController
