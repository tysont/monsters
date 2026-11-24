--!strict
-- Smoke tests for the headless round simulator (Shared.RoundSim). The real calibration runs are
-- `make sim`; these only check that it behaves sensibly and deterministically.

local Config = require("../../src/shared/Config")
local RoundSim = require("../../src/shared/RoundSim")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local config = Config.resolve("test")

	-- xorshift32, as in scripts/sim.luau (a plain LCG's consecutive values are correlated enough
	-- to bias the simulator's per-player rolls).
	local function rng(seed: number): () -> number
		local s = seed
		return function(): number
			s = bit32.bxor(s, bit32.lshift(s, 13))
			s = bit32.bxor(s, bit32.rshift(s, 17))
			s = bit32.bxor(s, bit32.lshift(s, 5))
			return (s % 1000000) / 1000000
		end
	end

	local function teams(n: number, power1: number, power2: number): { { number } }
		local a, b = {}, {}
		for i = 1, n do
			a[i] = power1
			b[i] = power2
		end
		return { a, b }
	end

	t.test("rounds end with a winner, a first guardian and a sensible length", function()
		local r = RoundSim.run(teams(6, 1, 1), RoundSim.defaults, rng(3), config)
		expect.truthy(r.minutes > 5 and r.minutes <= RoundSim.defaults.maxMinutes)
		expect.truthy(r.winner == 0 or r.firstGuardian ~= 0)
		expect.near(r.share, 0.5, 1e-9)
	end)

	t.test("the same seed gives the same round", function()
		local a = RoundSim.run(teams(5, 1.2, 1), RoundSim.defaults, rng(11), config)
		local b = RoundSim.run(teams(5, 1.2, 1), RoundSim.defaults, rng(11), config)
		expect.equal(a.minutes, b.minutes)
		expect.equal(a.winner, b.winner)
	end)

	t.test("a far stronger team wins most rounds", function()
		local results = {}
		local random = rng(5)
		for _ = 1, 150 do
			table.insert(results, RoundSim.run(teams(10, 1.5, 1), RoundSim.defaults, random, config))
		end
		local s = RoundSim.summarise(results)
		-- Equalisers soften the edge but must not erase it.
		expect.truthy(s.team1WinRate > 0.55)
		expect.equal(s.rounds, 150)
	end)
end
