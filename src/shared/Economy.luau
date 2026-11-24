--!strict
-- Phase 12 economy rules, pure and unit tested under Lune: buying and equipping cosmetics,
-- loadouts, the daily login streak, daily quests, the featured shop rotation, and the Robux
-- receipt ledger (idempotent: a receipt is granted exactly once, however often Roblox retries it).
--
-- Nothing here reads or changes stats: gold and cosmetics are separate from levels, pets and XP.

local Cosmetics = require("./Cosmetics")

export type QuestDef = {
	id: string,
	text: string,
	-- The counter it tracks (see EconomyService): "wins", "rounds", "kills", "assists", "minions",
	-- "camps", "structures", "eggs", "support", "damage".
	stat: string,
	target: number,
	gold: number,
}

export type GoldPack = { id: string, productId: number, gold: number, robux: number }

export type EconomyConfig = {
	-- Gold per event from play.
	gold: {
		roundWin: number,
		roundLoss: number,
		kill: number,
		assist: number,
		structure: number,
		campClear: number,
		boss: number,
		eggHatched: number,
	},
	daily: {
		-- Login reward: base + perDay x (streak day - 1), capped at max; the streak runs to
		-- streakDays and starts again after a missed day.
		loginBase: number,
		loginPerDay: number,
		loginMax: number,
		streakDays: number,
		-- Quests offered each day.
		questCount: number,
		quests: { QuestDef },
	},
	-- Loadout presets: free, and with the game pass.
	loadouts: { free: number, withPass: number },
	-- Featured shop items per day.
	featuredCount: number,
	-- Receipt IDs kept per profile for idempotence.
	receiptHistory: number,
	purchaseHistory: number,
	-- Robux products (productId 0 = not created yet: hidden from the shop).
	goldPacks: { GoldPack },
	extraLoadoutsPass: { passId: number, robux: number },
}

export type Loadout = { [string]: string }

export type Quest = { id: string, progress: number, done: boolean }

export type Daily = {
	-- Day number (UTC days since 1970) of the last login reward.
	lastLoginDay: number,
	streak: number,
	questDay: number,
	quests: { Quest },
}

export type Purchase = { receipt: string, product: number, gold: number, at: number }

-- The parts of a profile the economy reads and writes.
export type Wallet = {
	gold: number,
	cosmetics: { [string]: boolean },
	loadouts: { Loadout },
	activeLoadout: number,
	receipts: { string },
	purchases: { Purchase },
	daily: Daily,
}

local Economy = {}

local DAY = 86400

function Economy.day(unixTime: number): number
	return math.floor(unixTime / DAY)
end

-- Buying -------------------------------------------------------------------------------------

function Economy.canBuy(wallet: Wallet, itemId: string): (boolean, string?)
	local item = Cosmetics.get(itemId)
	if item == nil then
		return false, "unknown item"
	end
	if item.price <= 0 then
		return false, "not for sale"
	end
	if wallet.cosmetics[itemId] then
		return false, "already owned"
	end
	if wallet.gold < item.price then
		return false, "not enough gold"
	end
	return true, nil
end

-- Buys an item for gold. Returns whether it was bought and why not.
function Economy.buy(wallet: Wallet, itemId: string): (boolean, string?)
	local ok, reason = Economy.canBuy(wallet, itemId)
	if not ok then
		return false, reason
	end
	local item = Cosmetics.get(itemId) :: Cosmetics.Item
	wallet.gold -= item.price
	wallet.cosmetics[itemId] = true
	return true, nil
end

-- Loadouts -----------------------------------------------------------------------------------

function Economy.loadoutCount(hasPass: boolean, cfg: EconomyConfig): number
	return if hasPass then cfg.loadouts.withPass else cfg.loadouts.free
end

-- Equips an owned item in its slot of the active loadout, or clears the slot (`itemId` nil).
function Economy.equip(wallet: Wallet, slot: string, itemId: string?): (boolean, string?)
	if not table.find(Cosmetics.SLOTS, slot) then
		return false, "unknown slot"
	end
	local loadout = wallet.loadouts[wallet.activeLoadout]
	if loadout == nil then
		return false, "no loadout"
	end
	if itemId == nil then
		loadout[slot] = nil
		return true, nil
	end
	local item = Cosmetics.get(itemId)
	if item == nil or item.kind ~= slot then
		return false, "wrong item for that slot"
	end
	if not wallet.cosmetics[itemId] then
		return false, "not owned"
	end
	loadout[slot] = itemId
	return true, nil
end

-- Switches to loadout `index` (creating empty ones up to it) if the player has that many.
function Economy.selectLoadout(wallet: Wallet, index: number, available: number): boolean
	if index < 1 or index > available or index ~= math.floor(index) then
		return false
	end
	for i = #wallet.loadouts + 1, index do
		wallet.loadouts[i] = {}
	end
	wallet.activeLoadout = index
	return true
