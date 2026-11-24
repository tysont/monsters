--!strict
-- Class abilities (Phase 10): every cast, by players and class bots, goes through `cast`.
--
--   Casting: the client sends a slot, its aim direction and (for point abilities) a ground point.
--   The server checks the class, unlock level, cooldown, round phase and state (alive, not
--   stunned or launching), applies aim assist, and resolves the ability's shape: enemies and
--   allies in it get the ability's effects (Shared.Abilities, Shared.Classes). Damage goes
--   through CombatService.applyHit like every other hit.
--   Dashes: a player's client moves its own character (like a dodge); the server resolves the
--   shape where the dash ends (stopped by walls). Bots are moved here.
--   Delays and projectiles: point abilities resolve when their projectile lands or their delay
--   ends; lines (arrows, bolts) resolve at once.
--   Traps: placed at a point, armed after a moment, sprung by the first enemy in reach.
--   Status effects (Shared.Combat.Status) tick here: heal over time, expiry, and player
--   movement. Structures are immune to stun, slow and taunt. A stun interrupts a monster's attack.
--   Heals, heals over time and shields absorbing damage fire CombatService.supported (XP), and
--   make the healer a supporter of the ally (assists).
--
-- Clients get AbilityFx for every cast near them (the caster predicted its own) and see status
-- effects through the `Statuses` player attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Abilities = require(ReplicatedStorage.Shared.Abilities)
local Classes = require(ReplicatedStorage.Shared.Classes)
local Config = require(ReplicatedStorage.Shared.Config)
local Damage = require(ReplicatedStorage.Shared.Combat.Damage)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Status = require(ReplicatedStorage.Shared.Combat.Status)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local MonsterService = require("./MonsterService")
local NpcService = require("./NpcService")
local RoundService = require("./RoundService")

type Entry = CombatService.Entry

-- Clients farther than this from a cast do not hear about it.
local FX_RANGE = 250
-- Extra reach allowed for client-reported points (movement between client and server).
local POINT_TOLERANCE = 6
local MAX_RADIUS = 5
-- Seconds a dash takes on the client.
local DASH_SECONDS = 0.2

type Trap = {
	owner: Entry,
	ability: Classes.Ability,
	x: number,
	z: number,
	armAt: number,
	expiresAt: number,
	part: Part,
}

local AbilityService = {
	name = "AbilityService",
	dependencies = { "CharacterService", "CombatService", "MonsterService", "NpcService", "RoundService" },
	-- (caster, slot) after a successful cast (bots and tests).
	casted = Signal.new() :: Signal.Signal<Entry, number>,
}

