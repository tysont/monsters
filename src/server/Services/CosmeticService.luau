--!strict
-- Puts equipped cosmetics on characters and pets (Phase 12). Pure looks: nothing here touches
-- combat entries, stats or XP.
--
--   Weapon skin  recolours the class weapon (and its accent), optional glow and a few particles.
--   Armour skin  two shoulder plates.
--   Trail        a Trail between two attachments on the root part.
--   Title        the `CosmeticTitle` attribute (nameplates show it beside account titles).
--   Kill effect  when the wearer defeats a player, nearby clients play a burst (KillEffect).
--   Emote        the wearer presses G; nearby clients play the pose (EmotePlayed).
--   Pet skin     the active pet's colour (PetService tint).
--
-- The looks themselves are in Shared.CosmeticLook (shared with the shop preview), within its
-- per-item budget.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticLook = require(ReplicatedStorage.Shared.CosmeticLook)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local CharacterService = require("./CharacterService")
local CombatService = require("./CombatService")
local EconomyService = require("./EconomyService")
local PetService = require("./PetService")
local ProgressionService = require("./ProgressionService")

local EFFECT_RANGE = 200
local TAG = "Cosmetic"

local CosmeticService = {
	name = "CosmeticService",
	dependencies = { "CharacterService", "CombatService", "EconomyService", "PetService", "ProgressionService" },
}

-- Applies a player's worn cosmetics to their character (call after any change).
function CosmeticService.dress(player: Player)
	local character = player.Character
	if character == nil then
		return
	end
	local loadout = EconomyService.loadoutOf(player)
	CosmeticLook.dress(character, loadout, TAG)
	local title = loadout.title and Cosmetics.get(loadout.title)
	player:SetAttribute("CosmeticTitle", if title then title.look.text else nil)
end

local function petTint(player: Player): number?
	local skin = EconomyService.petSkinOf(player)
	local c = skin and skin.look.color
	if c == nil then
		return nil
	end
	return c[1] * 65536 + c[2] * 256 + c[3]
end

local function playersNear(position: Vector3): { Player }
	local out: { Player } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= EFFECT_RANGE then
			table.insert(out, player)
		end
	end
	return out
end

function CosmeticService.init(_self: typeof(CosmeticService))
	PetService.tintOf = petTint
	CharacterService.characterSpawned:connect(function(player: Player)
		-- After CombatService has put the weapon in the hand.
		task.defer(CosmeticService.dress, player)
	end)
	CombatService.weaponDressed:connect(function(character: Model)
		local player = Players:GetPlayerFromCharacter(character)
		if player then
			task.defer(CosmeticService.dress, player)
		end
	end)
	local lastPetTint: { [Player]: number? } = {}
	EconomyService.loadoutChanged:connect(function(player: Player)
		CosmeticService.dress(player)
		local tint = petTint(player)
		if tint ~= lastPetTint[player] then
			lastPetTint[player] = tint
			PetService.respawn(player)
		end
		-- The stable screen shows each pet's skin.
		ProgressionService.refresh(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastPetTint[player] = nil
	end)
	CombatService.killed:connect(function(_victimId: number, killerId: number, _assists: { number }, victim)
		-- Players and class bots (dev tests) only: not minions or monsters.
		if (victim.kind ~= "player" and victim.classId == nil) or killerId <= 0 then
			return
		end
		local killer = Players:GetPlayerByUserId(killerId)
		local effect = killer and EconomyService.loadoutOf(killer).killEffect
		local position = victim.position()
		if effect and position then
			Net.fireClients(Remotes.KillEffect, playersNear(position), { item = effect, position = position })
		end
	end)
	Net.onServerEvent(Remotes.Emote, function(player: Player)
		local emote = EconomyService.loadoutOf(player).emote
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if emote and root and root:IsA("BasePart") then
			Net.fireClients(Remotes.EmotePlayed, playersNear(root.Position), { player = player.UserId, item = emote })
		end
	end)
end

return CosmeticService
