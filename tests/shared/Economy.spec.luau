--!strict
-- Contract tests for Phase 12: the cosmetic catalogue, the economy rules, the receipt ledger, and
-- the fairness rule that no cosmetic or purchase changes stats or how fast XP is earned.

local Classes = require("../../src/shared/Classes")
local Config = require("../../src/shared/Config")
local Cosmetics = require("../../src/shared/Cosmetics")
local Economy = require("../../src/shared/Economy")
local Profile = require("../../src/shared/Profile")
local Progression = require("../../src/shared/Progression")
local Stats = require("../../src/shared/Combat/Stats")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local config = Config.resolve("test")
	local cfg = config.economy

	local function wallet(gold: number): Economy.Wallet
		local data = Profile.new()
		data.gold = gold
		return data :: any
	end

	t.test("the catalogue is only looks, within the per-item performance budget", function()
		local itemKeys = {
			id = true,
			name = true,
			kind = true,
			rarity = true,
			price = true,
			weapon = true,
			description = true,
			look = true,
		}
		local lookKeys = {
			color = true,
			color2 = true,
			material = true,
			glow = true,
			particles = true,
			lifetime = true,
			width = true,
			burst = true,
			pose = true,
			text = true,
		}
		expect.truthy(#Cosmetics.list >= 25)
		for _, item in Cosmetics.list do
			for key in item :: any do
				expect.truthy(itemKeys[key])
			end
			for key in item.look :: any do
				expect.truthy(lookKeys[key])
			end
			expect.truthy(table.find(Cosmetics.KINDS, item.kind) ~= nil)
			expect.truthy(table.find(Cosmetics.RARITIES, item.rarity) ~= nil)
			expect.equal(item.price, Cosmetics.PRICE[item.rarity])
			-- Budget: few particles, short thin trails.
			expect.truthy((item.look.particles or 0) <= 12)
			expect.truthy((item.look.lifetime or 0) <= 0.6)
			expect.truthy((item.look.width or 0) <= 2)
			if item.weapon then
				expect.truthy(item.kind == "weaponSkin")
			end
		end
	end)

	t.test("buying needs the gold, once; equipping needs the item in the right slot", function()
		local w = wallet(300)
		expect.falsy((Economy.buy(w, "royal")))
		local ok = Economy.buy(w, "sparktrail")
		expect.truthy(ok)
		expect.equal(w.gold, 50)
		local again, reason = Economy.buy(w, "sparktrail")
		expect.falsy(again)
		expect.equal(reason, "already owned")
		expect.falsy((Economy.equip(w, "trail", "flametrail")))
		expect.falsy((Economy.equip(w, "emote", "sparktrail")))
		expect.truthy((Economy.equip(w, "trail", "sparktrail")))
		expect.equal(w.loadouts[1].trail, "sparktrail")
		expect.truthy((Economy.equip(w, "trail", nil)))
		expect.equal(w.loadouts[1].trail, nil)
	end)

	t.test("loadouts: presets up to what the player has; weapon skins only on their weapon", function()
		local w = wallet(0)
		w.cosmetics.obsidian = true
		w.cosmetics.royal = true
		expect.falsy(Economy.selectLoadout(w, 2, Economy.loadoutCount(false, cfg)))
		expect.truthy(Economy.selectLoadout(w, 3, Economy.loadoutCount(true, cfg)))
		expect.equal(#w.loadouts, 3)
		Economy.equip(w, "weaponSkin", "obsidian")
		expect.equal(Economy.resolve(w, "sword").weaponSkin, "obsidian")
		expect.equal(Economy.resolve(w, "bow").weaponSkin, nil)
		Economy.equip(w, "weaponSkin", "royal")
		expect.equal(Economy.resolve(w, "bow").weaponSkin, "royal")
	end)

	t.test("login streak grows daily, resets after a missed day, pays once a day", function()
		local d = { lastLoginDay = 0, streak = 0, questDay = 0, quests = {} }
		local gold, streak = Economy.loginReward(d, 100, cfg)
		expect.equal(gold, cfg.daily.loginBase)
		expect.equal(streak, 1)
		d.lastLoginDay, d.streak = 100, 1
		expect.equal((Economy.loginReward(d, 100, cfg)), 0)
		gold, streak = Economy.loginReward(d, 101, cfg)
		expect.equal(streak, 2)
		expect.equal(gold, cfg.daily.loginBase + cfg.daily.loginPerDay)
		gold, streak = Economy.loginReward(d, 103, cfg)
		expect.equal(streak, 1)
		d.lastLoginDay, d.streak = 106, cfg.daily.streakDays
		local _, wrapped = Economy.loginReward(d, 107, cfg)
		expect.equal(wrapped, 1)
	end)

	t.test("daily quests are distinct, stable per player and day, and pay once", function()
		local a = Economy.questsFor(12345, 200, cfg)
		local b = Economy.questsFor(12345, 200, cfg)
		expect.equal(#a, cfg.daily.questCount)
		local seen: { [string]: boolean } = {}
		for i, q in a do
			expect.equal(q.id, b[i].id)
			expect.falsy(seen[q.id])
			seen[q.id] = true
		end
		local daily = { lastLoginDay = 0, streak = 0, questDay = 200, quests = a }
		local def = Economy.questDef(a[1].id, cfg) :: Economy.QuestDef
		local gold = Economy.progress(daily, def.stat, def.target - 1, cfg)
		expect.equal(gold, 0)
		gold = Economy.progress(daily, def.stat, 5, cfg)
		expect.truthy(gold >= def.gold)
		expect.equal((Economy.progress(daily, def.stat, 5, cfg)), 0)
	end)

	t.test("featured items rotate daily through what is for sale", function()
		local today = Economy.featured(10, cfg)
		expect.equal(#today, cfg.featuredCount)
		for _, id in today do
			expect.truthy((Cosmetics.get(id) :: Cosmetics.Item).price > 0)
		end
		expect.truthy(Economy.featured(11, cfg)[1] ~= today[1])
	end)

	t.test("a receipt is granted exactly once, however often it is retried", function()
		local packs = table.clone(cfg.goldPacks)
		packs[1] = { id = "gold500", productId = 111, gold = 500, robux = 49 }
		local live = table.clone(cfg) :: any
		live.goldPacks = packs
		local w = wallet(0)
		local result, gold = Economy.applyReceipt(w, "r-1", 111, 1, live)
		expect.equal(result, "granted")
		expect.equal(gold, 500)
		-- Retried (for example after a disconnect before Roblox heard back).
		result, gold = Economy.applyReceipt(w, "r-1", 111, 2, live)
		expect.equal(result, "duplicate")
		expect.equal(gold, 0)
		expect.equal(w.gold, 500)
		expect.equal(#w.purchases, 1)
		expect.equal((Economy.applyReceipt(w, "r-2", 999, 3, live)), "unknown")
		-- Unconfigured products (ID 0) are never granted.
		expect.equal((Economy.applyReceipt(w, "r-3", 0, 3, cfg)), "unknown")
	end)

	t.test("a fully cosmetic-equipped profile has identical stats and XP to a bare one", function()
		local bare = Profile.new()
		local dressed = Profile.new()
		dressed.gold = 1e9
		for _, item in Cosmetics.list do
			dressed.cosmetics[item.id] = true
		end
		for _, slot in Cosmetics.SLOTS do
			for _, item in Cosmetics.list do
				if item.kind == slot then
					Economy.equip(dressed :: any, slot, item.id)
				end
			end
		end
		for _, data in { bare, dressed } do
			Profile.addPet(data, "shellback", 3)
			data.pets[1].xp = 5000
		end
		dressed.pets[1].cosmetic = "goldpet"
		local p = config.progression
		for _, class in Classes do
			for _, level in { 1, 20, 500 } do
				local a = Stats.compute(class.stats, level, Progression.petMultiplier(bare.pets[1].xp, p))
				local b = Stats.compute(class.stats, level, Progression.petMultiplier(dressed.pets[1].xp, p))
				expect.equal(a.maxHealth, b.maxHealth)
				expect.equal(a.damage, b.damage)
				expect.equal(a.defence, b.defence)
				expect.equal(a.power, b.power)
			end
		end
		-- The same XP award moves both the same way.
		local ra = Progression.award(bare.classes.knight, 1, 1000, p)
		local rb = Progression.award(dressed.classes.knight, 1, 1000, p)
		expect.equal(ra.gained, rb.gained)
		expect.equal(bare.classes.knight.level, dressed.classes.knight.level)
		expect.equal(
			Progression.power(bare.classes.knight.level, bare.pets[1].xp, p),
			Progression.power(dressed.classes.knight.level, dressed.pets[1].xp, p)
		)
	end)
end