-- Last cast time per slot, per entry (entries are replaced on respawn).
-- Keyed by class and slot ("mage1"), so switching class does not carry cooldowns over.
local lastCast: { [Entry]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any
-- Entries with status effects, for ticking.
local tracked: { [Entry]: string } = setmetatable({}, { __mode = "k" }) :: any
local traps: { Trap } = {}
local trapFolder: Folder

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rules(): Status.Rules
	return Config.get().classes.status
end

local function classOf(entry: Entry): Classes.Class?
	return if entry.classId then Config.get().classDefinitions[entry.classId] else nil
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function isMonster(entry: Entry): boolean
	return entry.kind == "npc" and MonsterService.monster(-entry.combatant.id) ~= nil
end

-- Candidates for shapes and aim assist: living hostiles near a point (not gated structures).
local function hostiles(
	team: number?,
	x: number,
	z: number,
	range: number
): ({ Abilities.Candidate }, { [number]: Entry })
	local list: { Abilities.Candidate } = {}
	local byId: { [number]: Entry } = {}
	CombatService.hostilesNear(team, x, z, range, function(entry)
		if entry.gated then
			return
		end
		local p = entry.position()
		if p then
			byId[entry.combatant.id] = entry
			table.insert(list, { id = entry.combatant.id, position = { x = p.X, z = p.Z }, radius = entry.radius })
		end
	end)
	return list, byId
end

-- Allies a support ability can affect: players and class bots on the team (never minions,
-- monsters or pets).
local function allies(
	team: number?,
	x: number,
	z: number,
	range: number
): ({ Abilities.Candidate }, { [number]: Entry })
	local list: { Abilities.Candidate } = {}
	local byId: { [number]: Entry } = {}
	CombatService.allNear(x, z, range + MAX_RADIUS, function(entry)
		if entry.combatant.team ~= team or not entry.combatant.alive then
			return
		end
		if entry.kind ~= "player" and entry.classId == nil then
			return
		end
		local p = entry.position()
		if p then
			local dx, dz = p.X - x, p.Z - z
			if dx * dx + dz * dz <= (range + entry.radius) ^ 2 then
				byId[entry.combatant.id] = entry
				table.insert(list, { id = entry.combatant.id, position = { x = p.X, z = p.Z }, radius = entry.radius })
			end
		end
	end)
	return list, byId
end

-- Status effects ----------------------------------------------------------------------------

local function publishStatuses(entry: Entry, t: number)
	local summary = Status.summary(entry.combatant.statuses, t)
	if tracked[entry] == summary then
		return
	end
	tracked[entry] = summary
	local player = entry.player
	if player then
		player:SetAttribute("Statuses", if summary ~= "" then summary else nil)
		CharacterService.applyMovement(player)
	end
end

local function applyStatus(source: Entry, target: Entry, effect: Classes.Effect, t: number): boolean
	local kind = effect.status :: Status.Kind
	if target.ccImmune and (kind == "stun" or kind == "slow" or kind == "taunt") then
		return false
	end
	local c = target.combatant
	if c.statuses == nil then
		c.statuses = Status.new()
	end
	local status: Status.Effect = {
		kind = effect.status :: Status.Kind,
		source = source.combatant.id,
		magnitude = Abilities.amount(effect, source.damage),
		duration = effect.duration or 0,
	}
	local applied = Status.apply(c.statuses :: Status.Set, status, t, c.maxHealth, rules())
	if applied then
		if tracked[target] == nil then
			tracked[target] = ""
		end
		if kind == "stun" and target.kind == "npc" then
			MonsterService.interrupt(-c.id, effect.duration or 0)
		end
		publishStatuses(target, t)
	end
	return applied
end

local function heal(source: Entry, target: Entry, amount: number, t: number): number
	local healed = Damage.heal(target.combatant, amount, source.combatant.id, t)
	if healed > 0 then
		CombatService.syncHealth(target)
		CombatService.supported:fire(source.combatant.id, target.combatant.id, healed)
	end
	return healed
end

local function tickStatuses(dt: number)
	local t = now()
	for entry in tracked do
		local c = entry.combatant
		local set = c.statuses
		if set == nil or not c.alive then
			tracked[entry] = nil
			if entry.player and c.statuses then
				entry.player:SetAttribute("Statuses", nil)
			end
			continue
		end
		for sourceId, amount in Status.regen(set, t, dt) do
			local source = CombatService.entry(sourceId)
			if source then
				heal(source, entry, amount, t)
			else
				Damage.heal(c, amount)
				CombatService.syncHealth(entry)
			end
		end
		Status.prune(set, t, rules())
		publishStatuses(entry, t)
		if #set.list == 0 then
			tracked[entry] = nil
		end
	end
end

-- Resolution --------------------------------------------------------------------------------

-- Applies a list of effects from `source` to one target. Enemy statuses only land if the hit
-- did (not dodged or protected).
local function applyEffects(
	source: Entry,
	target: Entry,
	effects: { Classes.Effect },
	cx: number,
	cz: number,
	dir: Vector3,
	t: number,
	hostile: boolean
)
	local landed = true
	if hostile then
		local c = target.combatant
		landed = c.alive and not c.protected and t >= c.invulnerableUntil
	end
	for _, effect in effects do
		if effect.kind == "damage" then
			local amount = source.damage * (effect.scale or 1)
			if effect.monsterBonus and isMonster(target) then
				amount *= effect.monsterBonus
			end
			local push = Vector3.zero
			local p = target.position()
			if effect.knockback and p then
				local away = Vector3.new(p.X - cx, 0, p.Z - cz)
				push = (if away.Magnitude > 0.5 then away.Unit else dir) * effect.knockback
			end
			local result = CombatService.applyHit(source.combatant.id, target.combatant.id, amount, "ability", push, t)
			landed = result ~= nil and result.applied
		elseif effect.kind == "heal" then
			heal(source, target, Abilities.amount(effect, source.damage), t)
		elseif effect.kind == "status" and landed and target.combatant.alive then
			applyStatus(source, target, effect, t)
		end
	end
end

local function resolve(
	caster: Entry,
	ability: Classes.Ability,
	origin: Vector3,
	centre: Vector3,
	dir: Vector3,
	t: number
)
	if not caster.combatant.alive and caster.kind ~= "player" then
		return
	end
	local shape = ability.shape
	local team = caster.combatant.team
	if ability.enemy and shape then
		-- Lines and cones start at the caster; circles sit on the centre.
		local from = if shape.kind == "circle" then centre else origin
		local candidates, byId = hostiles(team, from.X, from.Z, Abilities.bound(shape) + MAX_RADIUS)
		local ids = Abilities.targets(
			shape,
			{ x = from.X, z = from.Z },
			{ x = dir.X, z = dir.Z },
			candidates,
			ability.maxTargets
		)
		for _, id in ids do
			local target = byId[id]
			local p = target.position()
			-- Lines (arrows, bolts) and cones do not pass through walls.
			if p and (shape.kind == "circle" or CombatService.clearLine(from, p)) then
				applyEffects(caster, target, ability.enemy :: { Classes.Effect }, from.X, from.Z, dir, t, true)
			end
		end
	end
	if ability.ally then
		local effects = ability.ally :: { Classes.Effect }
		if ability.aim == "ally" then
			local range = ability.range or 0
			local candidates, byId = allies(team, origin.X, origin.Z, range)
			local chosen = Abilities.nearestToAim(
				{ x = origin.X, z = origin.Z },
				{ x = dir.X, z = dir.Z },
				candidates,
				range,
				Config.get().classes.allyAssistCone
			)
			-- Nobody in the aim (or aiming at yourself): yourself.
			local target = if chosen and chosen.id ~= caster.combatant.id then byId[chosen.id] else caster
			applyEffects(caster, target, effects, origin.X, origin.Z, dir, t, false)
		elseif shape then
			local _, byId = allies(team, centre.X, centre.Z, Abilities.bound(shape))
			local count = 0
			for _, target in byId do
				count += 1
				if count > (ability.maxTargets or math.huge) then
					break
				end
				applyEffects(caster, target, effects, centre.X, centre.Z, dir, t, false)
			end
		end
	end
	if ability.self then
		applyEffects(caster, caster, ability.self :: { Classes.Effect }, origin.X, origin.Z, dir, t, false)
	end
end

local function broadcast(
	caster: Entry,
	class: Classes.Class,
	slot: number,
	origin: Vector3,
	target: Vector3,
	dir: Vector3,
	delay: number
)
	local recipients: { Player } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		-- The caster predicted its own effects.
		if
			player ~= caster.player
			and root
			and root:IsA("BasePart")
			and (root.Position - origin).Magnitude <= FX_RANGE
		then
			table.insert(recipients, player)
		end
	end
	if #recipients > 0 then
		Net.fireClients(Remotes.AbilityFx, recipients, {
			caster = caster.combatant.id,
			class = class.id,
			slot = slot,
			origin = origin,
			target = target,
			direction = dir,
			delay = delay,
		})
	end
end

-- Traps -------------------------------------------------------------------------------------

local function placeTrap(caster: Entry, ability: Classes.Ability, centre: Vector3, t: number)
	local spec = ability.trap :: { arm: number, lifetime: number, trigger: number, max: number }
	-- At most `max` per caster: the oldest goes.
	local mine: { number } = {}
	for i, trap in traps do
		if trap.owner == caster and trap.ability == ability then
			table.insert(mine, i)
		end
	end
	while #mine >= spec.max do
		local index = table.remove(mine, 1) :: number
		traps[index].part:Destroy()
		table.remove(traps, index)
		for i = 1, #mine do
			mine[i] -= 1
		end
	end
	local part = Instance.new("Part")
	part.Name = "Trap"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.3, spec.trigger * 1.2, spec.trigger * 1.2)
	part.CFrame = CFrame.new(centre.X, 0.15, centre.Z) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	local class = classOf(caster)
	part.Color = if class then Color3.fromRGB(class.color[1], class.color[2], class.color[3]) else Color3.new(1, 1, 1)
	part.Transparency = 0.6
	part:SetAttribute("Team", caster.combatant.team)
	part.Parent = trapFolder
	table.insert(traps, {
		owner = caster,
		ability = ability,
		x = centre.X,
		z = centre.Z,
		armAt = t + spec.arm,
		expiresAt = t + spec.lifetime,
		part = part,
	})