end

-- The active loadout, keeping only items still owned that fit the weapon in use (weapon skins).
function Economy.resolve(wallet: Wallet, weapon: string?): Loadout
	local out: Loadout = {}
	local loadout: Loadout = wallet.loadouts[wallet.activeLoadout] or {}
	for slot, id in loadout do
		local item = Cosmetics.get(id)
		if item and wallet.cosmetics[id] then
			if slot ~= "weaponSkin" or item.weapon == nil or item.weapon == weapon then
				out[slot] = id
			end
		end
	end
	return out
end

-- Daily ----------------------------------------------------------------------------------------

-- The login reward for logging in on `today`: (gold, new streak), or (0, streak) if already
-- claimed today.
function Economy.loginReward(daily: Daily, today: number, cfg: EconomyConfig): (number, number)
	if daily.lastLoginDay == today then
		return 0, daily.streak
	end
	local streak = if daily.lastLoginDay == today - 1 then daily.streak % cfg.daily.streakDays + 1 else 1
	local gold = math.min(cfg.daily.loginMax, cfg.daily.loginBase + cfg.daily.loginPerDay * (streak - 1))
	return gold, streak
end

-- A small deterministic hash for daily picks.
local function mix(a: number, b: number): number
	local h = (a * 2654435761 + b * 40503) % 4294967296
	h = (h * 1103515245 + 12345) % 2147483648
	return h
end

-- Today's quests for a player: `questCount` distinct quests, the same all day for that player.
function Economy.questsFor(userId: number, day: number, cfg: EconomyConfig): { Quest }
	local pool = cfg.daily.quests
	local indices: { number } = {}
	for i = 1, #pool do
		indices[i] = i
	end
	local seed = mix(userId % 2147483647, day)
	-- Fisher-Yates with the seeded hash.
	for i = #indices, 2, -1 do
		seed = mix(seed, i)
		local j = seed % i + 1
		indices[i], indices[j] = indices[j], indices[i]
	end
	local out: { Quest } = {}
	for i = 1, math.min(cfg.daily.questCount, #pool) do
		table.insert(out, { id = pool[indices[i]].id, progress = 0, done = false })
	end
	return out
end

function Economy.questDef(id: string, cfg: EconomyConfig): QuestDef?
	for _, q in cfg.daily.quests do
		if q.id == id then
			return q
		end
	end
	return nil
end

-- Adds `amount` to every quest tracking `stat`. Returns the gold for quests completed now.
function Economy.progress(daily: Daily, stat: string, amount: number, cfg: EconomyConfig): (number, { string })
	local gold = 0
	local finished: { string } = {}
	for _, quest in daily.quests do
		local def = Economy.questDef(quest.id, cfg)
		if def and def.stat == stat and not quest.done then
			quest.progress = math.min(def.target, quest.progress + amount)
			if quest.progress >= def.target then
				quest.done = true
				gold += def.gold
				table.insert(finished, def.text)
			end
		end
	end
	return gold, finished
end

-- Featured shop items for a day: a rotation through everything for sale.
function Economy.featured(day: number, cfg: EconomyConfig): { string }
	local forSale: { string } = {}
	for _, item in Cosmetics.list do
		if item.price > 0 then
			table.insert(forSale, item.id)
		end
	end
	local out: { string } = {}
	local count = math.min(cfg.featuredCount, #forSale)
	local start = (day * count) % #forSale
	for i = 0, count - 1 do
		table.insert(out, forSale[(start + i) % #forSale + 1])
	end
	return out
end

-- Robux receipts ------------------------------------------------------------------------------

export type ReceiptResult = "granted" | "duplicate" | "unknown"

-- Applies a developer product receipt to the wallet exactly once. "duplicate" means it was
-- already granted (Roblox retried it): grant nothing, but tell Roblox it is done.
function Economy.applyReceipt(
	wallet: Wallet,
	receiptId: string,
	productId: number,
	at: number,
	cfg: EconomyConfig
): (ReceiptResult, number)
	if table.find(wallet.receipts, receiptId) then
		return "duplicate", 0
	end
	local pack: GoldPack? = nil
	for _, p in cfg.goldPacks do
		if p.productId == productId and productId ~= 0 then
			pack = p
		end
	end
	if pack == nil then
		return "unknown", 0
	end
	local gold = (pack :: GoldPack).gold
	wallet.gold += gold
	table.insert(wallet.receipts, receiptId)
	while #wallet.receipts > cfg.receiptHistory do
		table.remove(wallet.receipts, 1)
	end
	table.insert(wallet.purchases, { receipt = receiptId, product = productId, gold = gold, at = at })
	while #wallet.purchases > cfg.purchaseHistory do
		table.remove(wallet.purchases, 1)
	end
	return "granted", gold
end

return Economy
