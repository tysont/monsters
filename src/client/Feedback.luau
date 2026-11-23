--!strict
-- Placeholder combat feedback shared by client controllers: sounds, camera shake, hit flash and
-- pooled floating damage numbers. Rough on purpose (Phase 13 makes the final versions); every
-- effect must exist for the Phase 3 fun gate.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Feedback = {}

local DAMAGE_NUMBER_POOL = 24
local DAMAGE_NUMBER_SECONDS = 0.7
local FLASH_SECONDS = 0.08

-- Sounds -----------------------------------------------------------------------------------

-- Plays a sound once. With a position it is 3D at that point; otherwise it plays flat.
function Feedback.playSound(soundId: string, position: Vector3?, volume: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 0.6
	sound.PlaybackSpeed = 0.95 + math.random() * 0.1
	if position then
		local attachment = Instance.new("Attachment")
		attachment.WorldPosition = position
		attachment.Parent = workspace.Terrain
		sound.RollOffMaxDistance = 150
		sound.Parent = attachment
		sound.Ended:Once(function()
			attachment:Destroy()
		end)
		task.delay(5, function()
			if attachment.Parent then
				attachment:Destroy()
			end
		end)
	else
		sound.Parent = SoundService
		sound.Ended:Once(function()
			sound:Destroy()
		end)
	end
	sound:Play()
end

-- Camera shake -----------------------------------------------------------------------------

local shakeStrength = 0
local shakeUntil = 0
local shakeDuration = 0
local shakeConnection: RBXScriptConnection? = nil

-- Shakes the camera by offsetting the local character's camera, decaying over `duration`.
function Feedback.shake(strength: number, duration: number)
	local t = os.clock()
	if t + duration > shakeUntil or strength > shakeStrength then
		shakeStrength = math.max(strength, if t < shakeUntil then shakeStrength else 0)
		shakeUntil = t + duration
		shakeDuration = duration
	end
	if shakeConnection == nil then
		shakeConnection = RunService.RenderStepped:Connect(function()
			local character = (Players.LocalPlayer :: Player).Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid == nil then
				return
			end
			local remaining = shakeUntil - os.clock()
			if remaining <= 0 then
				humanoid.CameraOffset = Vector3.zero
				return
			end
			local s = shakeStrength * remaining / shakeDuration
			humanoid.CameraOffset = Vector3.new((math.random() - 0.5) * s, (math.random() - 0.5) * s, 0)
		end)
	end
end

-- Hit flash --------------------------------------------------------------------------------

-- Flashes a model white briefly.
function Feedback.flash(model: Instance?)
	if model == nil then
		return
	end
	local highlight = model:FindFirstChild("HitFlash")
	if highlight == nil then
		local h = Instance.new("Highlight")
		h.Name = "HitFlash"
		h.FillColor = Color3.new(1, 1, 1)
		h.OutlineTransparency = 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Enabled = false
		h.Parent = model
		highlight = h
	end
	local h = highlight :: Highlight
	h.FillTransparency = 0.2
	h.Enabled = true
	task.delay(FLASH_SECONDS, function()
		h.Enabled = false
	end)
end

-- Damage numbers ---------------------------------------------------------------------------

type DamageNumber = { attachment: Attachment, gui: BillboardGui, label: TextLabel, busyUntil: number }

local pool: { DamageNumber } = {}

local function makeNumber(): DamageNumber
	local attachment = Instance.new("Attachment")
	attachment.Name = "DamageNumber"
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(80, 30)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 200
	gui.Adornee = attachment
	gui.Enabled = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	attachment.Parent = workspace.Terrain
	gui.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
	return { attachment = attachment, gui = gui, label = label, busyUntil = 0 }
end

-- Shows a number rising from `position`. Reuses a fixed pool; no per-hit instance creation.
function Feedback.damageNumber(position: Vector3, amount: number, color: Color3)
	local t = os.clock()
	local slot: DamageNumber? = nil
	for _, n in pool do
		if n.busyUntil <= t then
			slot = n
			break
		end
	end
	if slot == nil then
		if #pool < DAMAGE_NUMBER_POOL then
			slot = makeNumber()
			table.insert(pool, slot :: DamageNumber)
		else
			-- Reuse the one that ends soonest.
			table.sort(pool, function(a, b)
				return a.busyUntil < b.busyUntil
			end)
			slot = pool[1]
		end
	end
	local n = slot :: DamageNumber
	n.busyUntil = t + DAMAGE_NUMBER_SECONDS
	local jitter = Vector3.new((math.random() - 0.5) * 2, 0, (math.random() - 0.5) * 2)
	n.attachment.WorldPosition = position + jitter
	n.label.Text = tostring(math.floor(amount + 0.5))
	n.label.TextColor3 = color
	n.label.TextTransparency = 0
	n.gui.StudsOffsetWorldSpace = Vector3.zero
	n.gui.Enabled = true
	local info = TweenInfo.new(DAMAGE_NUMBER_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(n.gui, info, { StudsOffsetWorldSpace = Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(n.label, info, { TextTransparency = 1 }):Play()
	task.delay(DAMAGE_NUMBER_SECONDS, function()
		if n.busyUntil <= os.clock() + 0.01 then
			n.gui.Enabled = false
		end
	end)
end

return Feedback
