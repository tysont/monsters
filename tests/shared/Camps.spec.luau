--!strict
-- Contract tests for the Phase 7 jungle: camp layout, tiers, group scaling, and the monster
-- definition format.

local Camps = require("../../src/shared/Combat/Camps")
local Config = require("../../src/shared/Config")
local Map = require("../../src/shared/Map")
local MonsterBrain = require("../../src/shared/Combat/MonsterBrain")
local Monsters = require("../../src/shared/Monsters")
local Shapes = require("../../src/shared/Combat/Shapes")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local config = Config.resolve("dev")

	t.test("there are 12 camps with every type at every tier", function()
		local camps = Camps.list(Map.get(), config.camps)
		expect.equal(#camps, 12)
		local seen: { [string]: boolean } = {}
		local perTier = { 0, 0, 0 }
		for _, camp in camps do
			seen[`{camp.monster}:{camp.tier}`] = true
			perTier[camp.tier] += 1
			expect.truthy(config.monsters[camp.monster] ~= nil)
		end
		expect.deepEqual(perTier, { 4, 4, 4 })
		for _, monster in config.camps.types do
			for tier = 1, 3 do
				if not seen[`{monster}:{tier}`] then
					error(`{monster} never appears at tier {tier}`)
				end
			end
		end
	end)

	t.test("centre camps are the hardest tier", function()
		expect.equal(Camps.tierFor(-450, config.camps), 1)
		expect.equal(Camps.tierFor(250, config.camps), 2)
		expect.equal(Camps.tierFor(-120, config.camps), 3)
		local tiers = config.camps.tiers
		expect.truthy(tiers[3].healthScale > tiers[2].healthScale and tiers[2].healthScale > tiers[1].healthScale)
	end)

	t.test("group scaling is mild and capped", function()
		expect.near(Camps.groupScale(1, config.camps), 1)
		expect.near(Camps.groupScale(0, config.camps), 1)
		expect.near(Camps.groupScale(3, config.camps), 1.3)
		expect.near(Camps.groupScale(20, config.camps), config.camps.maxGroupScale)
	end)

	-- Every monster definition is complete and refers only to defined monsters.
	t.test("monster definitions are well formed", function()
		local primitives = {
			slam = true,
			sweep = true,
			projectile = true,
			charge = true,
			summon = true,
			grab = true,
			burrow = true,
		}
		for id, def in Monsters do
			expect.truthy(def.maxHealth > 0 and def.radius > 0 and def.height > 0)
			expect.truthy(#def.attacks >= 1)
			for _, attack in def.attacks do
				if not primitives[attack.primitive] then
					error(`{id}.{attack.id}: unknown primitive {attack.primitive}`)
				end
				if attack.primitive == "summon" then
					local summon = attack.summon
					expect.truthy(summon ~= nil and Monsters[summon.id] ~= nil)
				end
			end
			if def.signature == "splits" then
				local split = def.split
				expect.truthy(split ~= nil and Monsters[split.id] ~= nil)
			end
		end
	end)

	t.test("jungle monsters each have two primitives, a signature and an egg", function()
		for _, id in config.camps.types do
			local def = Monsters[id]
			local kinds: { [string]: boolean } = {}
			for _, attack in def.attacks do
				kinds[attack.primitive] = true
			end
			local count = 0
			for _ in kinds do
				count += 1
			end
			expect.equal(count, 2)
			expect.truthy(def.signature ~= nil)
			expect.equal(def.egg, id)
		end
	end)

	-- Jungle attacks aimed at a target (slams, grabs, eruptions, charges) can be walked out of.
	t.test("jungle targeted attacks can be walked out of", function()
		for _, id in config.camps.types do
			local def = Monsters[id]
			for _, attack in def.attacks do
				local targeted = attack.origin == "target" or attack.primitive == "charge"
				if targeted then
					local shape = {
						primitive = attack.primitive :: string,
						radius = if attack.primitive == "charge" then def.radius else attack.radius,
						reach = attack.reach,
						arc = attack.arc,
					}
					local escape = Shapes.worstEscape(shape, 1.5)
					local time = MonsterBrain.telegraphSeconds(def, attack, 1) - 0.25
					if escape > 16 * time then
						error(`{id}.{attack.id}: {escape} studs to escape in {time} s`)
					end
				end
			end
		end
	end)
end
