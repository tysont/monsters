--!strict
-- Eggs and hatcheries: the egg loop inside a round (rules in Shared.Eggs).
--
--   Eggs drop at cleared camps. Anyone can pick up a dropped egg (hold prompt). A carrier walks at
--   70% speed, cannot dodge, shows on enemy minimaps when enemies are near (client), and drops
--   the egg where they fall. Dropped eggs vanish after a while.
--   Hatcheries (one per lane per team, from the map markers) have 4 slots. A carrier deposits at
--   their own team's hatchery; incubation takes 60 to 240 s by rarity. The depositor owns the egg.
--   An enemy can raid an incubating egg (hold prompt) once that lane's outer guardian is dead; the
--   defending team is alerted when the raid starts. The raider carries it home and incubation
--   starts over.
--   When an egg hatches, its owner chooses: claim as a pet or feed to a pet (recorded as player
--   attributes until Phase 9 adds pets), or unleash it as an allied monster on that hatchery's
--   lane. No choice in time, or an absent owner, unleashes it.
--   Round reset clears every egg.
--
-- Eggs and hatcheries are a handful of server parts. Their state replicates as attributes
-- (eggs: State, Kind, Rarity, Team, Carrier, Hatchery, EndsAt; hatcheries: Team, Lane, Raidable,
-- Free) for the client HUD, world labels and minimap. Every interaction is checked on the server
-- (range, state, team, rate) and carriers' movement is validated.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Eggs = require(ReplicatedStorage.Shared.Eggs)
local Map = require(ReplicatedStorage.Shared.Map)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Structures = require(ReplicatedStorage.Shared.Combat.Structures)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local MonsterService = require("./MonsterService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

local PICKUP_RANGE = 12
local HATCHERY_RANGE = 18
local MOVE_CHECK_SECONDS = 0.5
-- Carriers who were just hit are not movement-checked (knockback).
local HIT_GRACE = 1.5

export type Egg = {
	id: number,
	kind: string,
	rarity: string,
	state: Eggs.State,
	part: BasePart,
	prompt: ProximityPrompt,
	carrier: Player?,
	-- The depositor, once incubating.
	owner: Player?,
	ownerTeam: number?,
	hatchery: Hatchery?,
	slot: number,
	endsAt: number,
	-- Dropped: when it vanishes. Hatched: when the choice times out.
	expiresAt: number,
}

export type Hatchery = {
	key: string,
	team: number,
	lane: Map.LaneId,
	position: Vector3,
	model: Model,
	slots: { Egg | false },
	depositPrompt: ProximityPrompt,
	raidPrompt: ProximityPrompt,
}

local EggService = {
	name = "EggService",
	dependencies = { "CharacterService", "CombatService", "MonsterService", "RoundService", "TeamService" },
	-- (player, egg)
	pickedUp = Signal.new() :: Signal.Signal<Player, Egg>,
	deposited = Signal.new() :: Signal.Signal<Player, Egg>,
	raided = Signal.new() :: Signal.Signal<Player, Egg>,
	-- (egg, choice)
	hatched = Signal.new() :: Signal.Signal<Egg, string>,
	-- Pet hooks (ProgressionService): claim a hatched monster as a pet (replacing `target` if the
	-- stable is full), or feed it to pet `target`. Defaults refuse.
	claimPet = function(_player: Player, _kind: string, _target: number?): boolean
		return false
	end,
	feedPet = function(_player: Player, _target: number?, _kind: string, _rarity: string): number
		return 0
	end,
}

local RARITY_COLORS: { [string]: Color3 } = {
	common = Color3.fromRGB(190, 195, 205),
	rare = Color3.fromRGB(80, 160, 255),
	epic = Color3.fromRGB(180, 100, 255),
	legendary = Color3.fromRGB(255, 180, 50),
}

local eggs: { [number]: Egg } = {}
local carried: { [Player]: Egg } = {}
local hatcheries: { [string]: Hatchery } = {}
local lastInteract: { [Player]: number } = {}
local lastValid: { [Player]: { position: Vector3, at: number } } = {}
local nextId = 1
local folder: Folder

local function now(): number
	return workspace:GetServerTimeNow()
end

local function config(): Config.EggConfig
	return Config.get().eggs
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Rate limit for egg interactions.
local function allowInteract(player: Player): boolean
	local t = now()
	if t - (lastInteract[player] or -math.huge) < config().interactCooldown then
		return false
	end
	lastInteract[player] = t
	return true
end

local function publish(egg: Egg)
	local part = egg.part
	part:SetAttribute("State", egg.state)
	part:SetAttribute("Team", egg.ownerTeam)
	part:SetAttribute("Carrier", if egg.carrier then egg.carrier.UserId else nil)
	part:SetAttribute("Hatchery", if egg.hatchery then egg.hatchery.key else nil)
	part:SetAttribute("EndsAt", if egg.state == "incubating" then egg.endsAt else nil)
	part:SetAttribute("ExpiresAt", egg.expiresAt)
	egg.prompt.Enabled = egg.state == "dropped"
end

local function publishHatchery(h: Hatchery)
	local free = 0
	for _, slot in h.slots do
		if slot == false then
			free += 1
		end
	end
	h.model:SetAttribute("Free", free)
	local outerDead = MonsterService.isDead(Structures.key("outerGuardian", h.team, h.lane))
	h.model:SetAttribute("Raidable", outerDead or not config().raidRequiresOuterGuardian)
end

local function setCarrying(player: Player, egg: Egg?)
	if egg then
		carried[player] = egg
		player:SetAttribute("CarryingEgg", `{egg.rarity} {egg.kind}`)
		local root = rootOf(player)
		if root then
			lastValid[player] = { position = root.Position, at = now() }
		end
	else
		carried[player] = nil
		player:SetAttribute("CarryingEgg", nil)
		lastValid[player] = nil
	end
	CharacterService.applyMovement(player)
end

local function remove(egg: Egg)
	if eggs[egg.id] ~= egg then
		return
	end
	eggs[egg.id] = nil
	if egg.carrier then
		setCarrying(egg.carrier :: Player, nil)
	end
	local h = egg.hatchery
	if h and h.slots[egg.slot] == egg then
		h.slots[egg.slot] = false
		publishHatchery(h)
	end
	egg.part:Destroy()
end

-- Puts an egg on the ground at `position`.
local function placeOnGround(egg: Egg, position: Vector3)
	local weld = egg.part:FindFirstChildOfClass("WeldConstraint")
	if weld then
		weld:Destroy()
	end
	egg.part.Anchored = true
	egg.part.CFrame = CFrame.new(position.X, 1.6, position.Z)
	egg.part.Parent = folder
	egg.state = "dropped"
	egg.carrier = nil
	egg.hatchery = nil
	egg.expiresAt = now() + config().droppedSeconds
	publish(egg)
end

-- Attaches an egg to a player's back.
local function carry(player: Player, egg: Egg): boolean
	local root = rootOf(player)
	if root == nil or carried[player] then
		return false
	end
	local h = egg.hatchery
	if h and h.slots[egg.slot] == egg then
		h.slots[egg.slot] = false
		publishHatchery(h)
	end
	egg.hatchery = nil
	egg.state = "carried"
	egg.carrier = player
	egg.expiresAt = 0
	local part = egg.part
	part.Anchored = false
	part.Massless = true
	part.CFrame = root.CFrame * CFrame.new(0, 1.2, 1.4)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
	part.Parent = player.Character
	setCarrying(player, egg)
	publish(egg)
	return true
end

local function drop(player: Player)
	local egg = carried[player]
	if egg == nil then
		return
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local position = if root and root:IsA("BasePart") then root.Position else egg.part.Position
	setCarrying(player, nil)
	placeOnGround(egg, position)
end

local function newEgg(kind: string, rarity: string): Egg
	local id = nextId
	nextId += 1
	local part = Instance.new("Part")
	part.Name = `Egg_{kind}_{id}`
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2.4, 3, 2.4)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = RARITY_COLORS[rarity] or RARITY_COLORS.common
	part:SetAttribute("EggId", id)
	CollectionService:AddTag(part, "Egg")
	part:SetAttribute("Kind", kind)
	part:SetAttribute("Rarity", rarity)
	local light = Instance.new("PointLight")
	light.Color = part.Color
	light.Range = 10
	light.Parent = part
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up"
	prompt.ObjectText = `{rarity} {kind} egg`
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = PICKUP_RANGE - 2
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	local egg: Egg = {
		id = id,
		kind = kind,
		rarity = rarity,
		state = "dropped",
		part = part,
		prompt = prompt,
		carrier = nil,
		owner = nil,
		ownerTeam = nil,
		hatchery = nil,
		slot = 0,
		endsAt = 0,
		expiresAt = 0,
	}
	prompt.Triggered:Connect(function(player: Player)
		if eggs[egg.id] ~= egg or not Eggs.canPickUp(egg.state) or not allowInteract(player) then
			return
		end
		local root = rootOf(player)
		if root == nil or (root.Position - part.Position).Magnitude > PICKUP_RANGE then
			return
		end
		if carry(player, egg) then
			EggService.pickedUp:fire(player, egg)
		end
	end)
	eggs[id] = egg
	return egg
