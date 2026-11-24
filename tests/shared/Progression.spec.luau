--!strict
-- Contract tests for Phase 9: progression maths, the profile schema and session locking.

local Config = require("../../src/shared/Config")
local Profile = require("../../src/shared/Profile")
local Progression = require("../../src/shared/Progression")
local SessionLock = require("../../src/shared/SessionLock")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local config = Config.resolve("dev")
	local p = config.progression

	-- Levels and XP ---------------------------------------------------------------------------

	t.test("the XP curve grows and never caps", function()
		expect.equal(Progression.xpToNext(1, p), p.xpBase)
		expect.truthy(Progression.xpToNext(20, p) > Progression.xpToNext(10, p))
		expect.truthy(Progression.xpToNext(500, p) > 0)
	end)

	t.test("award levels up through several levels and keeps the remainder", function()
		local progress = { level = 1, xp = 0 }
		local total = Progression.xpToNext(1, p) + Progression.xpToNext(2, p) + 10
		local result = Progression.award(progress, 1, total, p)
		expect.equal(progress.level, 3)
		expect.near(progress.xp, 10)
		expect.equal(result.levelsGained, 2)
	end)

	-- Catch-up: below, at, and crossing the threshold.
	t.test("catch-up doubles XP below the highest class level", function()
		local progress = { level = 1, xp = 0 }
		expect.near(Progression.catchUpAmount(progress, 5, 10, p), 10 * p.catchUpMultiplier)
	end)

	t.test("catch-up stops at the highest class level", function()
		local progress = { level = 5, xp = 0 }
		expect.near(Progression.catchUpAmount(progress, 5, 10, p), 10)
		local above = { level = 7, xp = 0 }
		expect.near(Progression.catchUpAmount(above, 5, 10, p), 10)
	end)

	t.test("an award crossing the threshold is boosted only up to it", function()
		-- Level 1 to 2 needs xpToNext(1) = 100; highest is 2, so 100 XP of gap.
		local progress = { level = 1, xp = 0 }
		local gap = Progression.xpToNext(1, p)
		-- 80 raw: the first 50 raw fill the 100 gap (doubled), the other 30 count once.
		local amount = Progression.catchUpAmount(progress, 2, 80, p)
		expect.near(amount, gap + (80 - gap / p.catchUpMultiplier))
		Progression.award(progress, 2, 80, p)
		expect.equal(progress.level, 2)
		expect.near(progress.xp, 80 - gap / p.catchUpMultiplier)
	end)

	t.test("account level is the sum of class levels and gates slots and titles", function()
		local classes = { knight = { level = 10, xp = 0 }, mage = { level = 6, xp = 0 } }
		expect.equal(Progression.accountLevel(classes), 16)
		expect.equal(Progression.highestLevel(classes), 10)
		expect.equal(Progression.petSlots(1, p), 1)
		expect.equal(Progression.petSlots(16, p), 2)
		expect.equal(Progression.petSlots(40, p), 3)
		expect.deepEqual(Progression.titles(16, p), { "Recruit", "Tamer" })
	end)

	-- A maxed profile is about 1.5 times a new one, never more.
	t.test("combat power ceiling is 1.5", function()
		expect.near(Progression.power(1, nil, p), 1)
		local maxed = Progression.power(100000, 1e9, p)
		expect.truthy(maxed <= 1.5 + 1e-6)
		expect.truthy(maxed > 1.49)
		expect.near(Progression.petMultiplier(p.petHalfXp, p), 1 + p.petBonus / 2)
	end)

	t.test("feeding a matching pet earns the bonus", function()
		expect.equal(Progression.feedXp("rare", "burrower", "shellback", p), p.feedXp.rare)
		expect.equal(
			Progression.feedXp("rare", "burrower", "burrower", p),
			math.floor(p.feedXp.rare * p.feedMatchBonus + 0.5)
		)
	end)

	-- Profile ---------------------------------------------------------------------------------

	t.test("new profiles start at knight level 1 with no pets", function()
		local data = Profile.new()
		expect.equal(data.version, Profile.VERSION)
		expect.equal(data.classes.knight.level, 1)
		expect.equal(#data.pets, 0)
	end)

	t.test("migrate fills missing fields and refuses newer versions", function()
		local stored: any = { version = 1, classes = { knight = { level = 7, xp = 3 } }, activeClass = "knight" }
		local data = Profile.migrate(stored) :: Profile.Data
		expect.equal(data.classes.knight.level, 7)
		expect.equal(data.gold, 0)
		expect.equal(data.stats.wins, 0)
		expect.equal(Profile.migrate({ version = Profile.VERSION + 1 }), nil)
		expect.equal((Profile.migrate(nil) :: Profile.Data).classes.knight.level, 1)
	end)

	t.test("pets fill slots, the first becomes active, and replacing keeps active", function()
		local data = Profile.new()
		local a = Profile.addPet(data, "shellback", 1) :: Profile.Pet
		expect.equal(data.activePet, a.id)
		expect.equal(Profile.addPet(data, "splitter", 1), nil)
		local b = Profile.replacePet(data, a.id, "burrower") :: Profile.Pet
		expect.equal(b.kind, "burrower")
		expect.equal(data.activePet, b.id)
		expect.equal(#data.pets, 1)
	end)

	-- Session lock ----------------------------------------------------------------------------

	t.test("a second session cannot load a locked profile", function()
		local store = SessionLock.memoryStore()
		local first = SessionLock.load(store, "p1", "serverA", 0, 600)
		expect.truthy(first.ok)
		local second = SessionLock.load(store, "p1", "serverB", 10, 600)
		expect.falsy(second.ok)
		expect.equal(second.reason, "locked")
	end)

	t.test("saves need the lock; releasing lets another session in", function()
		local store = SessionLock.memoryStore()
		SessionLock.load(store, "p1", "serverA", 0, 600)
		expect.truthy(SessionLock.save(store, "p1", "serverA", { level = 5 }, 5, false))
		expect.falsy(SessionLock.save(store, "p1", "serverB", { level = 1 }, 6, false))
		expect.truthy(SessionLock.save(store, "p1", "serverA", { level = 6 }, 7, true))
		local next = SessionLock.load(store, "p1", "serverB", 8, 600)
		expect.truthy(next.ok)
		expect.equal(next.data.level, 6)
	end)

	t.test("a stale lock from a dead server can be taken over", function()
		local store = SessionLock.memoryStore()
		SessionLock.load(store, "p1", "serverA", 0, 600)
		local takeover = SessionLock.load(store, "p1", "serverB", 700, 600)
		expect.truthy(takeover.ok)
		-- The old server can no longer write.
		expect.falsy(SessionLock.save(store, "p1", "serverA", { level = 99 }, 701, false))
	end)
end
