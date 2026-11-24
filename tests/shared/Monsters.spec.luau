--!strict
-- Contract tests for the Phase 6 pure modules: Shapes, MonsterBrain and Structures, plus checks
-- that every configured monster attack can be avoided.

local Config = require("../../src/shared/Config")
local Map = require("../../src/shared/Map")
local MonsterBrain = require("../../src/shared/Combat/MonsterBrain")
local Shapes = require("../../src/shared/Combat/Shapes")
local Structures = require("../../src/shared/Combat/Structures")
local TestKit = require("../TestKit")

local function definition(): Config.MonsterDefinition
	return {
		name = "Test",
		maxHealth = 1000,
		radius = 4,
		height = 8,
		speed = 0,
		aggroRange = 30,
		leashRange = 0,
		defence = 0,
		wakeRange = 40,
		attacks = {
			{
				id = "near",
				primitive = "sweep",
				minRange = 0,
				maxRange = 10,
				damage = 10,
				telegraphSeconds = 1,
				recoverSeconds = 1,
				cooldown = 3,
				reach = 12,
				arc = 90,
				knockback = 0,
			},
			{
				id = "far",
				primitive = "projectile",
				minRange = 8,
				maxRange = 30,
				damage = 10,
				telegraphSeconds = 0.6,
				recoverSeconds = 1,
				cooldown = 2,
				radius = 1,
				reach = 40,
				speed = 50,
				count = 1,
				spread = 0,
				knockback = 0,
			},
			{
				id = "late",
				primitive = "slam",
				origin = "self",
				minRange = 0,
				maxRange = 30,
				damage = 10,
				telegraphSeconds = 1,
				recoverSeconds = 1,
				cooldown = 5,
				radius = 10,
				knockback = 0,
				minPhase = 2,
			},
		},
		stagger = { threshold = 100, seconds = 2, bonus = 1.5, decayPerSecond = 10 },
		phases = { 0.5 },
		phaseTempo = 0.8,
	}
end