end

-- Drops a new egg of `kind` and `rarity` at a ground position. Returns it.
function EggService.drop(kind: string, rarity: string, position: Vector3): Egg
	local egg = newEgg(kind, rarity)
	placeOnGround(egg, position)
	return egg
end

-- Hatcheries ---------------------------------------------------------------------------------

local function slotPosition(h: Hatchery, slot: number): Vector3
	local angle = (slot - 0.5) / #h.slots * 2 * math.pi
	return h.position + Vector3.new(math.cos(angle) * 5, 2.2, math.sin(angle) * 5)
end

local function deposit(player: Player, h: Hatchery)
	local egg = carried[player]
	if egg == nil or not allowInteract(player) then
		return
	end
	local root = rootOf(player)
	if root == nil or (root.Position - h.position).Magnitude > HATCHERY_RANGE then
		return
	end
	local free: number? = nil
	for i, slot in h.slots do
		if slot == false then
			free = i
			break
		end
	end
	if not Eggs.canDeposit(TeamService.teamOf(player), h.team, if free then 1 else 0) then
		return
	end
	local slot = free :: number
	setCarrying(player, nil)
	local weld = egg.part:FindFirstChildOfClass("WeldConstraint")
	if weld then
		weld:Destroy()
	end
	egg.part.Anchored = true
	egg.part.CFrame = CFrame.new(slotPosition(h, slot))
	egg.part.Parent = folder
	egg.state = "incubating"
	egg.carrier = nil
	egg.owner = player
	egg.ownerTeam = h.team
	egg.hatchery = h
	egg.slot = slot
	egg.endsAt = now() + Eggs.incubationSeconds(egg.rarity, config())
	egg.expiresAt = 0
	h.slots[slot] = egg
	publish(egg)
	publishHatchery(h)
	EggService.deposited:fire(player, egg)
