--!strict
-- The player profile schema and its migrations. Pure, unit tested under Lune.
--
-- Version 1: per-class level and XP, last active class, pets (up to three: type, pet XP,
-- cosmetic), active pet, gold, cosmetics owned, settings, statistics. Pets, pet XP, gold and
-- cosmetics are account-wide.
--
-- To change the schema: bump VERSION, add a migration from the previous version to MIGRATIONS,
-- and update `new`. Old profiles are migrated step by step when loaded.

export type ClassData = { level: number, xp: number }

export type Pet = {
	-- Unique within the profile.
	id: number,
	-- Monster type (Shared.Monsters).
	kind: string,
	xp: number,
	cosmetic: string?,
}

export type Data = {
	version: number,
	classes: { [string]: ClassData },
	activeClass: string,
	-- Whether the player has picked a class yet (the first-join picker shows until they do).
	classChosen: boolean,
	pets: { Pet },
	-- Pet ID, or 0 for none.
	activePet: number,
	nextPetId: number,
	gold: number,
	cosmetics: { [string]: boolean },
	-- Cosmetic loadout presets (slot -> item ID) and which one is worn (Phase 12).
	loadouts: { { [string]: string } },
	activeLoadout: number,
	-- Robux receipts already granted (most recent), and purchase history.
	receipts: { string },
	purchases: { { receipt: string, product: number, gold: number, at: number } },
	-- Daily login streak and quests.
	daily: {
		lastLoginDay: number,
		streak: number,
		questDay: number,
		quests: { { id: string, progress: number, done: boolean } },
	},
	settings: { [string]: any },
	stats: {
		rounds: number,
		wins: number,
		kills: number,
		deaths: number,
		eggsHatched: number,
		goldEarned: number,
	},
}

local VERSION = 1

local Profile = {}

Profile.VERSION = VERSION

function Profile.new(): Data
	return {
		version = VERSION,
		classes = { knight = { level = 1, xp = 0 } },
		activeClass = "knight",
		classChosen = false,
		pets = {},
		activePet = 0,
		nextPetId = 1,
		gold = 0,
		cosmetics = {},
		loadouts = { {} },
		activeLoadout = 1,
		receipts = {},
		purchases = {},
		daily = { lastLoginDay = 0, streak = 0, questDay = 0, quests = {} },
		settings = {},
		stats = { rounds = 0, wins = 0, kills = 0, deaths = 0, eggsHatched = 0, goldEarned = 0 },
	}
end

-- Each entry migrates a profile from version (index) to version (index + 1), in place.
local MIGRATIONS: { (data: any) -> () } = {}

-- Upgrades stored data to the current version and fills any missing fields with defaults.
-- Returns nil for data from a newer version than this server knows (it must not be overwritten).
function Profile.migrate(stored: any): Data?
	if type(stored) ~= "table" then
		return Profile.new()
	end
	local data = stored
	local version = if type(data.version) == "number" then data.version else 0
	if version > VERSION then
		return nil
	end
	if version < 1 then
		-- Pre-release data: start over.
		return Profile.new()
	end
	while version < VERSION do
		MIGRATIONS[version](data)
		version += 1
		data.version = version
	end
	-- Fill anything missing (fields added without a version bump).
	local defaults = Profile.new()
	for key, value in defaults :: any do
		if data[key] == nil then
			data[key] = value
		end
	end
	for key, value in defaults.stats :: any do
		if data.stats[key] == nil then
			data.stats[key] = value
		end
	end
	if data.classes[data.activeClass] == nil then
		data.classes[data.activeClass] = { level = 1, xp = 0 }
	end
	return data :: Data
end

function Profile.pet(data: Data, id: number): Pet?
	for _, pet in data.pets do
		if pet.id == id then
			return pet
		end
	end
	return nil
end

-- Adds a pet. Returns it, or nil if every unlocked slot is full.
function Profile.addPet(data: Data, kind: string, slots: number): Pet?
	if #data.pets >= slots then
		return nil
	end
	local pet: Pet = { id = data.nextPetId, kind = kind, xp = 0, cosmetic = nil }
	data.nextPetId += 1
	table.insert(data.pets, pet)
	if data.activePet == 0 then
		data.activePet = pet.id
	end
	return pet
end

-- Replaces pet `id` with a new pet of `kind`. Returns the new pet, or nil if `id` is unknown.
function Profile.replacePet(data: Data, id: number, kind: string): Pet?
	for i, pet in data.pets do
		if pet.id == id then
			local new: Pet = { id = data.nextPetId, kind = kind, xp = 0, cosmetic = nil }
			data.nextPetId += 1
			data.pets[i] = new
			if data.activePet == id then
				data.activePet = new.id
			end
			return new
		end
	end
	return nil
end

return Profile
