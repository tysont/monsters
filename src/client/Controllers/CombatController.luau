--!strict
-- Player combat on the client: input, the swing, the dodge, and feedback.
--
--   Input (one action layer for mouse/keyboard, gamepad and touch):
--     Attack  left mouse, gamepad R2 or X, on-screen button on touch
--     Dodge   Q, gamepad B, on-screen button on touch
--   The swing animation and sound start the moment input arrives; the request goes to the
--   server, which decides what was hit. The client also predicts its own hits with the same
--   rules (Shared.Combat.Melee) so hit-stop, flash and hit sound are instant; damage numbers
--   come from the server.
--   Dodge moves the character immediately (the client owns its character's physics); the
--   server grants the invulnerability window.
--
-- Placeholder visuals: a procedural arm swing and a kill feed (Phase 4 and 13 replace them).

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Melee = require(ReplicatedStorage.Shared.Combat.Melee)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Tuning = require(ReplicatedStorage.Shared.Combat.Tuning)

local Feedback = require("../Feedback")
local NpcRenderController = require("./NpcRenderController")

local KILL_FEED_LINES = 5
local KILL_FEED_SECONDS = 6
local PREDICTION_MEMORY = 0.6
local LATENCY_SAMPLES = 30

local CombatController = {
	name = "CombatController",
	dependencies = { "NpcRenderController" },
}

type Swing = { motor: Motor6D, base: CFrame, start: number, duration: number }

local player = Players.LocalPlayer :: Player
local swings: { [Motor6D]: Swing } = {}
local lastAttack = -math.huge
local lastDodge = -math.huge
-- Targets this client predicted hitting, by combatant ID, with the time.
local predicted: { [number]: number } = {}
-- Input time of the latest attack waiting for its first animated frame.
local pendingInput: number? = nil
local latencies: { number } = {}
local killFeed: Frame
local healthFill: Frame
local healthLabel: TextLabel

local function config()
	return Config.get().combat
end

local function character(): Model?
	return player.Character
end

local function humanoidAndRoot(): (Humanoid?, BasePart?)
	local c = character()
	if c == nil then
		return nil, nil
	end
	local humanoid = c:FindFirstChildOfClass("Humanoid")
	local root = c:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

-- Alive and not frozen by the round.
local function canAct(): boolean
	local humanoid = humanoidAndRoot()
	return humanoid ~= nil and humanoid.Health > 0 and humanoid.WalkSpeed > 0
end

local function myTeam(): number?
	local team = player.Team
	local index = team and team:GetAttribute("TeamIndex")
	return if type(index) == "number" then index else nil
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

-- Procedural swing -------------------------------------------------------------------------

local function shoulderOf(model: Model): Motor6D?
	local arm = model:FindFirstChild("RightUpperArm")
	local motor = arm and arm:FindFirstChild("RightShoulder")
	if motor == nil then
		local torso = model:FindFirstChild("Torso")
		motor = torso and torso:FindFirstChild("Right Shoulder")
	end
	return if motor and motor:IsA("Motor6D") then motor else nil
end

local function startSwing(model: Model)
	local motor = shoulderOf(model)
	if motor == nil then
		return
	end
	local existing = swings[motor]
	local base = if existing then existing.base else motor.C0
	swings[motor] = { motor = motor, base = base, start = os.clock(), duration = config().swingDuration }
end

-- Arm pose for swing progress p in [0, 1]: raise, slash across, recover.
local function swingPose(p: number): CFrame
	local raise = math.sin(math.min(p / 0.3, 1) * math.pi / 2)
	local slash = if p > 0.3 then math.clamp((p - 0.3) / 0.45, 0, 1) else 0
	slash = slash * slash * (3 - 2 * slash)
	local weight = if p < 0.8 then 1 else 1 - (p - 0.8) / 0.2
	return CFrame.Angles((raise * 2.4 - slash * 3.2) * weight, 0, (-slash * 0.9) * weight)
end

local function updateSwings()
	local t = os.clock()
	for motor, swing in swings do
		local p = (t - swing.start) / swing.duration
		if motor.Parent == nil or p >= 1 then
			if motor.Parent then
				motor.C0 = swing.base
			end
			swings[motor] = nil
		else
			motor.C0 = swing.base * swingPose(math.max(0, p))
		end
	end
	if pendingInput then
		local sample = (os.clock() - (pendingInput :: number)) * 1000
		table.insert(latencies, sample)
		if #latencies > LATENCY_SAMPLES then
			table.remove(latencies, 1)
		end
		pendingInput = nil
	end
end

-- Hit-stop: freeze the local swing for `seconds`.
local function hitStop(seconds: number)
	local c = character()
	local motor = c and shoulderOf(c)
	local swing = motor and swings[motor]
	if swing then
		swing.start += seconds
	end
end

-- Targets ----------------------------------------------------------------------------------

type Target = { id: number, position: Vector3, radius: number, model: Model }

local function hostileTargets(): { Target }
	local team = myTeam()
	local list: { Target } = {}
	for _, other in Players:GetPlayers() do
		if other ~= player and other.Team ~= player.Team then
			local c = other.Character
			local root = c and c:FindFirstChild("HumanoidRootPart")
			local humanoid = c and c:FindFirstChildOfClass("Humanoid")
			if c and root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				table.insert(list, { id = other.UserId, position = root.Position, radius = 1.5, model = c })
			end
		end
	end
	for _, npc in NpcRenderController.targets() do
		if npc.team ~= team then
			table.insert(list, { id = npc.id, position = npc.position, radius = npc.radius, model = npc.model })
		end
	end
	return list
end

local function modelOf(combatantId: number): Model?
	if combatantId > 0 then
		local other = Players:GetPlayerByUserId(combatantId)
		return other and other.Character
	end
	return NpcRenderController.model(combatantId)
end

local function nameOf(combatantId: number): string
	if combatantId > 0 then
		local other = Players:GetPlayerByUserId(combatantId)
		return if other then other.DisplayName else "Player"
	end
	local kind = NpcRenderController.kindOf(combatantId)
	return if kind then string.upper(string.sub(kind, 1, 1)) .. string.sub(kind, 2) else "Monster"
end

-- Actions ----------------------------------------------------------------------------------

local function attack(inputTime: number)
	if not canAct() then
		return
	end
	local t = os.clock()
	if t - lastAttack < Tuning.get("attackCooldown") then
		return
	end
	lastAttack = t
	local _, root = humanoidAndRoot()
	local c = character()
	if root == nil or c == nil then
		return
	end

	-- Attack where the camera looks, turning the character to match.
	local direction = flat(workspace.CurrentCamera.CFrame.LookVector)
	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
	startSwing(c)
	pendingInput = inputTime
	Feedback.playSound(config().sounds.swing, nil, 0.5)
	Net.fireServer(Remotes.CombatAttack, { direction = direction })

	-- Predict our own hits for instant feedback (the server still decides the damage).
	local targets = hostileTargets()
	local candidates: { Melee.Candidate } = {}
	local byId: { [number]: Target } = {}
	for _, target in targets do
		byId[target.id] = target
		table.insert(candidates, {
			id = target.id,
			position = { x = target.position.X, z = target.position.Z },
			radius = target.radius,
		})
	end
	local hits = Melee.selectTargets(
		{ x = root.Position.X, z = root.Position.Z },
		{ x = direction.X, z = direction.Z },
		candidates,
		{ range = Tuning.get("attackRange"), arc = Tuning.get("attackArc"), maxTargets = config().maxTargets }
	)
	if #hits > 0 then
		hitStop(Tuning.get("hitStop"))
		Feedback.playSound(config().sounds.hit, nil, 0.7)
		Feedback.shake(0.15, 0.12)
		for _, id in hits do
			predicted[id] = t
			Feedback.flash(byId[id].model)
		end
	end
end

local function dodge()
	if not canAct() then
		return
	end
	local t = os.clock()
	if t - lastDodge < Tuning.get("dodgeCooldown") then
		return
	end
	lastDodge = t
	local humanoid, root = humanoidAndRoot()
	if humanoid == nil or root == nil then
		return
	end
	local move = humanoid.MoveDirection
	local direction = if move.Magnitude > 0.1 then flat(move) else flat(root.CFrame.LookVector)
	local duration = config().dodgeDuration

	local attachment = Instance.new("Attachment")
	attachment.Name = "DodgeAttachment"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(1e6, 0, 1e6)
	velocity.VectorVelocity = direction * (Tuning.get("dodgeDistance") / duration)
	velocity.Parent = root

	local c = character()
	if c then
		for _, d in c:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0.5
			end
		end
	end
	task.delay(duration, function()
		attachment:Destroy()
		velocity:Destroy()
		if c then
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = 0
				end
			end
		end
	end)
	Net.fireServer(Remotes.CombatDodge, nil)
end

-- Pushes the local character (knockback). The client owns its character's physics.
local function push(velocity: Vector3)
	local _, root = humanoidAndRoot()
	if root == nil or velocity.Magnitude < 0.1 then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(1e5, 0, 1e5)
	lv.VectorVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	lv.Parent = root
	task.delay(0.15, function()
		attachment:Destroy()
		lv:Destroy()
	end)
end

-- Server events ----------------------------------------------------------------------------

local function onHit(event: Remotes.HitEvent)
	local me = player.UserId
	local t = os.clock()
	local wasPredicted = event.source == me
		and predicted[event.target] ~= nil
		and t - predicted[event.target] < PREDICTION_MEMORY
	if not wasPredicted then
		Feedback.flash(modelOf(event.target))
		if event.source == me then
			Feedback.playSound(config().sounds.hit, nil, 0.7)
		end
	end
	local color = if event.target == me
		then Color3.fromRGB(255, 80, 80)
		elseif event.source == me then Color3.fromRGB(255, 230, 120)
		else Color3.fromRGB(235, 235, 235)
	Feedback.damageNumber(event.position + Vector3.new(0, 3, 0), event.amount, color)
	if event.target == me then
		Feedback.shake(0.5, 0.25)
		Feedback.playSound(config().sounds.hit, nil, 0.5)
		push(event.knockback)
	end
end

local function addKillLine(text: string)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 20)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	label.TextSize = 15
	label.Text = text
	label.LayoutOrder = -math.floor(os.clock() * 1000)
	label.Parent = killFeed
	local lines = {}
	for _, child in killFeed:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(lines, child)
		end
	end
	table.sort(lines, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = KILL_FEED_LINES + 1, #lines do
		lines[i]:Destroy()
	end
	task.delay(KILL_FEED_SECONDS, function()
		label:Destroy()
	end)
end

local function onKill(event: Remotes.KillEvent)
	local text = `{nameOf(event.killer)}  defeated  {nameOf(event.victim)}`
	if #event.assists > 0 then
		local names = {}
		for _, id in event.assists do
			table.insert(names, nameOf(id))
		end
		text ..= `  (assist: {table.concat(names, ", ")})`
	end
	addKillLine(text)
end

local function onSwing(attackerId: number)
	if attackerId < 0 then
		NpcRenderController.playSwing(attackerId)
		return
	end
	local model = modelOf(attackerId)
	if model then
		startSwing(model)
		local root = model:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			Feedback.playSound(config().sounds.swing, root.Position, 0.4)
		end
	end
end

-- UI ---------------------------------------------------------------------------------------

local function buildUi()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatHud"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets

	local feed = Instance.new("Frame")
	feed.Name = "KillFeed"
	feed.AnchorPoint = Vector2.new(1, 0)
	feed.Position = UDim2.new(1, -12, 0, 60)
	feed.Size = UDim2.fromOffset(420, 120)
	feed.BackgroundTransparency = 1
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = feed
	feed.Parent = gui
	killFeed = feed

	local bar = Instance.new("Frame")
	bar.Name = "Health"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -24)
	bar.Size = UDim2.fromOffset(260, 18)
	bar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	bar.BorderSizePixel = 0
	bar.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(90, 210, 90)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	healthFill = fill
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.3
	text.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	text.TextSize = 13
	text.Parent = bar
	healthLabel = text

	gui.Parent = player:WaitForChild("PlayerGui")