end

local function incubatingIn(h: Hatchery): { Egg }
	local list: { Egg } = {}
	for _, slot in h.slots do
		local egg = if slot == false then nil else slot :: Egg
		if egg and egg.state == "incubating" then
			table.insert(list, egg)
		end
	end
	return list
end

local function raid(player: Player, h: Hatchery)
	if not allowInteract(player) then
		return
	end
	local root = rootOf(player)
	if root == nil or (root.Position - h.position).Magnitude > HATCHERY_RANGE then
		return
	end
	local list = incubatingIn(h)
	local outerDead = MonsterService.isDead(Structures.key("outerGuardian", h.team, h.lane))
	if not Eggs.canRaid(TeamService.teamOf(player), h.team, outerDead, #list, carried[player] ~= nil, config()) then
		return
	end
	local ends: { number } = {}
	for _, egg in list do
		table.insert(ends, egg.endsAt)
	end
	local egg = list[Eggs.raidPick(ends) :: number]
	egg.owner = nil
	egg.ownerTeam = nil
	if carry(player, egg) then
		EggService.raided:fire(player, egg)
	end
end

local function buildHatchery(marker: Map.Marker): Hatchery
	local team = marker.team :: number
	local lane = marker.lane :: Map.LaneId
	local key = `H{team}_{lane}`
	local position = Vector3.new(marker.position.x, 0, marker.position.z)
	local model = Instance.new("Model")
	model.Name = key
	local teamColor = BrickColor.new(Config.get().teams[team].brickColor :: any).Color
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Shape = Enum.PartType.Cylinder
	base.Size = Vector3.new(1, 16, 16)
	base.CFrame = CFrame.new(position + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
	base.Anchored = true
	base.CanCollide = false
	base.Material = Enum.Material.Slate
	base.Color = teamColor:Lerp(Color3.fromRGB(60, 60, 64), 0.5)
	base.Parent = model
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Size = Vector3.new(2, 3, 2)
	core.CFrame = CFrame.new(position + Vector3.new(0, 2.5, 0))
	core.Anchored = true
	core.CanCollide = false
	core.Material = Enum.Material.Neon
	core.Color = teamColor
	core.Parent = model
	local slots: { Egg | false } = {}
	for i = 1, config().slots do
		slots[i] = false
	end
	local h: Hatchery
	local depositPrompt = Instance.new("ProximityPrompt")
	depositPrompt.Name = "Deposit"
	depositPrompt.ActionText = "Deposit egg"
	depositPrompt.ObjectText = "Hatchery"
	depositPrompt.HoldDuration = 0.3
	depositPrompt.MaxActivationDistance = HATCHERY_RANGE - 4
	depositPrompt.RequiresLineOfSight = false
	depositPrompt:SetAttribute("Team", team)
	depositPrompt.Parent = core
	local raidPrompt = Instance.new("ProximityPrompt")
	raidPrompt.Name = "Raid"
	raidPrompt.ActionText = "Steal egg"
	raidPrompt.ObjectText = "Enemy hatchery"
	raidPrompt.HoldDuration = config().raidSeconds
	raidPrompt.MaxActivationDistance = HATCHERY_RANGE - 4
	raidPrompt.RequiresLineOfSight = false
	raidPrompt.KeyboardKeyCode = Enum.KeyCode.F
	raidPrompt:SetAttribute("Team", team)
	raidPrompt.Parent = core
	model:SetAttribute("Team", team)
	model:SetAttribute("Lane", lane)
	model.Parent = workspace:WaitForChild("Hatcheries")
	h = {
		key = key,
		team = team,
		lane = lane :: Map.LaneId,
		position = position,
		model = model,
		slots = slots,
		depositPrompt = depositPrompt,
		raidPrompt = raidPrompt,
	}
	depositPrompt.Triggered:Connect(function(player: Player)
		deposit(player, h)
	end)
	raidPrompt.Triggered:Connect(function(player: Player)
		raid(player, h)
	end)
	raidPrompt.PromptButtonHoldBegan:Connect(function(player: Player)
		local raiderTeam = TeamService.teamOf(player)
		if raiderTeam == nil or raiderTeam == team or #incubatingIn(h) == 0 then
			return
		end
		local recipients: { Player } = {}
		for _, other in Players:GetPlayers() do
			if TeamService.teamOf(other) == team then
				table.insert(recipients, other)
			end
		end
		Net.fireClients(Remotes.RaidAlert, recipients, { hatchery = key, lane = lane, raider = player.DisplayName })
	end)
	publishHatchery(h)
	return h
end

-- Hatching -----------------------------------------------------------------------------------

local function unleash(egg: Egg)
	local h = egg.hatchery
	if h == nil then
		remove(egg)
		return
	end
	local scale = Eggs.rarityScale(egg.rarity, config())
	local monsterId = egg.kind
	if Config.get().monsters[monsterId] then
		MonsterService.spawn(monsterId, h.position + Vector3.new(0, 0, 0), h.team, {
			lane = h.lane,
			owner = if egg.owner then (egg.owner :: Player).UserId else nil,
			healthScale = scale,
			damageScale = scale,
		})
	end
	EggService.hatched:fire(egg, "unleash")
	remove(egg)
end

local function onHatched(egg: Egg)
	egg.state = "hatched"
	egg.expiresAt = now() + config().choiceSeconds
	publish(egg)
	local owner = egg.owner
	if owner == nil or owner.Parent == nil then
		unleash(egg)
		return
	end
	Net.fireClient(Remotes.HatchReady, owner, {
		egg = egg.id,
		kind = egg.kind,
		rarity = egg.rarity,
		hatchery = (egg.hatchery :: Hatchery).key,
		expiresAt = egg.expiresAt,
	})
end

local function onChoice(player: Player, request: Remotes.HatchChoiceRequest)
	local egg = eggs[request.egg]
	if egg == nil or egg.state ~= "hatched" or egg.owner ~= player or not Eggs.isChoice(request.choice) then
		return
	end
	if request.choice == "unleash" then
		unleash(egg)
		return
	end
	-- Claim and feed go to the pet system (ProgressionService sets these hooks). A claim that
	-- cannot fit (full stable, no pet chosen to replace) keeps the egg so the owner can choose
	-- again.
	local done = if request.choice == "claim"
		then EggService.claimPet(player, egg.kind, request.target)
		else EggService.feedPet(player, request.target, egg.kind, egg.rarity) > 0
	if not done then
		return
	end
	EggService.hatched:fire(egg, request.choice)
	remove(egg)
end

-- Ticking ------------------------------------------------------------------------------------

local function tick()
	local t = now()
	for _, egg in eggs do
		if egg.state == "dropped" and t >= egg.expiresAt then
			remove(egg)
		elseif egg.state == "incubating" and t >= egg.endsAt then
			onHatched(egg)
		elseif egg.state == "hatched" and t >= egg.expiresAt then
			unleash(egg)
		end
	end
	for _, h in hatcheries do
		publishHatchery(h)
	end
end

-- Carriers cannot move faster than the slowed walk allows; a carrier who does is put back.
local function validateCarriers()
	local t = now()
	local walk = Map.get().walkSpeed
	for player in carried do
		local root = rootOf(player)
		local valid = lastValid[player]
		if root == nil then
			drop(player)
		elseif valid then
			local entry = CombatService.entry(player.UserId)
			local recentlyHit = entry ~= nil and t - entry.combatant.lastDamagedAt < HIT_GRACE
			local flat = Vector3.new(root.Position.X - valid.position.X, 0, root.Position.Z - valid.position.Z)
			if recentlyHit or Eggs.validCarrierMove(flat.Magnitude, t - valid.at, walk, config()) then
				lastValid[player] = { position = root.Position, at = t }
			else
				local character = player.Character :: Model
				character:PivotTo(CFrame.new(valid.position) * character:GetPivot().Rotation)
				lastValid[player] = { position = valid.position, at = t }
				warn(`[Eggs] {player.Name} moved too fast while carrying an egg; put back`)
			end
		end
	end
end

-- Dev and test access ------------------------------------------------------------------------

function EggService.hatchery(key: string): Hatchery?
	return hatcheries[key]
end

function EggService.carrying(player: Player): Egg?
	return carried[player]
end

-- Dev: gives a player an egg to carry.
function EggService.give(player: Player, kind: string, rarity: string): boolean
	local egg = newEgg(kind, rarity)
	if carry(player, egg) then
		return true
	end
	egg.part:Destroy()
	eggs[egg.id] = nil
	return false
end

-- Dev: finishes incubation of every egg in a hatchery now.
function EggService.hatchNow(key: string): number
	local h = hatcheries[key]
	local n = 0
	if h then
		for _, egg in incubatingIn(h) do
			egg.endsAt = now()
			n += 1
		end
	end
	return n
end

-- Dev: deposits directly (used by tests driving bots).
function EggService.deposit(player: Player, key: string)
	local h = hatcheries[key]
	if h then
		lastInteract[player] = nil
		deposit(player, h)
	end
end

function EggService.raid(player: Player, key: string)
	local h = hatcheries[key]
	if h then
		lastInteract[player] = nil
		raid(player, h)
	end
end

-- Removes every egg. Returns how many.
function EggService.clear(): number
	local n = 0
	for _, egg in eggs do
		remove(egg)
		n += 1
	end
	return n
end

function EggService.count(): number
	local n = 0
	for _ in eggs do
		n += 1
	end
	return n
end

function EggService.describe(): string
	local lines = {}
	for _, egg in eggs do
		local where = if egg.carrier
			then `carried by {egg.carrier.Name}`
			elseif egg.hatchery then `{egg.hatchery.key} slot {egg.slot}`
			else "on the ground"
		local timeText = if egg.state == "incubating" then ` hatches in {math.ceil(egg.endsAt - now())} s` else ""
		table.insert(lines, `#{egg.id} {egg.rarity} {egg.kind} {egg.state}, {where}{timeText}`)
	end
	return if #lines > 0 then table.concat(lines, " | ") else "No eggs."
end

function EggService.init(_self: typeof(EggService))
	local f = Instance.new("Folder")
	f.Name = "Eggs"
	f.Parent = workspace
	folder = f
	local hf = Instance.new("Folder")
	hf.Name = "Hatcheries"
	hf.Parent = workspace

	CharacterService.speedScale = function(player: Player): number
		return if carried[player] then config().carrySpeedScale else 1
	end
	CombatService.canDodge = function(player: Player): boolean
		return carried[player] == nil
	end
	CharacterService.characterSpawned:connect(function(player: Player, character: Model)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Died:Connect(function()
				drop(player)
			end)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		drop(player)
		lastInteract[player] = nil
		-- Their incubating and hatched eggs lose an owner (hatched ones unleash on time).
		for _, egg in eggs do
			if egg.owner == player then
				egg.owner = nil
			end
		end
	end)
	Net.onServerEvent(Remotes.HatchChoice, onChoice)
	RoundService.roundReset:connect(function()
		EggService.clear()
	end)
	MonsterService.structureDestroyed:connect(function()
		for _, h in hatcheries do
			publishHatchery(h)
		end
	end)
end

function EggService.start(_self: typeof(EggService))
	for _, marker in Map.markersOf(Map.get(), "hatchery") do
		local h = buildHatchery(marker)
		hatcheries[h.key] = h
	end
	local since = 0
	RunService.Heartbeat:Connect(function(dt: number)
		since += dt
		if since >= MOVE_CHECK_SECONDS then
			since = 0
			validateCarriers()
		end
	end)
	while true do
		task.wait(1)
		tick()
	end
end

return EggService
