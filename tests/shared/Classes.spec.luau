--!strict
-- Contract tests for Phase 10: status effects, their place in the damage pipeline, and the
-- ability rules and class definitions.

local Abilities = require("../../src/shared/Abilities")
local Classes = require("../../src/shared/Classes")
local Config = require("../../src/shared/Config")
local Damage = require("../../src/shared/Combat/Damage")
local MonsterBrain = require("../../src/shared/Combat/MonsterBrain")
local Status = require("../../src/shared/Combat/Status")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local rules = Config.resolve("test").classes.status

	-- Status effects -----------------------------------------------------------------------

	t.test("the strongest slow applies and slows never add up", function()
		local s = Status.new()
		Status.apply(s, { kind = "slow", source = 1, magnitude = 0.3, duration = 2 }, 0, 100, rules)
		Status.apply(s, { kind = "slow", source = 2, magnitude = 0.5, duration = 1 }, 0, 100, rules)
		expect.near(Status.speedMultiplier(s, 0.5, rules), 0.5, 1e-9)
		-- The stronger one ends; the weaker remains.
		expect.near(Status.speedMultiplier(s, 1.5, rules), 0.7, 1e-9)
		expect.near(Status.speedMultiplier(s, 2.5, rules), 1, 1e-9)
		-- Capped.
		Status.apply(s, { kind = "slow", source = 3, magnitude = 0.99, duration = 1 }, 3, 100, rules)
		expect.near(Status.speedMultiplier(s, 3.1, rules), 1 - rules.maxSlow, 1e-9)
	end)

	t.test("stuns stop movement and grant immunity afterwards", function()
		local s = Status.new()
		expect.truthy(Status.apply(s, { kind = "stun", source = 1, magnitude = 0, duration = 1 }, 0, 100, rules))
		expect.truthy(Status.stunned(s, 0.5))
		expect.equal(Status.speedMultiplier(s, 0.5, rules), 0)
		-- A second stun extends to the longer one, it does not add.
		Status.apply(s, { kind = "stun", source = 2, magnitude = 0, duration = 0.8 }, 0.5, 100, rules)
		expect.truthy(Status.stunned(s, 1.2))
		expect.falsy(Status.stunned(s, 1.31))
		Status.prune(s, 1.31, rules)
		-- Immune right after.
		expect.falsy(Status.apply(s, { kind = "stun", source = 1, magnitude = 0, duration = 1 }, 1.5, 100, rules))
		expect.truthy(
			Status.apply(
				s,
				{ kind = "stun", source = 1, magnitude = 0, duration = 1 },
				1.3 + rules.stunImmunity + 0.01,
				100,
				rules
			)
		)
	end)

	t.test("shields absorb damage first, up to a cap, oldest first", function()
		local s = Status.new()
		Status.apply(s, { kind = "shield", source = 7, magnitude = 30, duration = 5 }, 0, 100, rules)
		Status.apply(s, { kind = "shield", source = 8, magnitude = 1000, duration = 2 }, 0, 100, rules)
		-- Capped at maxShieldFraction of max health in total.
		expect.near(Status.shield(s, 0), 100 * rules.maxShieldFraction, 1e-9)
		local left, by = Status.absorb(s, 40, 0)
		expect.equal(left, 0)
		-- Source 8's ends first and goes first (capped at what was left under the cap: 30).
		expect.equal(by[8], 100 * rules.maxShieldFraction - 30)
		expect.equal(by[7], 40 - (100 * rules.maxShieldFraction - 30))
		local left2 = Status.absorb(s, 100, 0)
		expect.near(left2, 100 - (100 * rules.maxShieldFraction - 40), 1e-9)
	end)

	t.test("taunt: the latest wins; vulnerable: the strongest, no adding", function()
		local s = Status.new()
		Status.apply(s, { kind = "taunt", source = 1, magnitude = 0, duration = 3 }, 0, 100, rules)
		Status.apply(s, { kind = "taunt", source = 2, magnitude = 0, duration = 1 }, 0.5, 100, rules)
		expect.equal(Status.taunter(s, 1), 2)
		expect.equal(Status.taunter(s, 2), nil)
		Status.apply(s, { kind = "vulnerable", source = 1, magnitude = 0.25, duration = 3 }, 0, 100, rules)
		Status.apply(s, { kind = "vulnerable", source = 2, magnitude = 0.1, duration = 3 }, 0, 100, rules)
		expect.near(Status.damageTakenMultiplier(s, 1), 1.25, 1e-9)
		expect.equal(Status.summary(s, 1), "taunt,vulnerable")
	end)

	t.test("regen adds up across sources, per source", function()
		local s = Status.new()
		Status.apply(s, { kind = "regen", source = 1, magnitude = 5, duration = 4 }, 0, 100, rules)
		Status.apply(s, { kind = "regen", source = 2, magnitude = 3, duration = 4 }, 0, 100, rules)
		-- Reapplying from the same source refreshes, it does not stack.
		Status.apply(s, { kind = "regen", source = 1, magnitude = 5, duration = 4 }, 1, 100, rules)
		local due = Status.regen(s, 1, 0.5)
		expect.near(due[1], 2.5, 1e-9)
		expect.near(due[2], 1.5, 1e-9)
		expect.truthy(Status.has(s, "regen", 4.5))
		expect.falsy(Status.has(s, "regen", 5.1))
	end)

	t.test("damage pipeline: vulnerable amplifies, shields absorb, heals credit supporters", function()
		local target = Damage.newCombatant(10, 2, 100, 0)
		target.statuses = Status.new()
		local statuses = target.statuses :: Status.Set
		Status.apply(statuses, { kind = "vulnerable", source = 3, magnitude = 0.5, duration = 5 }, 0, 100, rules)
		local r = Damage.apply(target, { sourceId = 1, sourceTeam = 1, amount = 20, kind = "test", now = 1 }, 10)
		expect.equal(r.amount, 30)
		expect.equal(target.health, 70)
		Status.apply(statuses, { kind = "shield", source = 4, magnitude = 20, duration = 5 }, 1, 100, rules)
		local r2 = Damage.apply(target, { sourceId = 1, sourceTeam = 1, amount = 20, kind = "test", now = 2 }, 10)
		expect.equal(r2.amount, 10)
		expect.equal((r2.absorbed :: { [number]: number })[4], 20)
		expect.equal(target.health, 60)
		expect.equal(Damage.heal(target, 25, 5, 3), 25)
		expect.equal(Damage.heal(target, 5, 10, 3), 5)
		-- The shielder and the healer support the target; the target healing itself does not.
		local supporters = Damage.supportersOf(target, 4, 10)
		expect.equal(#supporters, 2)
		expect.equal(supporters[1], 4)
		expect.equal(supporters[2], 5)
		expect.equal(#Damage.supportersOf(target, 20, 10), 0)
	end)

	-- Abilities and classes -----------------------------------------------------------------

	t.test("every class has a basic attack and three abilities, its full kit by level 10", function()
		local count = 0
		for id, class in Classes do
			count += 1
			expect.equal(class.id, id)
			expect.equal(#class.abilities, Abilities.SLOTS)
			expect.truthy(class.basic.unlockLevel == 1)
			for _, ability in class.abilities do
				expect.truthy(ability.unlockLevel >= 1 and ability.unlockLevel <= 10)
				expect.truthy(ability.cooldown > 0)
				-- Shapes are generous: nothing narrower than a body.
				if ability.shape then
					expect.truthy(ability.shape.size >= 5)
				end
			end
			for _, slot in Abilities.unlockedSlots(class, 10) do
				expect.truthy(slot)
			end
			-- At least one ability from level 1.
			expect.truthy(Abilities.unlockedSlots(class, 1)[1])
			expect.equal(Abilities.milestone(class, 1).level, 1)
			expect.equal(Abilities.milestone(class, 30).level, 25)
		end
		expect.equal(count, 4)
		expect.truthy(Classes[Config.resolve("test").classes.default] ~= nil)
	end)

	t.test("class data uses only known aims, shapes, effects and statuses", function()
		local statuses: { [string]: boolean } = {}
		for _, entry in Status.KINDS do
			statuses[entry.kind] = true
		end
		local aims = { self = true, direction = true, point = true, ally = true }
		local shapes = { circle = true, cone = true, line = true }
		local effects = { damage = true, heal = true, status = true }
		local weapons = { sword = true, bow = true, staff = true, wand = true }
		for _, class in Classes do
			expect.truthy(weapons[class.weapon])
			local all = { class.basic }
			for _, ability in class.abilities do
				table.insert(all, ability)
			end
			for _, ability in all do
				expect.truthy(aims[ability.aim])
				if ability.shape then
					expect.truthy(shapes[ability.shape.kind])
				end
				local lists: { { Classes.Effect } } = { ability.enemy or {}, ability.ally or {}, ability.self or {} }
				for _, list in lists do
					for _, effect in list do
						expect.truthy(effects[effect.kind])
						if effect.kind == "status" then
							expect.truthy(statuses[effect.status or ""])
							expect.truthy((effect.duration or 0) > 0)
						end
					end
				end
				-- Only the Knight's sword uses the melee path; everything else has a shape or an ally.
				expect.truthy(ability.melee or ability.shape ~= nil or ability.aim == "ally")
			end
		end
	end)

	t.test("empower: the strongest applies to damage dealt", function()
		local s = Status.new()
		Status.apply(s, { kind = "empower", source = 1, magnitude = 0.2, duration = 6 }, 0, 100, rules)
		Status.apply(s, { kind = "empower", source = 2, magnitude = 0.2, duration = 6 }, 0, 100, rules)
		expect.near(Status.damageDealtMultiplier(s, 1), 1.2, 1e-9)
		expect.near(Status.damageDealtMultiplier(s, 7), 1, 1e-9)
		expect.near(Status.damageDealtMultiplier(nil, 1), 1, 1e-9)
	end)

	t.test("teamwork: each distinct class beyond the first adds to damage on monsters", function()
		local per = Config.resolve("test").classes.teamworkPerClass
		expect.near(Abilities.teamwork({ knight = true }, per), 1, 1e-9)
		expect.near(Abilities.teamwork({ knight = true, mage = true }, per), 1 + per, 1e-9)
		expect.near(
			Abilities.teamwork({ knight = true, mage = true, hunter = true, healer = true }, per),
			1 + 3 * per,
			1e-9
		)
	end)

	t.test("a stun interrupts a monster's attack into recovery", function()
		local brain = MonsterBrain.new(0)
		brain.state = "telegraph"
		brain.stateEndsAt = 5
		MonsterBrain.interrupt(brain, 1, 1.5)
		expect.equal(brain.state, "recover")
		expect.equal(brain.attack, nil)
		expect.near(brain.stateEndsAt, 2.5, 1e-9)
	end)

	t.test("aim assist snaps to the enemy nearest the aim inside a generous cone", function()
		local origin = { x = 0, z = 0 }
		local candidates = {
			{ id = 1, position = { x = 30, z = 8 }, radius = 1.5 },
			{ id = 2, position = { x = 10, z = -9 }, radius = 1.5 },
			{ id = 3, position = { x = -20, z = 0 }, radius = 1.5 },
		}
		-- Aiming along +x: 1 is about 15 degrees off, 2 about 42; 3 is behind.
		local hit = Abilities.nearestToAim(origin, { x = 1, z = 0 }, candidates, 40, 40)
		expect.equal((hit :: Abilities.Candidate).id, 1)
		local dir = Abilities.assist(origin, { x = 1, z = 0 }, candidates, 40, 40)
		expect.near(dir.x * dir.x + dir.z * dir.z, 1, 1e-9)
		expect.truthy(dir.z > 0.2)
		-- Out of range or outside the cone: the aim is kept.
		local none = Abilities.assist(origin, { x = 0, z = 1 }, candidates, 40, 20)
		expect.near(none.z, 1, 1e-9)
	end)

	t.test("shapes: lines hit the first body along them, circles and cones nearest first", function()
		local line = { kind = "line", size = 40, width = 2.5 } :: Classes.Shape
		local candidates = {
			{ id = 1, position = { x = 20, z = 1 }, radius = 1.5 },
			{ id = 2, position = { x = 10, z = -3 }, radius = 1.5 },
			{ id = 3, position = { x = 10, z = 6 }, radius = 1.5 },
			{ id = 4, position = { x = -5, z = 0 }, radius = 1.5 },
		}
		local hits = Abilities.targets(line, { x = 0, z = 0 }, { x = 1, z = 0 }, candidates, 1)
		expect.equal(#hits, 1)
		expect.equal(hits[1], 2)
		local circle = { kind = "circle", size = 8 } :: Classes.Shape
		local around = Abilities.targets(circle, { x = 10, z = 0 }, { x = 1, z = 0 }, candidates, nil)
		expect.equal(#around, 2)
		expect.equal(around[1], 2)
		local cone = { kind = "cone", size = 25, width = 60 } :: Classes.Shape
		local front = Abilities.targets(cone, { x = 0, z = 0 }, { x = 1, z = 0 }, candidates, 10)
		expect.equal(#front, 3)
		expect.falsy(table.find(front, 4))
	end)

	t.test("points clamp to range; dashes end where they should", function()
		local p = Abilities.clampPoint({ x = 0, z = 0 }, { x = 30, z = 40 }, 10)
		expect.near(p.x, 6, 1e-9)
		expect.near(p.z, 8, 1e-9)
		local charge = Classes.knight.abilities[1]
		local e = Abilities.dashEnd(charge, { x = 0, z = 0 }, { x = 0, z = 2 })
		expect.near(e.z, charge.dash :: number, 1e-9)
		local fireball = Classes.mage.abilities[1]
		local c = Abilities.centre(fireball, { x = 0, z = 0 }, { x = 1, z = 0 }, { x = 100, z = 0 })
		expect.near(c.x, fireball.range :: number, 1e-9)
		-- Shields and heals scale with the caster's damage; other statuses use their magnitude.
		expect.near(Abilities.amount({ kind = "status", status = "shield", scale = 2 }, 10), 20, 1e-9)
		expect.near(Abilities.amount({ kind = "status", status = "slow", magnitude = 0.4 }, 10), 0.4, 1e-9)
	end)
end
