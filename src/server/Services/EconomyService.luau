--!strict
-- Gold and cosmetics on the server (Phase 12; rules in Shared.Economy, catalogue in
-- Shared.Cosmetics). Gold and cosmetics never touch stats or XP.
--
--   Gold from play: round result, player kills and assists, guardians (attacking team nearby),
--   camp clears (nearby), the jungle boss (killing team nearby), hatched eggs.
--   Daily: a login reward on the first join of each UTC day (streak), and three quests a day
--   tracked from play.
--   Shop: buy cosmetics for gold; equip them in loadout presets (one free, three with the game
--   pass); pet skins live on each pet.
--   Policy: PolicyService is checked per player. Nothing is a paid random item and nothing can be
--   traded, so no item needs hiding; the result is kept (`PaidRandomItemsRestricted`) for later.
--   Telemetry: every gold source and sink goes to AnalyticsService:LogEconomyEvent.
--
-- Player attributes for the UI: Gold, Owned (JSON list), Loadout (JSON, the active preset),
-- LoadoutIndex, LoadoutCount, Quests (JSON), LoginStreak.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Net = require(ReplicatedStorage.Shared.Net)
local Profile = require(ReplicatedStorage.Shared.Profile)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)

local CampService = require("./CampService")
local CombatService = require("./CombatService")
local DataService = require("./DataService")
local EggService = require("./EggService")
local JungleBossService = require("./JungleBossService")
local MonsterService = require("./MonsterService")
local RoundService = require("./RoundService")
local TeamService = require("./TeamService")

local CAMP_RANGE = 60
local BOSS_RANGE = 80

local EconomyService = {
	name = "EconomyService",
	dependencies = {
		"CampService",
		"CombatService",
		"DataService",
		"EggService",
		"JungleBossService",
		"MonsterService",
		"RoundService",
		"TeamService",
	},
	-- (player) when their worn cosmetics may have changed (CosmeticService re-dresses them).
	loadoutChanged = Signal.new() :: Signal.Signal<Player>,
	-- (player, amount, source) for every gold change (negative for spending).
	goldChanged = Signal.new() :: Signal.Signal<Player, number, string>,
}

local passOwners: { [Player]: boolean } = {}
local dirty: { [Player]: boolean } = {}

local function cfg(): Economy.EconomyConfig
	return Config.get().economy
end

local function walletOf(player: Player): Economy.Wallet?
	local data = DataService.get(player)
	return if data then data :: any else nil
end

local function toast(player: Player, text: string, kind: string)
	Net.fireClient(Remotes.Announce, player, { text = text, kind = kind })
end

local function logEconomy(
	player: Player,
	flow: Enum.AnalyticsEconomyFlowType,
	amount: number,
	balance: number,
	kind: string,
	sku: string
)
	pcall(function()
		AnalyticsService:LogEconomyEvent(player, flow, "Gold", amount, balance, kind, sku)
	end)
end

-- Publishing ---------------------------------------------------------------------------------

local function weaponOf(player: Player): string?
	local character = player.Character
	local weapon = character and character:FindFirstChild("Weapon")
	local classId = weapon and weapon:GetAttribute("Class")
	local class = if type(classId) == "string" then Config.get().classDefinitions[classId] else nil
	return if class then class.weapon else nil
end

-- The cosmetics a player is wearing right now (slot -> item ID).
function EconomyService.loadoutOf(player: Player): Economy.Loadout
	local w = walletOf(player)
	return if w then Economy.resolve(w, weaponOf(player)) else {}
end

local function publish(player: Player)
	local w = walletOf(player)
	if w == nil then
		return
	end
	player:SetAttribute("Gold", w.gold)
	local owned: { string } = {}
	for id in w.cosmetics do
		table.insert(owned, id)
	end
	table.sort(owned)
	player:SetAttribute("Owned", HttpService:JSONEncode(owned))
	player:SetAttribute("Loadout", HttpService:JSONEncode(w.loadouts[w.activeLoadout] or {}))
	player:SetAttribute("LoadoutIndex", w.activeLoadout)
	player:SetAttribute("LoadoutCount", Economy.loadoutCount(passOwners[player] == true, cfg()))
	player:SetAttribute("LoginStreak", w.daily.streak)
	local quests = {}
	for _, q in w.daily.quests do
		local def = Economy.questDef(q.id, cfg())
		if def then
			table.insert(
				quests,
				{ text = def.text, progress = q.progress, target = def.target, gold = def.gold, done = q.done }
			)
		end
	end
	player:SetAttribute("Quests", HttpService:JSONEncode(quests))
end

-- Gold ----------------------------------------------------------------------------------------

-- Gives gold from play (or a reward). Returns the amount given.
function EconomyService.give(player: Player, amount: number, source: string): number
	local w = walletOf(player)
	if w == nil or amount <= 0 then
		return 0
	end
	amount = math.floor(amount)
	w.gold += amount
	local data = DataService.get(player) :: Profile.Data
	data.stats.goldEarned += amount
	publish(player)
	EconomyService.goldChanged:fire(player, amount, source)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Source, amount, w.gold, "Gameplay", source)
	return amount
