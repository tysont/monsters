--!strict
-- Contract tests for the Phase 8 egg and hatchery rules (Shared.Eggs).

local Config = require("../../src/shared/Config")
local Eggs = require("../../src/shared/Eggs")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local config = Config.resolve("dev").eggs

	t.test("incubation and unleash scale grow with rarity", function()
		expect.equal(Eggs.incubationSeconds("common", config), 60)
		expect.equal(Eggs.incubationSeconds("epic", config), 180)
		expect.equal(Eggs.incubationSeconds("unknown", config), 60)
		expect.truthy(Eggs.rarityScale("epic", config) > Eggs.rarityScale("rare", config))
		expect.equal(Eggs.rarityScale("common", config), 1)
	end)

	t.test("only dropped eggs can be picked up", function()
		expect.truthy(Eggs.canPickUp("dropped"))
		expect.falsy(Eggs.canPickUp("carried"))
		expect.falsy(Eggs.canPickUp("incubating"))
		expect.falsy(Eggs.canPickUp("hatched"))
	end)

	t.test("deposits go to your own team's hatchery with a free slot", function()
		expect.truthy(Eggs.canDeposit(1, 1, 2))
		expect.falsy(Eggs.canDeposit(2, 1, 2))
		expect.falsy(Eggs.canDeposit(1, 1, 0))
		expect.falsy(Eggs.canDeposit(nil, 1, 4))
	end)

	t.test("raids need an enemy, an egg, empty hands and the outer guardian down", function()
		expect.truthy(Eggs.canRaid(2, 1, true, 1, false, config))
		expect.falsy(Eggs.canRaid(2, 1, false, 1, false, config))
		expect.falsy(Eggs.canRaid(1, 1, true, 1, false, config))
		expect.falsy(Eggs.canRaid(2, 1, true, 0, false, config))
		expect.falsy(Eggs.canRaid(2, 1, true, 1, true, config))
		expect.falsy(Eggs.canRaid(nil, 1, true, 1, false, config))
	end)

	t.test("a raid takes the egg closest to hatching", function()
		expect.equal(Eggs.raidPick({ 50, 20, 80 }), 2)
		expect.equal(Eggs.raidPick({}), nil)
	end)

	t.test("carrier movement checks allow the slowed walk plus slack", function()
		-- 16 * 0.7 * 0.5 s * 1.25 = 7 studs, plus 8 slack.
		expect.truthy(Eggs.validCarrierMove(14, 0.5, 16, config))
		expect.falsy(Eggs.validCarrierMove(30, 0.5, 16, config))
	end)

	t.test("hatch choices are claim, feed or unleash", function()
		expect.truthy(Eggs.isChoice("unleash"))
		expect.truthy(Eggs.isChoice("claim"))
		expect.falsy(Eggs.isChoice("gold"))
	end)
end
