--!strict
-- Puts cosmetic looks on a character (Phase 12). Used by the server (what everyone sees) and by
-- the client's shop preview (local only), so a preview looks exactly like the real thing.
-- Engine code: not required by the Lune tests.
--
-- Per-item budget (the catalogue tests check the data side): at most two extra parts, one
-- particle emitter of up to 12 per second, one light, one trail of up to 0.6 s.

local Cosmetics = require("./Cosmetics")

local CosmeticLook = {}

local ORIGINAL_COLOR = "OriginalColor"
local ORIGINAL_MATERIAL = "OriginalMaterial"
local ACCENTS = { Guard = true, Grip = true, Orb = true, Gem = true }

local function rgb(c: { number }?, fallback: Color3): Color3
	return if c then Color3.fromRGB(c[1], c[2], c[3]) else fallback
end

local function material(name: string?): Enum.Material?
	if name == nil then
		return nil
	end
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok then value else nil
end

local function tagged<T>(instance: T & Instance, tag: string): T
	instance:SetAttribute(tag, true)
	return instance
end

local function emitter(color: Color3, rate: number, tag: string): ParticleEmitter
	local e = tagged(Instance.new("ParticleEmitter"), tag)
	e.Color = ColorSequence.new(color)
	e.Rate = math.min(12, rate)
	e.Lifetime = NumberRange.new(0.4, 0.8)
	e.Speed = NumberRange.new(1, 2)
	e.Size = NumberSequence.new(0.2, 0)
	e.LightEmission = 0.6
	return e
end

-- Removes everything added with `tag`, and restores the weapon's own colours.
function CosmeticLook.strip(character: Model, tag: string)
	for _, d in character:GetDescendants() do
		if d:GetAttribute(tag) then
			d:Destroy()
		end
	end
	local weapon = character:FindFirstChild("Weapon")
	if weapon then
		for _, part in weapon:GetChildren() do
			if part:IsA("BasePart") and part:GetAttribute(ORIGINAL_COLOR) ~= nil then
				part.Color = part:GetAttribute(ORIGINAL_COLOR) :: Color3
				part.Material = material(part:GetAttribute(ORIGINAL_MATERIAL) :: string?) or part.Material
			end
		end
	end
end

local function skinWeapon(character: Model, item: Cosmetics.Item, tag: string)
	local weapon = character:FindFirstChild("Weapon")
	if weapon == nil then
		return
	end
	local look = item.look
	local accent: BasePart? = nil
	for _, part in weapon:GetChildren() do
		if part:IsA("BasePart") then
			if part:GetAttribute(ORIGINAL_COLOR) == nil then
				part:SetAttribute(ORIGINAL_COLOR, part.Color)
				part:SetAttribute(ORIGINAL_MATERIAL, part.Material.Name)
			end
			local main = rgb(look.color, part.Color)
			if ACCENTS[part.Name] then
				part.Color = rgb(look.color2, main)
				accent = part
			else
				part.Color = main
			end
			part.Material = material(look.material) or part.Material
		end
	end
	if accent then
		local glowColor = rgb(look.color2 or look.color, Color3.new(1, 1, 1))
		if look.glow then
			local light = tagged(Instance.new("PointLight"), tag)
			light.Color = glowColor
			light.Range = 7
			light.Brightness = 1.2
			light.Parent = accent
		end
		if look.particles then
			emitter(glowColor, look.particles, tag).Parent = accent
		end
	end
end

local function armour(character: Model, item: Cosmetics.Item, tag: string)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if torso == nil or not torso:IsA("BasePart") then
		return
	end
	local look = item.look
	for _, side in { -1, 1 } do
		local plate = tagged(Instance.new("Part"), tag)
		plate.Name = "ShoulderPlate"
		plate.Size = Vector3.new(1.3, 0.35, 1.3)
		plate.Color = rgb(look.color, Color3.new(0.6, 0.6, 0.6))
		plate.Material = material(look.material) or Enum.Material.Metal
		plate.CanCollide = false
		plate.CanQuery = false
		plate.CanTouch = false
		plate.Massless = true
		local weld = Instance.new("Weld")
		weld.Part0 = torso
		weld.Part1 = plate
		weld.C0 = CFrame.new(side * (torso.Size.X / 2 + 0.25), torso.Size.Y / 2, 0)
			* CFrame.Angles(0, 0, math.rad(-side * 18))
		weld.Parent = plate
		if side == 1 then
			if look.glow then
				local light = Instance.new("PointLight")
				light.Color = plate.Color
				light.Range = 6
				light.Parent = plate
			end
			if look.particles then
				emitter(rgb(look.color2 or look.color, Color3.new(1, 1, 1)), look.particles, tag).Parent = plate
			end
		end
		plate.Parent = character
	end
end

local function trail(character: Model, item: Cosmetics.Item, tag: string)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end
	local look = item.look
	local width = math.min(2, look.width or 1)
	local a0 = tagged(Instance.new("Attachment"), tag)
	a0.Position = Vector3.new(0, width / 2, 0.6)
	a0.Parent = root
	local a1 = tagged(Instance.new("Attachment"), tag)
	a1.Position = Vector3.new(0, -width / 2, 0.6)
	a1.Parent = root
	local t = tagged(Instance.new("Trail"), tag)
	t.Attachment0 = a0
	t.Attachment1 = a1
	local c1 = rgb(look.color, Color3.new(1, 1, 1))
	t.Color = ColorSequence.new(c1, rgb(look.color2, c1))
	t.Lifetime = math.min(0.6, look.lifetime or 0.3)
	t.Transparency = NumberSequence.new(0.2, 1)
	t.LightEmission = 0.5
	t.FaceCamera = true
	t.Parent = root
end

-- Dresses a character in the given worn items (slot -> item ID), replacing anything previously
-- added with `tag`. Kill effects, emotes and titles are not worn: they play or show elsewhere.
function CosmeticLook.dress(character: Model, loadout: { [string]: string }, tag: string)
	CosmeticLook.strip(character, tag)
	local weapon = loadout.weaponSkin and Cosmetics.get(loadout.weaponSkin)
	if weapon then
		skinWeapon(character, weapon, tag)
	end
	local plates = loadout.armourSkin and Cosmetics.get(loadout.armourSkin)
	if plates then
		armour(character, plates, tag)
	end
	local t = loadout.trail and Cosmetics.get(loadout.trail)
	if t then
		trail(character, t, tag)
	end
end

return CosmeticLook
