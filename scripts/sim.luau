--!nocheck
-- Bot-versus-bot round simulation (Phase 11) on the pure modules: Shared.RoundSim with the real
-- Config. Prints the balance dashboard numbers the Phase 11 acceptance tests ask for.
-- Usage: lune run scripts/sim [rounds] [playersPerTeam] [seed]     (make sim)

local process = require("@lune/process")

local Config = require("../src/shared/Config")
local RoundSim = require("../src/shared/RoundSim")

local rounds = tonumber(process.args[1]) or 2000
local perTeam = tonumber(process.args[2]) or 10
local seed = tonumber(process.args[3]) or 1
local config = Config.resolve("dev")

-- xorshift32: deterministic across runs and machines.
local state = seed
local function random()
	state = bit32.bxor(state, bit32.lshift(state, 13))
	state = bit32.bxor(state, bit32.rshift(state, 17))
	state = bit32.bxor(state, bit32.lshift(state, 5))
	state = bit32.band(state, 0xFFFFFFFF)
	return (state % 1000000) / 1000000
end

-- A server's mix of players: new (1.0) to maxed (1.5) power.
local function drawPower()
	local r = random()
	return 1 + 0.5 * r * r
end

-- How well a player plays this round, independent of level: log-normal, about +-40%.
local function drawSkill()
	local sum = random() + random() + random() + random()
	local normal = (sum - 2) / 0.577
	return math.exp(0.4 * normal)
end

local function skills(n)
	local list = {}
	for _ = 1, n do
		table.insert(list, drawSkill())
	end
	return list
end

local function team(n, scale)
	local list = {}
	for _ = 1, n do
		table.insert(list, drawPower() * scale)
	end
	return list
end

local function line(label, s)
	print(
		string.format(
			"%-34s median %5.1f min (25%% %4.1f, 75%% %4.1f) | first guardian wins %4.1f%% | team 1 wins %4.1f%% | reversals %.1f | draws %d/%d",
			label,
			s.medianMinutes,
			s.p25Minutes,
			s.p75Minutes,
			s.firstGuardianWinRate * 100,
			s.team1WinRate * 100,
			s.reversalsPerRound,
			s.draws,
			s.rounds
		)
	)
end

local params = RoundSim.defaults

local function scenario(label, scale1, n1, n2)
	local results = {}
	local shares = 0
	for _ = 1, rounds do
		local r = RoundSim.run(
			{ team(n1 or perTeam, scale1), team(n2 or perTeam, 1) },
			params,
			random,
			config,
			{ skills(n1 or perTeam), skills(n2 or perTeam) }
		)
		shares += r.share
		table.insert(results, r)
	end
	local s = RoundSim.summarise(results)
	line(string.format("%s (share %.1f%%)", label, shares / rounds * 100), s)
	return s
end

print(`Round simulation: {rounds} rounds per scenario, {perTeam} v {perTeam}, seed {seed}`)
scenario("Even teams", 1)
-- Team 1 holds 55% of the total strength.
scenario("Team 1 at 55% strength", 0.55 / 0.45)
scenario("Team 1 at 60% strength", 0.6 / 0.4)
scenario("Team 1 one player short", 1, perTeam - 1, perTeam)
