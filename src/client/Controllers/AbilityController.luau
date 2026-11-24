--!strict
-- Class abilities on the client (Phase 10).
--
--   Input: keys 1, 2 and 3 (gamepad L1, Y, R1) cast the class's abilities; the basic attack
--   (left mouse) casts slot 0 for classes without a sword. The cooldown, arm swing, dash and
--   effects start at once (prediction); the server decides what was hit.
--   Aim: directions come from the camera (or the character's facing, per settings) and snap to
--   the enemy nearest the aim (the same assist as the server). Point abilities land under the
--   mouse, clamped to range; without a mouse they land ahead of the character.
--   Others' casts arrive as AbilityFx.
--
-- The HUD reads `slots()` and `cooldown(slot)`; the class picker reads the class attributes.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Abilities = require(ReplicatedStorage.Shared.Abilities)
local Classes = require(ReplicatedStorage.Shared.Classes)
local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local AbilityFx = require("../AbilityFx")
local Feedback = require("../Feedback")
local Toast = require("../UI/Components/Toast")
local CombatController = require("./CombatController")

local AbilityController = {
	name = "AbilityController",
	dependencies = { "CombatController" },
}

export type SlotInfo = {
	slot: number,
	name: string,
	glyph: string,
	key: string,
	unlocked: boolean,
	unlockLevel: number,
	description: string,
}

local KEYS = { "1", "2", "3" }
local DASH_SECONDS = 0.2

local player = Players.LocalPlayer :: Player
-- Keyed by class and slot ("mage1"), like the server.
local lastCast: { [string]: number } = {}
local lastLockedToast = 0

function AbilityController.class(): Classes.Class
	local id = player:GetAttribute("ActiveClass")
	return Classes[if type(id) == "string" then id else Config.get().classes.default] or Classes.knight
end

local function level(): number
	local v = player:GetAttribute("ClassLevel")
	return if type(v) == "number" then v else 1
end

local function root(): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

-- The ground point under the mouse (plane y = 0), or nil without a mouse.
local function mouseGround(): Vector3?
	if not UserInputService.MouseEnabled then
		return nil
	end
	local camera = workspace.CurrentCamera
	local m = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(m.X, m.Y)
	if math.abs(ray.Direction.Y) < 1e-3 then
		return nil
	end
	local t = -ray.Origin.Y / ray.Direction.Y
	if t <= 0 then
		return nil
	end
	return ray.Origin + ray.Direction * t
end

local function dash(direction: Vector3, distance: number)
	local r = root()
	if r == nil then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = r
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(1e6, 0, 1e6)
	velocity.VectorVelocity = direction * (distance / DASH_SECONDS)
	velocity.Parent = r
	task.delay(DASH_SECONDS, function()
		attachment:Destroy()
		velocity:Destroy()
	end)
end

-- Casts slot `slot` (0 = basic). Returns whether a cast was sent.
function AbilityController.cast(slot: number): boolean
	if not CombatController.canAct() then
		return false
	end
	local class = AbilityController.class()
	local ability = Abilities.slot(class, slot)
	if ability == nil or ability.melee then
		return false
	end
	if not Abilities.unlocked(ability, level()) then
		if os.clock() - lastLockedToast > 1.5 then
			lastLockedToast = os.clock()
			Toast.show(`{ability.name} unlocks at {class.name} level {ability.unlockLevel}`, "info")
		end
		return false
	end
	if ability.dash and player:GetAttribute("CarryingEgg") ~= nil then
		return false
	end
	local t = os.clock()
	if t - (lastCast[class.id .. slot] or -math.huge) < ability.cooldown then
		return false
	end
	local r = root()
	if r == nil then
		return false
	end
	local origin = r.Position
	local dir = CombatController.aimDirection()

	-- The same aim assist as the server, for facing and effects.
	if ability.aim == "direction" then
		local reach = ability.range or (if ability.shape then ability.shape.size else 0)
		local candidates: { Abilities.Candidate } = {}
		for _, target in CombatController.targets() do
			table.insert(candidates, {
				id = target.id,
				position = { x = target.position.X, z = target.position.Z },
				radius = target.radius,
			})
		end
		local snapped = Abilities.assist(
			{ x = origin.X, z = origin.Z },
			{ x = dir.X, z = dir.Z },
			candidates,
			reach,
			Config.get().classes.aimAssistCone
		)
		dir = Vector3.new(snapped.x, 0, snapped.z)
	end

	local point: Vector3? = nil
	local target = origin
	if ability.aim == "point" then
		local range = ability.range or 0
		local wanted = mouseGround() or (origin + dir * range * 0.7)
		local clamped = Abilities.clampPoint({ x = origin.X, z = origin.Z }, { x = wanted.X, z = wanted.Z }, range)
		point = Vector3.new(clamped.x, 0, clamped.z)
		target = point :: Vector3
		local toward = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
		if toward.Magnitude > 0.5 then
			dir = toward.Unit
		end
	end

	lastCast[class.id .. slot] = t
	r.CFrame = CFrame.lookAt(r.Position, r.Position + dir)
	CombatController.playCast()
	Feedback.playSound(Config.get().combat.sounds.swing, nil, 0.4)
	Net.fireServer(Remotes.AbilityCast, { slot = slot, direction = dir, point = point })

	-- Prediction: dash and effects.
	local from = origin
	if ability.dash then
		dash(dir, ability.dash)
		from = origin + dir * ability.dash
	end
	local delay = ability.delay or 0
	if ability.aim == "point" and ability.projectileSpeed then
		delay += (target - Vector3.new(origin.X, 0, origin.Z)).Magnitude / ability.projectileSpeed
	elseif ability.dash then
		delay += DASH_SECONDS
	end
	local fxTarget = if ability.aim == "point" then target else from
	if ability.shape and ability.shape.kind == "line" then
		fxTarget = from + dir * ability.shape.size
	end
	AbilityFx.play(class.id, slot, from, fxTarget, dir, delay)
	return true
end

-- Fraction of a slot's cooldown left: 1 just used, 0 ready.
function AbilityController.cooldown(slot: number): number
	local class = AbilityController.class()
	local ability = Abilities.slot(class, slot)
	if ability == nil or ability.cooldown <= 0 then
		return 0
	end
	return math.clamp(1 - (os.clock() - (lastCast[class.id .. slot] or -math.huge)) / ability.cooldown, 0, 1)
end

-- Whether the class's basic attack is the sword (CombatController handles it).
function AbilityController.meleeBasic(): boolean
	return AbilityController.class().basic.melee == true
end

-- The three ability slots for the HUD.
function AbilityController.slots(): { SlotInfo }
	local class = AbilityController.class()
	local lvl = level()
	local out: { SlotInfo } = {}
	for i, ability in class.abilities do
		table.insert(out, {
			slot = i,
			name = ability.name,
			glyph = ability.glyph,
			key = KEYS[i],
			unlocked = Abilities.unlocked(ability, lvl),
			unlockLevel = ability.unlockLevel,
			description = ability.description,
		})
	end
	return out
end

function AbilityController.start(_self: typeof(AbilityController))
	CombatController.basicOverride = function(): boolean
		if AbilityController.meleeBasic() then
			return false
		end
		AbilityController.cast(0)
		return true
	end
	local bindings: { { Enum.KeyCode } } = {
		{ Enum.KeyCode.One, Enum.KeyCode.ButtonL1 },
		{ Enum.KeyCode.Two, Enum.KeyCode.ButtonY },
		{ Enum.KeyCode.Three, Enum.KeyCode.ButtonR1 },
	}
	for slot, keys in bindings do
		ContextActionService:BindAction(`Ability{slot}`, function(_name, state: Enum.UserInputState)
			if state == Enum.UserInputState.Begin then
				AbilityController.cast(slot)
			end
			return Enum.ContextActionResult.Pass
		end, false, table.unpack(keys))
	end
	-- The server forgets cooldowns with the old character, so the client does too.
	player.CharacterAdded:Connect(function()
		table.clear(lastCast)
	end)
	Net.onClientEvent(Remotes.AbilityFx, function(event: Remotes.AbilityFxEvent)
		if event.slot >= 0 then
			CombatController.playSwingOn(event.caster)
		end
		AbilityFx.play(event.class, event.slot, event.origin, event.target, event.direction, event.delay)
	end)
end

return AbilityController