end

local function addProgress(player: Player, stat: string, amount: number)
	local w = walletOf(player)
	if w == nil or amount <= 0 then
		return
	end
	local gold, finished = Economy.progress(w.daily, stat, amount, cfg())
	if gold > 0 then
		for _, text in finished do
			toast(player, `Quest complete: {text} (+{gold} gold)`, "success")
		end
		EconomyService.give(player, gold, "quest")
	else
		-- Progress from frequent events (damage, healing, minions) is published on a short timer.
		dirty[player] = true
	end
end

-- Players near a point (optionally on one team).
local function playersNear(position: Vector3, range: number, team: number?): { Player }
	local out: { Player } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if
			root
			and root:IsA("BasePart")
			and (root.Position - position).Magnitude <= range
			and (team == nil or TeamService.teamOf(player) == team)
		then
			table.insert(out, player)
		end
	end
	return out
end

-- Daily ---------------------------------------------------------------------------------------

local function checkDaily(player: Player)
	local w = walletOf(player)
	if w == nil then
		return
	end
	local today = Economy.day(os.time())
	local gold, streak = Economy.loginReward(w.daily, today, cfg())
	if gold > 0 then
		w.daily.lastLoginDay = today
		w.daily.streak = streak
		EconomyService.give(player, gold, "daily")
		toast(player, `Daily reward, day {streak}: +{gold} gold`, "success")
	end
	if w.daily.questDay ~= today then
		w.daily.questDay = today
		w.daily.quests = Economy.questsFor(player.UserId, today, cfg())
		toast(player, "New daily quests are in the shop.", "info")
	end
	publish(player)
end

-- Shop ----------------------------------------------------------------------------------------

function EconomyService.buy(player: Player, itemId: string): string?
	local w = walletOf(player)
	if w == nil then
		return "profile not loaded"
	end
	local ok, reason = Economy.buy(w, itemId)
	if not ok then
		return reason
	end
	local item = Cosmetics.get(itemId) :: Cosmetics.Item
	publish(player)
	EconomyService.goldChanged:fire(player, -item.price, "shop")
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, item.price, w.gold, "Shop", itemId)
	toast(player, `Bought {item.name}`, "success")
	return nil
end

function EconomyService.equip(player: Player, slot: string, itemId: string?): string?
	local w = walletOf(player)
	if w == nil then
		return "profile not loaded"
	end
	local ok, reason = Economy.equip(w, slot, itemId)
	if not ok then
		return reason
	end
	publish(player)
	EconomyService.loadoutChanged:fire(player)
	return nil
end

function EconomyService.selectLoadout(player: Player, index: number): boolean
	local w = walletOf(player)
	if w == nil then
		return false
	end
	local ok = Economy.selectLoadout(w, index, Economy.loadoutCount(passOwners[player] == true, cfg()))
	if ok then
		publish(player)
		EconomyService.loadoutChanged:fire(player)
	end
	return ok
end

-- Sets the skin on one of the player's pets (nil to clear).
function EconomyService.setPetSkin(player: Player, petId: number, itemId: string?): string?
	local data = DataService.get(player)
	if data == nil then
		return "profile not loaded"
	end
	local pet = Profile.pet(data, petId)
	if pet == nil then
		return "no such pet"
	end
	if itemId then
		local item = Cosmetics.get(itemId)
		if item == nil or item.kind ~= "petSkin" or not data.cosmetics[itemId] then
			return "not an owned pet skin"
		end
	end
	pet.cosmetic = itemId
	EconomyService.loadoutChanged:fire(player)
	return nil
end

-- The skin on a player's active pet, if any.
function EconomyService.petSkinOf(player: Player): Cosmetics.Item?
	local data = DataService.get(player)
	local pet = data and Profile.pet(data, data.activePet)
	local id = pet and pet.cosmetic
	return if id then Cosmetics.get(id) else nil
end

function EconomyService.hasPass(player: Player): boolean
	return passOwners[player] == true
end

-- Re-reads game pass ownership (after a purchase prompt finishes).
function EconomyService.refreshPass(player: Player)
	local pass = cfg().extraLoadoutsPass
	if pass.passId == 0 then
		passOwners[player] = false
		return
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.passId)
	end)
	passOwners[player] = ok and owns == true
	publish(player)
end

-- Dev: gold for testing.
function EconomyService.grant(player: Player, amount: number)
	EconomyService.give(player, amount, "dev")
end

function EconomyService.publish(player: Player)
	publish(player)
end

-- Wiring --------------------------------------------------------------------------------------