end

local function tickTraps()
	local t = now()
	for i = #traps, 1, -1 do
		local trap = traps[i]
		local spec = trap.ability.trap :: { arm: number, lifetime: number, trigger: number, max: number }
		local sprung = false
		if t >= trap.armAt and t < trap.expiresAt then
			local candidates = hostiles(trap.owner.combatant.team, trap.x, trap.z, spec.trigger)
			sprung = #candidates > 0
		end
		if sprung or t >= trap.expiresAt then
			trap.part:Destroy()
			table.remove(traps, i)
			if sprung then
				local centre = Vector3.new(trap.x, 0, trap.z)
				resolve(trap.owner, trap.ability, centre, centre, Vector3.new(0, 0, -1), t)
				local class = classOf(trap.owner)
				if class then
					broadcast(trap.owner, class, -1, centre, centre, Vector3.new(0, 0, -1), 0)
				end
			end
		end
	end
end

-- Casting -----------------------------------------------------------------------------------

export type Aim = { direction: Vector3, point: Vector3? }

-- Casts slot `slot` (0 = basic) for `caster`. Returns nil on success or why it was refused.
-- `tolerance` forgives early arrival (players' network jitter).
function AbilityService.cast(caster: Entry, slot: number, aim: Aim, tolerance: number?): string?
	local class = classOf(caster)
	if class == nil then
		return "no class"
	end
	local ability = Abilities.slot(class, slot)
	if ability == nil then
		return "no ability in that slot"
	end
	local c = caster.combatant
	if not c.alive then
		return "dead"
	end
	if not Abilities.unlocked(ability, caster.level or 1) then
		return "locked"
	end
	local t = now()
	if Status.stunned(c.statuses, t) then
		return "stunned"
	end
	local casts = lastCast[caster]
	if casts == nil then
		casts = {}
		lastCast[caster] = casts
	end
	local cooldown = ability.cooldown
	local key = class.id .. slot
	if not Abilities.ready(casts[key], t, cooldown, tolerance or 0) then
		return "cooldown"
	end
	local origin = caster.position()
	if origin == nil then
		return "no position"
	end
	local dir = flat(aim.direction)

	if ability.melee then
		-- Melee basics (the Knight's sword) use the player melee path.
		casts[key] = t
		CombatService.meleeSwing(caster, dir, 0, t)
		AbilityService.casted:fire(caster, slot)
		return nil
	end

	-- Aim assist for direction aim: snap to the enemy nearest the aim.
	if ability.aim == "direction" then
		local reach = ability.range or (if ability.shape then ability.shape.size else 0)
		local candidates = hostiles(c.team, origin.X, origin.Z, reach + MAX_RADIUS)
		local snapped = Abilities.assist(
			{ x = origin.X, z = origin.Z },
			{ x = dir.X, z = dir.Z },
			candidates,
			reach,
			Config.get().classes.aimAssistCone
		)
		dir = Vector3.new(snapped.x, 0, snapped.z)
	end
	casts[key] = t

	-- Dash: bots are moved here; players' clients move themselves.
	local from = origin
	if ability.dash then
		local wanted = Abilities.dashEnd(ability, { x = origin.X, z = origin.Z }, { x = dir.X, z = dir.Z })
		local target = Vector3.new(wanted.x, origin.Y, wanted.z)
		from = CombatService.clampMove(origin, target)
		if caster.kind ~= "player" then
			local row = NpcService.row(-c.id)
			if row then
				row.x, row.z = from.X, from.Z
				CombatService.moved(caster)
			end
		end
	end

	local point = aim.point
	local centre: Vector3
	if ability.aim == "point" then
		local range = (ability.range or 0) + (if caster.kind == "player" then POINT_TOLERANCE else 0)
		local clamped = Abilities.clampPoint(
			{ x = origin.X, z = origin.Z },
			if point then { x = point.X, z = point.Z } else { x = origin.X, z = origin.Z },
			range
		)
		centre = Vector3.new(clamped.x, 0, clamped.z)
		local toward = Vector3.new(centre.X - origin.X, 0, centre.Z - origin.Z)
		if toward.Magnitude > 0.5 then
			dir = toward.Unit
		end
	else
		centre = from
	end

	-- When it resolves: after the delay, or when a point projectile lands.
	local delay = ability.delay or 0
	if ability.aim == "point" and ability.projectileSpeed then
		delay += (centre - Vector3.new(origin.X, 0, origin.Z)).Magnitude / ability.projectileSpeed
	elseif ability.dash then
		delay += DASH_SECONDS
	end
	local fxTarget = centre
	if ability.shape and ability.shape.kind == "line" then
		fxTarget = from + dir * ability.shape.size
	end
	broadcast(caster, class, slot, from, fxTarget, dir, delay)

	if ability.trap then
		placeTrap(caster, ability, centre, t)
	elseif delay > 0 then
		task.delay(delay, function()
			if Round.inputAllowed(RoundService.state().phase) then
				resolve(caster, ability, from, centre, dir, now())
			end
		end)
	else
		resolve(caster, ability, from, centre, dir, t)
	end
	AbilityService.casted:fire(caster, slot)
	return nil
end

-- Dev: forgets cooldowns for an entry.
function AbilityService.resetCooldowns(entry: Entry)
	lastCast[entry] = nil
end

-- Dev: how many traps are out.
function AbilityService.trapCount(): number
	return #traps
end

local function onCast(player: Player, request: Remotes.AbilityCastRequest)
	local entry = CombatService.entry(player.UserId)
	if entry == nil or not Round.inputAllowed(RoundService.state().phase) or player:GetAttribute("Launching") then
		return
	end
	local class = classOf(entry)
	local ability = class and Abilities.slot(class, request.slot)
	if ability == nil or ability.melee then
		return
	end
	-- Egg carriers cannot dash (they would outrun the carry speed).
	if ability.dash and player:GetAttribute("CarryingEgg") ~= nil then
		return
	end
	local reason = AbilityService.cast(
		entry,
		request.slot,
		{ direction = request.direction, point = request.point },
		Config.get().classes.cooldownTolerance
	)
	-- Studio: say why a cast was refused (cooldown refusals are normal and not logged).
	if reason and reason ~= "cooldown" and RunService:IsStudio() then
		print(`[Abilities] {player.Name} slot {request.slot}: {reason}`)
	end
end

function AbilityService.init(_self: typeof(AbilityService))
	local folder = Instance.new("Folder")
	folder.Name = "Traps"
	folder.Parent = workspace
	trapFolder = folder

	CharacterService.statusScale = function(player: Player): number
		local entry = CombatService.entry(player.UserId)
		if entry == nil then
			return 1
		end
		return Status.speedMultiplier(entry.combatant.statuses, now(), rules())
	end
	Net.onServerEvent(Remotes.AbilityCast, onCast)
	RoundService.roundReset:connect(function()
		for _, trap in traps do
			trap.part:Destroy()
		end
		table.clear(traps)
	end)

	local since = 0
	RunService.Heartbeat:Connect(function(dt: number)
		since += dt
		local step = Config.get().classes.statusTickSeconds
		if since < step then
			return
		end
		local elapsed = since
		since = 0
		tickStatuses(elapsed)
		tickTraps()
	end)
end

return AbilityService