end

local function updateHealth()
	local humanoid = humanoidAndRoot()
	if humanoid == nil then
		healthFill.Size = UDim2.fromScale(0, 1)
		healthLabel.Text = ""
		return
	end
	local fraction = if humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
	healthFill.Size = UDim2.fromScale(fraction, 1)
	healthLabel.Text = `HP {math.ceil(humanoid.Health)} / {math.ceil(humanoid.MaxHealth)}`
end

-- Ignore mouse clicks on visible UI buttons (the tuning panel, menus).
local function overUi(input: InputObject): boolean
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return false
	end
	local position = UserInputService:GetMouseLocation()
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui == nil then
		return false
	end
	-- GetGuiObjectsAtPosition works below the top bar inset; the mouse location includes it.
	local inset = GuiService:GetGuiInset()
	for _, object in gui:GetGuiObjectsAtPosition(position.X - inset.X, position.Y - inset.Y) do
		if object:IsA("GuiButton") and object.Visible then
			return true
		end
	end
	return false
end

-- Instrumentation --------------------------------------------------------------------------

-- Input-to-first-swing-frame latency over recent attacks, in milliseconds.
function CombatController.swingLatency(): (number, number, number)
	local total, max = 0, 0
	for _, v in latencies do
		total += v
		max = math.max(max, v)
	end
	return if #latencies > 0 then total / #latencies else 0, max, #latencies
end

function CombatController.start(_self: typeof(CombatController))
	buildUi()

	ContextActionService:BindAction("CombatAttack", function(_name, state: Enum.UserInputState, input: InputObject)
		if state == Enum.UserInputState.Begin and not overUi(input) then
			attack(os.clock())
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2, Enum.KeyCode.ButtonX)
	ContextActionService:SetTitle("CombatAttack", "Attack")

	ContextActionService:BindAction("CombatDodge", function(_name, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			dodge()
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.Q, Enum.KeyCode.ButtonB)
	ContextActionService:SetTitle("CombatDodge", "Dodge")

	Net.onClientEvent(Remotes.CombatHit, onHit)
	Net.onClientEvent(Remotes.CombatKill, onKill)
	Net.onClientEvent(Remotes.CombatSwing, onSwing)

	RunService.RenderStepped:Connect(function()
		updateSwings()
		updateHealth()
		local t = os.clock()
		for id, at in predicted do
			if t - at > PREDICTION_MEMORY then
				predicted[id] = nil
			end
		end
	end)
end

return CombatController
