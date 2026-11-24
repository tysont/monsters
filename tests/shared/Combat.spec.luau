--!strict
-- Contract tests for Shared.Combat: the stat function, the damage pipeline, melee geometry,
-- position history, snapshot packing and tuning limits.

local Config = require("../../src/shared/Config")
local Damage = require("../../src/shared/Combat/Damage")
local History = require("../../src/shared/Combat/History")
local Melee = require("../../src/shared/Combat/Melee")
local NpcCodec = require("../../src/shared/Combat/NpcCodec")
local Stats = require("../../src/shared/Combat/Stats")
local TestKit = require("../TestKit")
local Tuning = require("../../src/shared/Combat/Tuning")

local KNIGHT = Config.resolve("test").classDefinitions.knight.stats

local function hit(source: number, team: number?, amount: number, now: number): Damage.Hit
	return { sourceId = source, sourceTeam = team, amount = amount, kind = "melee", now = now }
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- Stats ---------------------------------------------------------------------------------

	-- A level 1 player with no pet has exactly the base stats and power 1.
	t.test("level 1 has base stats", function()
		local s = Stats.compute(KNIGHT, 1)
		expect.equal(s.maxHealth, KNIGHT.maxHealth)
		expect.near(s.damage, KNIGHT.damage)
		expect.near(s.power, 1)
	end)

	-- Level 21 is half the level bonus (L = 20); the curve flattens towards 1.25.
	t.test("level multiplier follows Appendix A", function()
		expect.near(Stats.levelMultiplier(21), 1.125)
		expect.truthy(Stats.levelMultiplier(1000) < 1.25)
		expect.truthy(Stats.levelMultiplier(1000) > 1.24)
		expect.truthy(Stats.levelMultiplier(50) > Stats.levelMultiplier(40))
	end)

	-- Maxed level and pet together stay within the 1.5x fairness ceiling.
	t.test("power never exceeds 1.5", function()
		local s = Stats.compute(KNIGHT, 100000, 1.2)
		expect.truthy(s.power <= 1.5)
		expect.truthy(s.power > 1.49)
	end)

	-- Damage --------------------------------------------------------------------------------

	-- A plain hit removes its amount and records the source.
	t.test("hit removes health", function()
		local target = Damage.newCombatant(-1, nil, 100, 0)
		local r = Damage.apply(target, hit(5, 1, 20, 10), 10)
		expect.truthy(r.applied)
		expect.equal(r.amount, 20)
		expect.equal(target.health, 80)
		expect.equal(target.lastDamagedAt, 10)
	end)

	-- Teammates cannot hurt each other; monsters cannot hurt monsters.
	t.test("friendly hits do nothing", function()
		local ally = Damage.newCombatant(1, 2, 100, 0)
		expect.equal(Damage.apply(ally, hit(5, 2, 20, 1), 10).reason, "friendly")
		local monster = Damage.newCombatant(-1, nil, 100, 0)
		expect.equal(Damage.apply(monster, hit(-2, nil, 20, 1), 10).reason, "friendly")
		expect.equal(ally.health, 100)
	end)

	-- Spawn protection and dodge invulnerability both block hits.
	t.test("protected and dodging targets take no damage", function()
		local target = Damage.newCombatant(1, 2, 100, 0)
		target.protected = true
		expect.equal(Damage.apply(target, hit(5, 1, 20, 1), 10).reason, "protected")
		target.protected = false
		target.invulnerableUntil = 5
		expect.equal(Damage.apply(target, hit(5, 1, 20, 4.9), 10).reason, "dodged")
		expect.truthy(Damage.apply(target, hit(5, 1, 20, 5), 10).applied)
	end)

	-- Defence reduces damage by 100 / (100 + defence); hits never round down to nothing.
	t.test("defence reduces damage but never to zero", function()
		expect.equal(Damage.finalAmount(20, 100, nil), 10)
		expect.equal(Damage.finalAmount(0.2, 0, nil), 1)
		expect.equal(Damage.finalAmount(20, 0, { 1.5 }), 30)
	end)

	-- A killing blow reports the kill, never overkills, and lists recent assisters only.
	t.test("kill credits assists within the window", function()
		local target = Damage.newCombatant(1, 2, 50, 0)
		Damage.apply(target, hit(10, 1, 10, 0), 10) -- outside the window by the kill
		Damage.apply(target, hit(11, 1, 10, 15), 10) -- inside
		local r = Damage.apply(target, hit(12, 1, 100, 20), 10)
		expect.truthy(r.killed)
		expect.equal(r.amount, 30)
		expect.deepEqual(r.assists, { 11 })
		expect.falsy(target.alive)
		expect.equal(Damage.apply(target, hit(12, 1, 10, 21), 10).reason, "dead")
	end)

	-- The killer is not also an assister.
	t.test("killer is not an assister", function()
		local target = Damage.newCombatant(1, 2, 30, 0)
		Damage.apply(target, hit(7, 1, 10, 0), 10)
		local r = Damage.apply(target, hit(7, 1, 30, 1), 10)
		expect.deepEqual(r.assists, {})
	end)

	-- Healing stops at max health and does nothing to the dead.
	t.test("heal is capped and ignores the dead", function()
		local target = Damage.newCombatant(1, 2, 100, 0)
		target.health = 90
		expect.equal(Damage.heal(target, 50), 10)
		target.alive = false
		expect.equal(Damage.heal(target, 50), 0)
	end)

	-- Melee ---------------------------------------------------------------------------------

	-- The arc is centred on the facing direction.
	t.test("inArc respects the arc width", function()
		local o = { x = 0, z = 0 }
		local f = { x = 0, z = -1 }
		expect.truthy(Melee.inArc(o, f, { x = 0, z = -5 }, 120))
		expect.truthy(Melee.inArc(o, f, { x = 4, z = -5 }, 120)) -- about 39 degrees
		expect.falsy(Melee.inArc(o, f, { x = 5, z = 0 }, 120)) -- 90 degrees
		expect.falsy(Melee.inArc(o, f, { x = 0, z = 5 }, 300)) -- directly behind
		expect.truthy(Melee.inArc(o, f, { x = 0, z = 5 }, 360))
	end)

	-- Targets must be in range (edge distance) and arc; nearest first, capped.
	t.test("selectTargets filters, sorts and caps", function()
		local candidates = {
			{ id = 1, position = { x = 0, z = -6 }, radius = 1.5 }, -- edge at 4.5, in range
			{ id = 2, position = { x = 0, z = -3 }, radius = 1 },
			{ id = 3, position = { x = 0, z = -12 }, radius = 1 }, -- too far
			{ id = 4, position = { x = 0, z = 3 }, radius = 1 }, -- behind
			{ id = 5, position = { x = 1, z = -4 }, radius = 1 },
		}
		local ids = Melee.selectTargets(
			{ x = 0, z = 0 },
			{ x = 0, z = -1 },
			candidates,
			{ range = 5, arc = 120, maxTargets = 2 }
		)
		expect.deepEqual(ids, { 2, 5 })
	end)

	-- Cooldowns allow requests a little early (jitter) but not much.
	t.test("cooldownReady forgives jitter only", function()
		expect.truthy(Melee.cooldownReady(nil, 0, 1, 0.05))
		expect.truthy(Melee.cooldownReady(10, 10.96, 1, 0.05))
		expect.falsy(Melee.cooldownReady(10, 10.5, 1, 0.05))
	end)

	-- History -------------------------------------------------------------------------------

	-- Positions between samples are interpolated; outside the range they clamp.
	t.test("history interpolates and clamps", function()
		local h = History.new(4)
		History.record(h, 0, 0, 0, 0)
		History.record(h, 1, 10, 0, 0)
		local x = History.sample(h, 0.5)
		expect.near(x :: number, 5)
		expect.near(History.sample(h, 5) :: number, 10)
		expect.near(History.sample(h, -5) :: number, 0)
	end)

	-- The ring keeps only the newest samples.
	t.test("history keeps the newest capacity samples", function()
		local h = History.new(3)
		for i = 0, 5 do
			History.record(h, i, i, 0, 0)
		end
		expect.equal(h.count, 3)
		-- Oldest kept is t = 3, so earlier times clamp to x = 3.
		expect.near(History.sample(h, 0) :: number, 3)
		expect.near(History.sample(h, 4.25) :: number, 4.25)
	end)

	-- An empty history has no position.
	t.test("empty history returns nil", function()
		expect.equal(History.sample(History.new(3), 1), nil)
	end)

	-- NpcCodec ------------------------------------------------------------------------------

	-- Pack then unpack returns the same entities within the fixed-point precision.
	t.test("codec round trips entities", function()
		local entities = {
			{ id = 1, x = 12.5, z = -900.25, yaw = math.pi / 2, health = 0.5, state = 3 },
			{ id = 65535, x = -2000, z = 2000, yaw = 0, health = 1, state = 0 },
		}
		local chunks = NpcCodec.pack(123.5, entities, 900)
		expect.equal(#chunks, 1)
		local time, out = NpcCodec.unpack(chunks[1])
		expect.near(time :: number, 123.5)
		local e = (out :: { NpcCodec.Entity })[1]
		expect.near(e.x, 12.5, 1 / 16)
		expect.near(e.z, -900.25, 1 / 16)
		expect.near(e.yaw, math.pi / 2, 2 * math.pi / 256)
		expect.near(e.health, 0.5, 1 / 255)
		expect.equal(e.state, 3)
		expect.equal((out :: { NpcCodec.Entity })[2].id, 65535)
	end)

	-- Every chunk fits the byte budget, and chunks together hold every entity.
	t.test("codec chunks stay under the byte budget", function()
		local entities = {}
		for i = 1, 300 do
			table.insert(entities, { id = i, x = i, z = -i, yaw = 0, health = 1, state = 0 })
		end
		local chunks = NpcCodec.pack(0, entities, 900)
		local total = 0
		for _, b in chunks do
			expect.truthy(buffer.len(b) <= 900)
			local _, out = NpcCodec.unpack(b)
			total += #(out :: { NpcCodec.Entity })
		end
		expect.equal(total, 300)
		expect.equal(#NpcCodec.pack(0, {}, 900), 0)
	end)

	-- Truncated or padded buffers are rejected.
	t.test("codec rejects malformed buffers", function()
		local chunks = NpcCodec.pack(0, { { id = 1, x = 0, z = 0, yaw = 0, health = 1, state = 0 } }, 900)
		local short = buffer.create(buffer.len(chunks[1]) - 1)
		buffer.copy(short, 0, chunks[1], 0, buffer.len(short))
		expect.equal(NpcCodec.unpack(short), nil)
		expect.equal(NpcCodec.unpack(buffer.create(3)), nil)
	end)

	-- Tuning --------------------------------------------------------------------------------

	-- Values clamp to the definition's range and snap to its step.
	t.test("tuning clamps and snaps", function()
		local d = Tuning.definition("attackCooldown") :: Tuning.Definition
		expect.near(Tuning.clamp(d, 0.52), 0.5)
		expect.near(Tuning.clamp(d, -3), d.min)
		expect.near(Tuning.clamp(d, 99), d.max)
	end)

	-- Every default sits inside its definition's range.
	t.test("tuning defaults are within limits", function()
		local defaults = Config.resolve("test").combat.tuning :: any
		for _, d in Tuning.definitions do
			local v = defaults[d.key]
			if type(v) ~= "number" or v < d.min or v > d.max then
				error(`{d.key} default {v} outside {d.min}..{d.max}`)
			end
		end
		expect.equal(Tuning.definition("nope"), nil)
	end)
end
