--!strict
-- Active pets in the world. Each player's active pet (from their profile) is a small version of
-- its monster type that follows them, fights hostiles near them with its own attacks (the same
-- monster kit and data pipeline as every other monster), and cannot be targeted. It appears when
-- the player spawns, leaves when they die or leave, and changes when they switch pets. Switching
-- the active pet is only allowed in your own base.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Map = require(ReplicatedStorage.Shared.Map)
local Net = require(ReplicatedStorage.Shared.Net)
local Profile = require(ReplicatedStorage.Shared.Profile)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local DataService = require("./DataService")
local MonsterService = require("./MonsterService")
local ProgressionService = require("./ProgressionService")
local TeamService = require("./TeamService")

local PET_SCALE = 0.45

local PetService = {
	name = "PetService",
	dependencies = {
		"CharacterService",
		"CombatService",
		"DataService",
		"MonsterService",
		"ProgressionService",
		"TeamService",
	},
}

local pets: { [Player]: MonsterService.Monster } = {}

local function despawnPet(player: Player)
	local m = pets[player]
	if m then
		pets[player] = nil
		if m.row.alive then
			MonsterService.remove(m)
		end
	end
end

-- Spawns a pet of `kind` following `follow` for `team` (players and dev load tests).
function PetService.spawnFor(
	follow: CombatService.Entry,
	team: number?,
	kind: string,
	petXp: number
): MonsterService.Monster?
	if Config.get().monsters[kind] == nil then
		return nil
	end
	local p = follow.position()
	if p == nil then
		return nil
	end
	local progression = Config.get().progression
	local damage = progression.petDamageScale * Progression.petMultiplier(petXp, progression)
	return MonsterService.spawn(kind, p + Vector3.new(3, 0, 3), team, {
		follow = follow,
		scale = PET_SCALE,
		damageScale = damage,
	})
end

local function spawnPet(player: Player)
	despawnPet(player)
	local data = DataService.get(player)
	local entry = CombatService.entry(player.UserId)
	if data == nil or entry == nil or data.activePet == 0 then
		return
	end
	local pet = Profile.pet(data, data.activePet)
	if pet == nil then
		return
	end
	local m = PetService.spawnFor(entry, TeamService.teamOf(player), pet.kind, pet.xp)
	if m then
		pets[player] = m
	end
end

local function inOwnBase(player: Player): boolean
	local team = TeamService.teamOf(player)
	local entry = CombatService.entry(player.UserId)
	local p = entry and entry.position()
	if team == nil or p == nil then
		return false
	end
	local base = Map.get().bases[team]
	return math.abs(p.X - base.center.x) <= base.size.x / 2 and math.abs(p.Z - base.center.z) <= base.size.z / 2
end

function PetService.petOf(player: Player): MonsterService.Monster?
	return pets[player]
end

function PetService.count(): number
	local n = 0
	for _ in pets do
		n += 1
	end
	return n
end

function PetService.init(_self: typeof(PetService))
	CharacterService.characterSpawned:connect(function(player: Player, character: Model)
		-- After CombatService has registered the character.
		task.defer(spawnPet, player)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Died:Connect(function()
				despawnPet(player)
			end)
		end
	end)
	ProgressionService.petChanged:connect(function(player: Player)
		task.delay(Config.get().progression.petRespawnSeconds * 0.1, spawnPet, player)
	end)
	Players.PlayerRemoving:Connect(despawnPet)
	Net.onServerEvent(Remotes.SetActivePet, function(player: Player, petId: number)
		if not inOwnBase(player) then
			Net.fireClient(Remotes.DevMessage, player, "Switch pets at your base.")
			return
		end
		ProgressionService.setActivePet(player, petId)
	end)
end

return PetService