function EconomyService.init(_self: typeof(EconomyService))
	local gold = cfg().gold
	DataService.loaded:connect(function(player: Player)
		task.spawn(function()
			EconomyService.refreshPass(player)
			local ok, policy = pcall(function()
				return PolicyService:GetPolicyInfoForPlayerAsync(player)
			end)
			if ok and type(policy) == "table" then
				player:SetAttribute("PaidRandomItemsRestricted", policy.ArePaidRandomItemsRestricted == true)
			end
		end)
		checkDaily(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		passOwners[player] = nil
		dirty[player] = nil
	end)

	Net.onServerEvent(Remotes.BuyCosmetic, function(player: Player, itemId: string)
		local reason = EconomyService.buy(player, itemId)
		if reason then
			toast(player, `Could not buy: {reason}`, "warning")
		end
	end)
	Net.onServerEvent(Remotes.EquipCosmetic, function(player: Player, request: Remotes.EquipRequest)
		local reason = EconomyService.equip(player, request.slot, request.item)
		if reason then
			toast(player, `Could not equip: {reason}`, "warning")
		end
	end)
	Net.onServerEvent(Remotes.SelectLoadout, function(player: Player, index: number)
		EconomyService.selectLoadout(player, index)
	end)
	Net.onServerEvent(Remotes.SetPetSkin, function(player: Player, request: Remotes.PetSkinRequest)
		local reason = EconomyService.setPetSkin(player, request.pet, request.item)
		if reason then
			toast(player, `Could not set the pet skin: {reason}`, "warning")
		end
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, bought: boolean)
		if bought and passId == cfg().extraLoadoutsPass.passId then
			EconomyService.refreshPass(player)
			toast(player, "Extra loadouts unlocked!", "success")
		end
	end)

	-- Gold and quests from play.
	RoundService.phaseChanged:connect(function(state: Round.State)
		if state.phase ~= "Ending" then
			return
		end
		for _, player in Players:GetPlayers() do
			local team = TeamService.teamOf(player)
			if team then
				local won = team == state.winner
				EconomyService.give(player, if won then gold.roundWin else gold.roundLoss, "round")
				addProgress(player, "rounds", 1)
				if won then
					addProgress(player, "wins", 1)
				end
			end
		end
	end)
	CombatService.killed:connect(function(_victimId: number, killerId: number, assists: { number }, victim)
		if victim.kind ~= "player" then
			return
		end
		local killer = if killerId > 0 then Players:GetPlayerByUserId(killerId) else nil
		if killer then
			EconomyService.give(killer, gold.kill, "kill")
			addProgress(killer, "kills", 1)
		end
		for _, id in assists do
			local assister = if id > 0 then Players:GetPlayerByUserId(id) else nil
			if assister then
				EconomyService.give(assister, gold.assist, "assist")
			end
		end
	end)
	MonsterService.structureDestroyed:connect(function(structure)
		local p = Vector3.new(structure.position.x, 0, structure.position.z)
		for _, player in playersNear(p, Config.get().progression.xp.structureRange, 3 - structure.team) do
			EconomyService.give(player, gold.structure, "structure")
			addProgress(player, "structures", 1)
		end
	end)
	CampService.cleared:connect(function(index: number)
		local p = CampService.position(index)
		if p then
			for _, player in playersNear(p, CAMP_RANGE, nil) do
				EconomyService.give(player, gold.campClear, "camp")
				addProgress(player, "camps", 1)
			end
		end
	end)
	JungleBossService.killed:connect(function(team: number?)
		if team == nil then
			return
		end
		for _, spot in Config.get().balance.boss.positions do
			for _, player in playersNear(Vector3.new(spot.x, 0, spot.z), BOSS_RANGE, team) do
				EconomyService.give(player, gold.boss, "boss")
			end
		end
	end)
	EggService.hatched:connect(function(egg)
		local owner = egg.owner
		if owner then
			EconomyService.give(owner, gold.eggHatched, "egg")
			addProgress(owner, "eggs", 1)
		end
	end)
	CombatService.credited:connect(function(player: Player, kind: string, amount: number)
		if kind == "minion" then
			addProgress(player, "minions", amount)
		end
	end)
	CombatService.supported:connect(function(sourceId: number, targetId: number, amount: number)
		if sourceId > 0 and sourceId ~= targetId then
			local player = Players:GetPlayerByUserId(sourceId)
			if player then
				addProgress(player, "support", amount)
			end
		end
	end)
	CombatService.damaged:connect(function(_targetId: number, sourceId: number, amount: number)
		if sourceId > 0 then
			local player = Players:GetPlayerByUserId(sourceId)
			if player then
				addProgress(player, "damage", amount)
			end
		end
	end)
end

function EconomyService.start(_self: typeof(EconomyService))
	local sinceDaily = 0
	while true do
		task.wait(2)
		for player in dirty do
			dirty[player] = nil
			if player.Parent then
				publish(player)
			end
		end
		-- New UTC day while playing: new login reward and quests.
		sinceDaily += 2
		if sinceDaily >= 60 then
			sinceDaily = 0
			for _, player in Players:GetPlayers() do
				checkDaily(player)
			end
		end
	end
end

return EconomyService