local function constant(value: number): () -> number
	return function()
		return value
	end
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- Shapes --------------------------------------------------------------------------------

	t.test("inCircle counts the body radius", function()
		expect.truthy(Shapes.inCircle(0, 0, 5, 6, 0, 1.5))
		expect.falsy(Shapes.inCircle(0, 0, 5, 7, 0, 1.5))
	end)

	t.test("inCone checks reach and arc", function()
		-- Facing +x, 90 degrees wide, 10 long.
		expect.truthy(Shapes.inCone(0, 0, 1, 0, 10, 90, 5, 0, 0))
		expect.truthy(Shapes.inCone(0, 0, 1, 0, 10, 90, 5, 4.9, 0))
		expect.falsy(Shapes.inCone(0, 0, 1, 0, 10, 90, 5, 6, 0))
		expect.falsy(Shapes.inCone(0, 0, 1, 0, 10, 90, -5, 0, 0))
		expect.falsy(Shapes.inCone(0, 0, 1, 0, 10, 90, 12, 0, 1))
		-- The body radius widens it a little.
		expect.truthy(Shapes.inCone(0, 0, 1, 0, 10, 90, 5, 6, 1.5))
		-- Standing on the origin always counts.
		expect.truthy(Shapes.inCone(0, 0, 1, 0, 10, 90, 0.5, -0.5, 1))
	end)

	t.test("segmentDistance clamps to the ends", function()
		expect.near(Shapes.segmentDistance(0, 0, 10, 0, 5, 3), 3)
		expect.near(Shapes.segmentDistance(0, 0, 10, 0, -4, 3), 5)
		expect.near(Shapes.segmentDistance(0, 0, 10, 0, 13, 4), 5)
	end)

	t.test("fan spreads directions around the centre", function()
		local fan = Shapes.fan(1, 0, 3, 90)
		expect.equal(#fan, 3)
		expect.near(fan[2].x, 1)
		expect.near(fan[2].z, 0)
		expect.near(fan[1].x, 0, 1e-9)
		expect.near(fan[1].z, -1)
		expect.near(fan[3].z, 1)
	end)

	t.test("worstEscape matches the shape", function()
		expect.near(Shapes.worstEscape({ primitive = "slam", radius = 7 }, 1.5), 8.5)
		expect.near(Shapes.worstEscape({ primitive = "projectile", radius = 1.5 }, 1.5), 3)
		-- A 180 degree cone: back out of the full reach.
		expect.near(Shapes.worstEscape({ primitive = "sweep", reach = 10, arc = 180 }, 0), 10)
		-- 90 degrees: reach * sin45 / (1 + sin45).
		local s = math.sin(math.rad(45))
		expect.near(Shapes.worstEscape({ primitive = "sweep", reach = 10, arc = 90 }, 0), 10 * s / (1 + s))
	end)

	-- MonsterBrain --------------------------------------------------------------------------

	t.test("brain telegraphs, lands, recovers and returns to idle", function()
		local def = definition()
		local brain = MonsterBrain.new(0)
		local input = { distance = 5, healthFraction = 1 }
		local event = MonsterBrain.update(brain, def, 0, input, constant(0))
		expect.equal((event :: MonsterBrain.Event).kind, "telegraph")
		expect.equal(((event :: MonsterBrain.Event).attack :: Config.MonsterAttack).id, "near")
		expect.near((event :: MonsterBrain.Event).endsAt :: number, 1)
		expect.equal(MonsterBrain.update(brain, def, 0.5, input, constant(0)), nil)
		local impact = MonsterBrain.update(brain, def, 1, input, constant(0))
		expect.equal((impact :: MonsterBrain.Event).kind, "impact")
		expect.equal(brain.state, "attack")
		MonsterBrain.update(brain, def, 1 + MonsterBrain.ATTACK_SECONDS, input, constant(0))
		expect.equal(brain.state, "recover")
		-- Recovery ends; "near" is on cooldown, nothing else fits at distance 5.
		expect.equal(MonsterBrain.update(brain, def, 2.5, input, constant(0)), nil)
		expect.equal(brain.state, "idle")
		-- After the cooldown (impact at 1 + 3) it can attack again.
		local again = MonsterBrain.update(brain, def, 4.1, input, constant(0))
		expect.equal((again :: MonsterBrain.Event).kind, "telegraph")
	end)

	t.test("brain picks attacks by range band and weight", function()
		local def = definition()
		local brain = MonsterBrain.new(0)
		local far = MonsterBrain.available(brain, def, 20, 0)
		expect.equal(#far, 1)
		expect.equal(far[1].id, "far")
		-- Both fit at 9; the roll chooses.
		local both = MonsterBrain.available(brain, def, 9, 0)
		expect.equal(#both, 2)
		expect.equal((MonsterBrain.pick(both, 0.1) :: Config.MonsterAttack).id, "near")
		expect.equal((MonsterBrain.pick(both, 0.9) :: Config.MonsterAttack).id, "far")
		expect.equal(MonsterBrain.pick({}, 0.5), nil)
		-- Nothing reaches 50.
		expect.falsy(MonsterBrain.inReach(brain, def, 50))
		expect.equal(MonsterBrain.update(brain, def, 0, { distance = 50, healthFraction = 1 }, constant(0)), nil)
		expect.equal(MonsterBrain.update(brain, def, 0, { distance = nil, healthFraction = 1 }, constant(0)), nil)
	end)

	t.test("brain phases unlock attacks and speed up", function()
		local def = definition()
		local brain = MonsterBrain.new(0)
		expect.equal(MonsterBrain.phaseFor(def, 1), 1)
		expect.equal(MonsterBrain.phaseFor(def, 0.5), 2)
		local event = MonsterBrain.update(brain, def, 0, { distance = 5, healthFraction = 0.4 }, constant(0))
		expect.equal((event :: MonsterBrain.Event).kind, "phase")
		expect.equal((event :: MonsterBrain.Event).phase, 2)
		-- The phase 2 attack is now available, and timings are faster.
		local names = {}
		for _, a in MonsterBrain.available(brain, def, 5, 0) do
			table.insert(names, a.id)
		end
		expect.deepEqual(names, { "near", "late" })
		expect.near(MonsterBrain.telegraphSeconds(def, def.attacks[1], 2), 0.8)
		-- Telegraphs never drop below the floor.
		expect.near(MonsterBrain.telegraphSeconds(def, def.attacks[2], 3), MonsterBrain.MIN_TELEGRAPH)
	end)

	t.test("damage while recovering fills the stagger bar", function()
		local def = definition()
		local brain = MonsterBrain.new(0)
		local input = { distance = 5, healthFraction = 1 }
		-- Damage outside recovery does not count.
		expect.falsy(MonsterBrain.onDamaged(brain, def, 500, 0))
		expect.near(brain.stagger, 0)
		MonsterBrain.update(brain, def, 0, input, constant(0))
		MonsterBrain.update(brain, def, 1, input, constant(0))
		MonsterBrain.update(brain, def, 1.2, input, constant(0))
		expect.equal(brain.state, "recover")
		expect.falsy(MonsterBrain.onDamaged(brain, def, 60, 1.3))
		expect.near(MonsterBrain.staggerFraction(brain, def, 1.3), 0.6)
		expect.near(MonsterBrain.vulnerability(brain, def), 1)
		expect.truthy(MonsterBrain.onDamaged(brain, def, 50, 1.4))
		expect.equal(brain.state, "stagger")
		expect.near(MonsterBrain.vulnerability(brain, def), 1.5)
		expect.near(MonsterBrain.staggerFraction(brain, def, 2.4), 0.5)
		-- No attacks while staggered; idle afterwards.
		expect.equal(MonsterBrain.update(brain, def, 3, input, constant(0)), nil)
		MonsterBrain.update(brain, def, 3.5, input, constant(0))
		expect.truthy(brain.state ~= "stagger")
	end)

	t.test("stagger bar drains outside recovery", function()
		local def = definition()
		local brain = MonsterBrain.new(0)
		brain.stagger = 50
		MonsterBrain.update(brain, def, 2, { distance = nil, healthFraction = 1 }, constant(0))
		expect.near(brain.stagger, 30)
	end)

	t.test("dead brains do nothing", function()
		local def = definition()
		local brain = MonsterBrain.new(0)
		MonsterBrain.kill(brain)
		expect.equal(MonsterBrain.update(brain, def, 1, { distance = 5, healthFraction = 1 }, constant(0)), nil)
		expect.falsy(MonsterBrain.onDamaged(brain, def, 10, 1))
	end)

	-- Structures ----------------------------------------------------------------------------

	t.test("structure list has 12 guardians and 2 Titans", function()
		local list = Structures.list(Map.get())
		expect.equal(#list, 14)
		local keys: { [string]: boolean } = {}
		for _, s in list do
			keys[s.key] = true
		end
		expect.truthy(keys["T1_top_outerGuardian"])
		expect.truthy(keys["T2_bottom_innerGuardian"])
		expect.truthy(keys["T1_titan"])
	end)

	t.test("lane gating orders outer, inner, Titan", function()
		local dead: { [string]: boolean } = {}
		expect.truthy(Structures.vulnerable("outerGuardian", 1, "top", dead))
		expect.falsy(Structures.vulnerable("innerGuardian", 1, "top", dead))
		expect.falsy(Structures.vulnerable("titan", 1, nil, dead))
		dead[Structures.key("outerGuardian", 1, "top")] = true
		expect.truthy(Structures.vulnerable("innerGuardian", 1, "top", dead))
		-- Another lane's outer guardian does not open this one.
		expect.falsy(Structures.vulnerable("innerGuardian", 1, "middle", dead))
		-- The other team is unaffected.
		expect.falsy(Structures.vulnerable("innerGuardian", 2, "top", dead))
		expect.falsy(Structures.vulnerable("titan", 1, nil, dead))
		dead[Structures.key("innerGuardian", 1, "top")] = true
		expect.truthy(Structures.vulnerable("titan", 1, nil, dead))
		expect.falsy(Structures.vulnerable("titan", 2, nil, dead))
	end)

	t.test("guardians prefer provokers, then minions, then nearest", function()
		expect.equal(
			Structures.chooseTarget({
				{ id = 1, distance = 3, isMinion = false, provoked = false },
				{ id = 2, distance = 20, isMinion = true, provoked = false },
				{ id = 3, distance = 25, isMinion = false, provoked = true },
			}),
			3
		)
		expect.equal(
			Structures.chooseTarget({
				{ id = 1, distance = 3, isMinion = false, provoked = false },
				{ id = 2, distance = 20, isMinion = true, provoked = false },
				{ id = 4, distance = 10, isMinion = true, provoked = false },
			}),
			4
		)
		expect.equal(
			Structures.chooseTarget({
				{ id = 1, distance = 8, isMinion = false, provoked = false },
				{ id = 5, distance = 4, isMinion = false, provoked = false },
			}),
			5
		)
		expect.equal(Structures.chooseTarget({}), nil)
	end)

	-- Configured monsters -------------------------------------------------------------------

	-- Every attack can be avoided: a dodge is always ready for the next attack (attacks come no
	-- faster than the dodge cooldown), and the telegraph is long enough to react and dodge.
	t.test("every configured attack can be avoided", function()
		local config = Config.resolve("dev")
		local dodgeCooldown = config.combat.tuning.dodgeCooldown
		local reaction = 0.25
		for id, def in config.monsters do
			for phase = 1, #def.phases + 1 do
				for _, attack in def.attacks do
					if (attack.minPhase or 1) <= phase then
						local telegraph = MonsterBrain.telegraphSeconds(def, attack, phase)
						local cadence = telegraph
							+ MonsterBrain.ATTACK_SECONDS
							+ MonsterBrain.recoverSeconds(def, attack, phase)
						if telegraph < reaction + 0.2 then
							error(`{id}.{attack.id} phase {phase}: telegraph {telegraph} s is too short to react`)
						end
						if cadence < dodgeCooldown + 0.1 then
							error(`{id}.{attack.id} phase {phase}: attacks every {cadence} s, faster than the dodge`)
						end
					end
				end
			end
		end
	end)

	-- Guardian and Titan slams and bolts can also be escaped on foot after reacting.
	t.test("guardian slams and bolts can be walked out of", function()
		local config = Config.resolve("dev")
		local walk = 16
		for _, id in { "outerGuardian", "innerGuardian", "titan" } do
			local def = config.monsters[id]
			for _, attack in def.attacks do
				local target = attack.primitive == "projectile" or attack.origin == "target"
				if target then
					local escape = Shapes.worstEscape(attack :: any, 1.5)
					local time = MonsterBrain.telegraphSeconds(def, attack, #def.phases + 1) - 0.25
					if escape > walk * time then
						error(`{id}.{attack.id}: {escape} studs to escape in {time} s`)
					end
				end
			end
		end
	end)
end
