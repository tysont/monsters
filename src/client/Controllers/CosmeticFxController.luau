--!strict
-- Cosmetics on the client (Phase 12): kill effect bursts, emote poses (press G to play your
-- equipped emote), and the shop preview: an item shown on your own character for a few seconds,
-- visible only to you (Shared.CosmeticLook, the same code the server uses).
-- Placeholder visuals until Phase 13.

local ContextActionService = game:GetService("ContextActionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CosmeticLook = require(ReplicatedStorage.Shared.CosmeticLook)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Toast = require("../UI/Components/Toast")

local PREVIEW_TAG = "CosmeticPreview"
local PREVIEW_SECONDS = 6
local EMOTE_SECONDS = 1.6

local CosmeticFxController = {
	name = "CosmeticFxController",
}

local player = Players.LocalPlayer :: Player
local previewToken = 0

local function rgb(c: { number }?): Color3
	return if c then Color3.fromRGB(c[1], c[2], c[3]) else Color3.new(1, 1, 1)
end

-- Kill effects --------------------------------------------------------------------------------

local function burst(itemId: string, position: Vector3)
	local item = Cosmetics.get(itemId)
	if item == nil then
		return
	end
	local look = item.look
	local color = rgb(look.color)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new(position + Vector3.new(0, 2, 0))
	anchor.Parent = workspace
	if look.burst == "rings" then
		local ring = Instance.new("Part")
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.Material = Enum.Material.Neon
		ring.Color = color
		ring.Transparency = 0.3
		ring.Size = Vector3.new(0.2, 2, 2)
		ring.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace
		TweenService:Create(ring, TweenInfo.new(0.5), { Size = Vector3.new(0.2, 16, 16), Transparency = 1 }):Play()
		Debris:AddItem(ring, 0.55)
	else
		local e = Instance.new("ParticleEmitter")
		e.Color = ColorSequence.new(color)
		e.Rate = 0
		e.Speed = NumberRange.new(if look.burst == "skulls" then 2 else 10, if look.burst == "skulls" then 4 else 18)
		e.Lifetime = NumberRange.new(0.6, 1.2)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = if look.burst == "skulls" then Vector3.new(0, 4, 0) else Vector3.new(0, -20, 0)
		e.Size = NumberSequence.new(if look.burst == "petals" then 0.5 else 0.3, 0)
		e.LightEmission = 0.5
		e.Parent = anchor
		e:Emit(if look.burst == "skulls" then 8 else 30)
	end
	Debris:AddItem(anchor, 1.5)
end

-- Emotes ----------------------------------------------------------------------------------------

local function motor(character: Model, partName: string, motorName: string): Motor6D?
	local part = character:FindFirstChild(partName)
	local m = part and part:FindFirstChild(motorName)
	return if m and m:IsA("Motor6D") then m else nil
end

-- Plays an emote pose on a character for a moment (procedural; real animations in Phase 13).
local function playPose(character: Model, pose: string)
	local right = motor(character, "RightUpperArm", "RightShoulder")
	local left = motor(character, "LeftUpperArm", "LeftShoulder")
	local waist = motor(character, "UpperTorso", "Waist")
	local root = motor(character, "LowerTorso", "Root")
	local saved: { [Motor6D]: CFrame } = {}
	for _, m in { right, left, waist, root } do
		if m then
			saved[m] = m.C0
		end
	end
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = os.clock() - started
		if t >= EMOTE_SECONDS or character.Parent == nil then
			connection:Disconnect()
			for m, c0 in saved do
				if m.Parent then
					m.C0 = c0
				end
			end
			return
		end
		local p = t / EMOTE_SECONDS
		local weight = math.sin(p * math.pi)
		if pose == "wave" and right then
			right.C0 = saved[right] * CFrame.Angles(0, 0, (2.6 + math.sin(t * 12) * 0.4) * weight)
		elseif pose == "cheer" then
			if right then
				right.C0 = saved[right] * CFrame.Angles(0, 0, 2.8 * weight)
			end
			if left then
				left.C0 = saved[left] * CFrame.Angles(0, 0, -2.8 * weight)
			end
		elseif pose == "bow" and waist then
			waist.C0 = saved[waist] * CFrame.Angles(-0.9 * weight, 0, 0)
		elseif pose == "spin" and root then
			root.C0 = saved[root] * CFrame.Angles(0, p * math.pi * 2, 0)
		end
	end)
end

local function onEmote(event: Remotes.EmoteEvent)
	local other = Players:GetPlayerByUserId(event.player)
	local item = Cosmetics.get(event.item)
	local character = other and other.Character
	if character and item and item.look.pose then
		playPose(character, item.look.pose)
	end
end

-- Preview -------------------------------------------------------------------------------------

-- Shows an item on the local character (or plays it) for a few seconds, visible only here.
function CosmeticFxController.preview(itemId: string)
	local item = Cosmetics.get(itemId)
	local character = player.Character
	if item == nil or character == nil then
		return
	end
	previewToken += 1
	local token = previewToken
	if item.kind == "killEffect" then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			burst(itemId, root.Position + root.CFrame.LookVector * 6)
		end
		return
	elseif item.kind == "emote" then
		playPose(character, item.look.pose or "wave")
		return
	elseif item.kind == "title" or item.kind == "petSkin" then
		Toast.show(if item.kind == "title" then `Title: {item.look.text}` else `Pet skin: {item.name}`, "info")
		return
	end
	-- Remember the weapon as worn now (it may carry a skin) to put it back afterwards.
	local worn: { [BasePart]: { color: Color3, material: Enum.Material } } = {}
	local weapon = character:FindFirstChild("Weapon")
	if weapon then
		for _, part in weapon:GetChildren() do
			if part:IsA("BasePart") then
				worn[part] = { color = part.Color, material = part.Material }
			end
		end
	end
	CosmeticLook.dress(character, { [item.kind] = itemId }, PREVIEW_TAG)
	task.delay(PREVIEW_SECONDS, function()
		if previewToken == token and character.Parent then
			CosmeticLook.strip(character, PREVIEW_TAG)
			for part, look in worn do
				if part.Parent then
					part.Color = look.color
					part.Material = look.material
				end
			end
		end
	end)
end

function CosmeticFxController.start(_self: typeof(CosmeticFxController))
	Net.onClientEvent(Remotes.KillEffect, function(event: Remotes.KillEffectEvent)
		burst(event.item, event.position)
	end)
	Net.onClientEvent(Remotes.EmotePlayed, onEmote)
	ContextActionService:BindAction("Emote", function(_name, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			Net.fireServer(Remotes.Emote, nil)
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.G, Enum.KeyCode.DPadUp)
end

return CosmeticFxController
