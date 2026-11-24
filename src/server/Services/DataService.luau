--!strict
-- Player profiles: session-locked load and save (Shared.SessionLock) on a data store named per
-- environment (Config.data: `dev_profiles_v1` in Studio, `profiles_v1` live), with schema
-- migration (Shared.Profile).
--
--   Load on join with retries and backoff. A profile held by another live server is retried
--   until it is released or goes stale. If it still cannot load, the player is told and removed:
--   nobody ever plays on an empty profile by accident. Players cannot spawn until loaded.
--   Autosave every minute (refreshing the lock), save and release on leave, and save everyone on
--   server shutdown.
--   In Studio without data store access, an in-memory store stands in (dev and test only), with a
--   warning; progress then lasts only for the session.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Profile = require(ReplicatedStorage.Shared.Profile)
local SessionLock = require(ReplicatedStorage.Shared.SessionLock)
local Signal = require(ReplicatedStorage.Shared.Signal)

local CharacterService = require("./CharacterService")

local DataService = {
	name = "DataService",
	dependencies = { "CharacterService" },
	-- (player, data) once a profile is loaded and ready.
	loaded = Signal.new() :: Signal.Signal<Player, Profile.Data>,
	-- True when the in-memory fallback is in use (no persistence).
	usingMemory = false,
}

local profiles: { [Player]: Profile.Data } = {}
local session = if RunService:IsStudio() then `studio-{HttpService:GenerateGUID(false)}` else game.JobId
local store: SessionLock.Store

local function now(): number
	return os.time()
end

local function config(): Config.DataConfig
	return Config.get().data
end

local function keyOf(userId: number): string
	return `player_{userId}`
end

local function dataStoreBackend(): SessionLock.Store
	local ds = DataStoreService:GetDataStore(config().storePrefix .. config().storeName)
	return {
		update = function(
			key: string,
			transform: (current: SessionLock.Record?) -> SessionLock.Record?
		): SessionLock.Record?
			return ds:UpdateAsync(key, function(current: any): any
				return transform(current)
			end)
		end,
	}
end

-- Probes data store access once; falls back to memory where allowed.
local function chooseStore()
	local backend = dataStoreBackend()
	local ok, err = pcall(function()
		backend.update("probe", function(current)
			return current or { data = { probe = true }, lock = nil }
		end)
	end)
	if ok then
		store = backend
		return
	end
	if config().allowMemoryFallback then
		warn(`[Data] data stores unavailable ({err}); using an in-memory store, progress will not persist`)
		store = SessionLock.memoryStore()
		DataService.usingMemory = true
	else
		-- Keep the real store; loads will fail and players will be told.
		warn(`[Data] data store probe failed: {err}`)
		store = backend
	end
end

local function kick(player: Player, message: string)
	if player.Parent then
		player:Kick(message)
	end
end

local function load(player: Player)
	local key = keyOf(player.UserId)
	local attempts = config().loadAttempts
	local lastReason = "unknown"
	for attempt = 1, attempts do
		local ok, result = pcall(SessionLock.load, store, key, session, now(), config().staleLockSeconds)
		if player.Parent == nil then
			return
		end
		if ok and result.ok then
			local data = Profile.migrate(result.data)
			if data == nil then
				kick(player, "Your progress was saved by a newer version of the game. Please rejoin in a moment.")
				return
			end
			profiles[player] = data
			player:SetAttribute("ProfileLoaded", true)
			DataService.loaded:fire(player, data)
			-- They may have been given a team while loading.
			task.spawn(CharacterService.spawn, player)
			return
		end
		lastReason = if ok then result.reason or "locked" else tostring(result)
		task.wait(2 ^ attempt)
	end
	warn(`[Data] could not load {player.Name}: {lastReason}`)
	if lastReason == "locked" then
		kick(player, "Your progress is still open on another server. Please rejoin in a minute.")
	else
		kick(player, "We could not load your progress. Please rejoin; nothing was lost.")
	end
end

local function save(player: Player, release: boolean): boolean
	local data = profiles[player]
	if data == nil then
		return false
	end
	local ok, result = pcall(SessionLock.save, store, keyOf(player.UserId), session, data, now(), release)
	if not ok then
		warn(`[Data] save failed for {player.Name}: {result}`)
		return false
	end
	if not result then
		warn(`[Data] {player.Name}'s profile lock was lost; not saved (another server owns it)`)
	end
	return result
end

-- The loaded profile, or nil while loading.
function DataService.get(player: Player): Profile.Data?
	return profiles[player]
end

function DataService.save(player: Player): boolean
	return save(player, false)
end

-- Dev: replaces a profile with a fresh one (saved at the next save).
function DataService.wipe(player: Player): Profile.Data
	local data = Profile.new()
	profiles[player] = data
	DataService.loaded:fire(player, data)
	return data
end

-- Dev: tries to load `player`'s profile as another server would. Returns the result reason.
function DataService.loadAsOtherServer(player: Player): string
	local result = SessionLock.load(store, keyOf(player.UserId), "other-server", now(), config().staleLockSeconds)
	return if result.ok then "loaded (lock was free)" else `refused: {result.reason} by {result.holder}`
end

function DataService.init(_self: typeof(DataService))
	CharacterService.canSpawn = function(player: Player): boolean
		return profiles[player] ~= nil
	end
	chooseStore()
end

function DataService.start(_self: typeof(DataService))
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		save(player, true)
		profiles[player] = nil
	end)
	game:BindToClose(function()
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				save(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
	while true do
		task.wait(config().autosaveSeconds)
		for player in profiles do
			task.spawn(save, player, false)
		end
	end
end

return DataService
