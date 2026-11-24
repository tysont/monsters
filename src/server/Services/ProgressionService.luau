--!strict
-- Levels, XP and pets on top of player profiles (rules in Shared.Progression).
--
--   XP sources (all to the active class, with catch-up): minion proximity credit, camp monsters
--   (shared by whoever damaged them), camp clears, structures (the attacking team nearby), player
--   kills and assists, egg deposits, raids and hatches, round win or loss, and damage dealt by
--   monsters you unleashed.
--   Level-ups update stats at once (max health and damage), the nameplate attributes, and team
--   strength. Combat power is the class level multiplier times the active pet's multiplier.
--   Pets: claim adds a hatched monster to the stable (replacing one if full); feed turns it into
--   pet XP for a chosen pet, more for a matching type.
--
-- Player attributes for the HUD and nameplates: ClassLevel, ClassXp, ClassXpNext, ActiveClass,
-- AccountLevel, Title, PetSlots, Power.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Profile = require(ReplicatedStorage.Shared.Profile)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Stats = require(ReplicatedStorage.Shared.Combat.Stats)

local CampService = require("./CampService")
local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local DataService = require("./DataService")
local EggService = require("./EggService")
local MonsterService = require("./MonsterService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

local ProgressionService = {
	name = "ProgressionService",
	dependencies = {
		"CampService",
		"CharacterService",
		"CombatService",
		"DataService",
		"EggService",
		"MonsterService",
		"RoundService",
		"TeamService",
	},
	-- (player, new level)
	leveledUp = Signal.new() :: Signal.Signal<Player, number>,
	-- (player) when the active pet or its power changes.
	petChanged = Signal.new() :: Signal.Signal<Player>,
}

-- Fractional XP carried between small awards (unleash damage), per player.
local carry: { [Player]: number } = {}

local function config(): Config.ProgressionConfig
	return Config.get().progression
end

local function activeProgress(data: Profile.Data): Profile.ClassData
	local progress = data.classes[data.activeClass]
	if progress == nil then
		progress = { level = 1, xp = 0 }
		data.classes[data.activeClass] = progress
	end
	return progress
end

local function activePetXp(data: Profile.Data): number?
	local pet = Profile.pet(data, data.activePet)
	return if pet then pet.xp else nil
end

function ProgressionService.power(player: Player): number
	local data = DataService.get(player)
	if data == nil then
		return 1
	end
	return Progression.power(activeProgress(data).level, activePetXp(data), config())
end

-- Applies the current level and pet to the live character (health keeps its fraction).
local function applyStats(player: Player)
	local data = DataService.get(player)
	local entry = CombatService.entry(player.UserId)
	if data == nil or entry == nil then
		return
	end
	local level = activeProgress(data).level
	local petMultiplier = Progression.petMultiplier(activePetXp(data) or 0, config())
	local stats = Stats.compute(Config.get().combat.knight, level, if data.activePet ~= 0 then petMultiplier else 1)
	local c = entry.combatant
	local fraction = if c.maxHealth > 0 then c.health / c.maxHealth else 1
	c.maxHealth = stats.maxHealth
	c.health = math.max(1, math.floor(stats.maxHealth * fraction + 0.5))
	entry.damage = stats.damage
	entry.power = stats.power
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.MaxHealth = c.maxHealth
		humanoid.Health = c.health
	end
end

-- Pets as JSON for the stable screen (kind, XP, multiplier, active).
local function petsJson(data: Profile.Data): string
	local list = {}
	for _, pet in data.pets do
		table.insert(list, {
			id = pet.id,
			kind = pet.kind,
			xp = math.floor(pet.xp),
			multiplier = math.floor(Progression.petMultiplier(pet.xp, config()) * 1000 + 0.5) / 1000,
			active = pet.id == data.activePet,
		})
	end
	return HttpService:JSONEncode(list)
end

local function publish(player: Player)
	local data = DataService.get(player)
	if data == nil then
		return
	end
	local progress = activeProgress(data)
	local account = Progression.accountLevel(data.classes)
	local titles = Progression.titles(account, config())
	player:SetAttribute("ClassLevel", progress.level)
	player:SetAttribute("ClassXp", math.floor(progress.xp))
	player:SetAttribute("ClassXpNext", Progression.xpToNext(progress.level, config()))
	player:SetAttribute("ActiveClass", data.activeClass)
	player:SetAttribute("AccountLevel", account)
	player:SetAttribute("Title", titles[#titles])
	player:SetAttribute("PetSlots", Progression.petSlots(account, config()))
	player:SetAttribute("Power", math.floor(ProgressionService.power(player) * 1000 + 0.5) / 1000)
	player:SetAttribute("Pets", petsJson(data))
end

local function refreshPower(player: Player)
	publish(player)
	applyStats(player)
	TeamService.refresh()
end

-- Awards XP to a player's active class. Returns the XP actually gained.
function ProgressionService.award(player: Player, amount: number, _reason: string): number
	local data = DataService.get(player)
	if data == nil or amount <= 0 then
		return 0
	end
	local progress = activeProgress(data)
	local result = Progression.award(progress, Progression.highestLevel(data.classes), amount, config())
	if result.levelsGained > 0 then
		ProgressionService.leveledUp:fire(player, progress.level)
		Net.fireClient(Remotes.LevelUp, player, { level = progress.level, class = data.activeClass })
		refreshPower(player)
	else
		publish(player)
	end
	return result.gained
end

local function awardNear(position: Vector3, team: number?, range: number, amount: number, reason: string)
	for _, player in Players:GetPlayers() do
		local entry = CombatService.entry(player.UserId)
		local p = entry and entry.position()
		if entry and p and (team == nil or entry.combatant.team == team) and (p - position).Magnitude <= range then
			ProgressionService.award(player, amount, reason)
		end
	end
end

-- Pets ---------------------------------------------------------------------------------------

-- Claims a hatched monster as a pet. `replace` is the pet to replace when the stable is full.
-- Returns whether it was added.
function ProgressionService.claim(player: Player, kind: string, replace: number?): boolean
	local data = DataService.get(player)
	if data == nil then
		return false
	end
	local slots = Progression.petSlots(Progression.accountLevel(data.classes), config())
	local pet = Profile.addPet(data, kind, slots)
	if pet == nil and replace then
		pet = Profile.replacePet(data, replace, kind)
	end
	if pet == nil then
		return false
	end
	refreshPower(player)
	ProgressionService.petChanged:fire(player)
	return true
end

-- Feeds a hatched monster to pet `petId`. Returns the pet XP given (0 if no such pet).
function ProgressionService.feed(player: Player, petId: number?, kind: string, rarity: string): number
	local data = DataService.get(player)
	if data == nil then
		return 0
	end
	local pet = Profile.pet(data, petId or data.activePet)
	if pet == nil then
		return 0
	end
	local xp = Progression.feedXp(rarity, kind, pet.kind, config())
	pet.xp += xp
	refreshPower(player)
	ProgressionService.petChanged:fire(player)
	return xp
end

function ProgressionService.setActivePet(player: Player, petId: number): boolean
	local data = DataService.get(player)
	if data == nil or (petId ~= 0 and Profile.pet(data, petId) == nil) then
		return false
	end
	data.activePet = petId
	refreshPower(player)
	ProgressionService.petChanged:fire(player)
	return true
end

-- Dev: sets the active class level.
function ProgressionService.setLevel(player: Player, level: number)
	local data = DataService.get(player)
	if data then
		local progress = activeProgress(data)
		progress.level = math.max(1, math.floor(level))
		progress.xp = 0
		refreshPower(player)
	end
end

function ProgressionService.refresh(player: Player)
	refreshPower(player)
end

-- Wiring -------------------------------------------------------------------------------------

function ProgressionService.init(_self: typeof(ProgressionService))
	local xp = config().xp
	CombatService.classLevelOf = function(player: Player): number
		local data = DataService.get(player)
		return if data then activeProgress(data).level else 1
	end
	TeamService.powerOf = function(id: string): number
		local userId = tonumber(string.match(id, "^player:(%d+)$"))
		local player = if userId then Players:GetPlayerByUserId(userId) else nil
		return if player then ProgressionService.power(player) else 1
	end

	-- Pet and level stats on every spawn (CombatService sets the base stats first).
	CharacterService.characterSpawned:connect(function(player: Player)
		applyStats(player)
	end)
	EggService.claimPet = ProgressionService.claim
	EggService.feedPet = ProgressionService.feed
	DataService.loaded:connect(function(player: Player)
		refreshPower(player)
	end)

	-- Minions (proximity credit).
	CombatService.credited:connect(function(player: Player, kind: string, amount: number)
		if kind == "minion" then
			ProgressionService.award(player, xp.minion * amount, "minion")
		end
	end)

	-- Player kills and assists.
	CombatService.killed:connect(function(victimId: number, killerId: number, assists: { number })
		if victimId <= 0 then
			return
		end
		local killer = Players:GetPlayerByUserId(killerId)
		if killer then
			ProgressionService.award(killer, xp.kill, "kill")
			local data = DataService.get(killer)
			if data then
				data.stats.kills += 1
			end
		end
		for _, id in assists do
			local assister = Players:GetPlayerByUserId(id)
			if assister then
				ProgressionService.award(assister, xp.assist, "assist")
			end
		end
		local victim = Players:GetPlayerByUserId(victimId)
		local victimData = victim and DataService.get(victim)
		if victimData then
			victimData.stats.deaths += 1
		end
	end)

	-- Camp monsters: shared by everyone who damaged them.
	MonsterService.died:connect(function(m: MonsterService.Monster)
		if m.camp == nil then
			return
		end
		local players: { Player } = {}
		for id in m.row.entry.combatant.contributors do
			local player = Players:GetPlayerByUserId(id)
			if player then
				table.insert(players, player)
			end
		end
		if #players > 0 then
			local share = m.row.entry.combatant.maxHealth * xp.monsterPerHealth / #players
			for _, player in players do
				ProgressionService.award(player, share, "monster")
			end
		end
	end)
	CampService.cleared:connect(function(index: number)
		local p = CampService.position(index)
		local tier = CampService.tier(index)
		if p then
			awardNear(p, nil, 60, xp.campClear * tier, "camp")
		end
	end)

	-- Structures: the attacking team nearby.
	MonsterService.structureDestroyed:connect(function(structure)
		local amount = (xp :: any)[structure.kind] or 0
		local p = Vector3.new(structure.position.x, 0, structure.position.z)
		awardNear(p, 3 - structure.team, xp.structureRange, amount, "structure")
	end)

	-- Eggs.
	EggService.deposited:connect(function(player: Player)
		ProgressionService.award(player, xp.eggDeposited, "deposit")
	end)
	EggService.raided:connect(function(player: Player)
		ProgressionService.award(player, xp.raid, "raid")
	end)
	EggService.hatched:connect(function(egg)
		local owner = egg.owner
		if owner then
			ProgressionService.award(owner, xp.eggHatched, "hatch")
			local data = DataService.get(owner)
			if data then
				data.stats.eggsHatched += 1
			end
		end
	end)

	-- Unleashed monsters' damage, to their owner.
	CombatService.damaged:connect(function(_targetId: number, sourceId: number, amount: number)
		if sourceId >= 0 then
			return
		end
		local m = MonsterService.monster(-sourceId)
		local ownerId = m and m.ownerId
		local owner = if ownerId then Players:GetPlayerByUserId(ownerId) else nil
		if owner then
			local total = (carry[owner] or 0) + amount * xp.unleashPerDamage
			local whole = math.floor(total)
			carry[owner] = total - whole
			if whole > 0 then
				ProgressionService.award(owner, whole, "unleash")
			end
		end
	end)

	-- Round completion.
	RoundService.phaseChanged:connect(function(state: Round.State)
		if state.phase ~= "Ending" then
			return
		end
		for _, player in Players:GetPlayers() do
			local data = DataService.get(player)
			local team = TeamService.teamOf(player)
			if data and team then
				local won = team == state.winner
				data.stats.rounds += 1
				if won then
					data.stats.wins += 1
				end
				ProgressionService.award(player, if won then xp.roundWin else xp.roundLoss, "round")
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		carry[player] = nil
	end)
end

return ProgressionService
