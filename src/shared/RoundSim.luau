--!strict
-- A headless, lane-level model of a whole round (Phase 11), for tuning balance numbers before
-- human tests: `make sim` runs thousands of rounds under Lune (scripts/sim.luau).
--
-- It uses the game's own rules and numbers wherever it can: structure health and gating (Monster
-- definitions, Shared.Combat.Structures rules), respawn delays (Shared.Round), equalisers,
-- escalation, siege minions, fading defender help, the underdog bonus and the jungle boss
-- (Shared.Balance). What it models abstractly is play: per lane, a front where the minion waves
-- meet moves towards the side with less force (waves plus players), stops at standing
-- structures, and the attackers there damage the structure; players die in contested lanes in
-- proportion to the enemy's strength and respawn by the real rules.
--
-- Pure (an injected random function), unit tested under Lune.

local Balance = require("./Balance")
local Config = require("./Config")
local Round = require("./Round")

export type Params = {
	-- Seconds per step.
	dt: number,
	-- A round that has not ended by now counts as a draw.
	maxMinutes: number,
	-- Lane fraction the front moves per second at a full force advantage.
	frontSpeed: number,
	-- Random drift of the front per step (standard-ish deviation, lane fraction).
	noise: number,
	-- Lane force per unit of wave strength, and per unit of player power.
	waveForce: number,
	playerForce: number,
	-- Extra force for defenders while the front is at one of their standing structures.
	structureForce: number,
	-- Structure damage per second per unit of attacking player power, and per unit of wave
	-- strength (siege minions count as waves).
	playerStructureDps: number,
	waveStructureDps: number,
	-- Wave strength one siege minion adds.
	siegeWave: number,
	-- Chance per second for each player in a contested lane to die, at even strength.
	deathRate: number,
	-- Extra death chance per second while attacking a structure (it fights back).
	structureDeathRate: number,
	-- Seconds to get back to a lane after respawning (launch pads and walking).
	returnSeconds: number,
	-- Seconds a group takes to kill the jungle boss once it is up.
	bossSeconds: number,
}

local RoundSim = {}

RoundSim.defaults = table.freeze({
	dt = 5,
	maxMinutes = 60,
	frontSpeed = 0.0045,
	noise = 0.03,
	waveForce = 2,
	playerForce = 1,
	structureForce = 3,
	playerStructureDps = 22,
	waveStructureDps = 14,
	siegeWave = 0.6,
	deathRate = 0.004,
	structureDeathRate = 0.003,
	returnSeconds = 15,
	bossSeconds = 75,
} :: Params)

-- Structure positions along a lane, as progress from team 1's base (lanes are mirrored).
local OUTER = 0.32
local INNER = 0.14

export type Player = {
	team: number,
	power: number,
	-- Power times skill: what the player brings to a lane.
	effective: number,
	-- Fighting strength: health and damage both scale with power, so power squared, times skill.
	fight: number,
	lane: number,
	-- Seconds until back in a lane (0 = in its lane).
	away: number,
}

export type Result = {
	minutes: number,
	-- 0 for a draw (time limit).
	winner: number,
	firstGuardian: number,
	reversals: number,
	-- Team strength share of team 1.
	share: number,
}

type LaneState = {
	front: number,
	-- Health of [team][kind]: kind 1 = outer, 2 = inner.
	health: { { number } },
	control: { number },
}

local function structureHealth(c: Config.Config, kind: string): number
	return c.monsters[kind].maxHealth * c.structures.healthScale
end

-- Runs one round. `powers` lists each team's member powers (levels and pets: what the game
-- balances on); `skills` (same shape, optional) multiplies each player's effectiveness in play
-- without the game knowing it. `config` defaults to Config.get() (pass Config.resolve(...) under
-- Lune).
function RoundSim.run(
	powers: { { number } },
	params: Params,
	random: () -> number,
	config: Config.Config?,
	skills: { { number } }?
): Result
	local cfg = config or Config.get()
	local balance = cfg.balance
	local respawn = cfg.respawn
	local outerHealth = structureHealth(cfg, "outerGuardian")
	local innerHealth = structureHealth(cfg, "innerGuardian")
	local titanHealth = { structureHealth(cfg, "titan"), structureHealth(cfg, "titan") }

	local lanes: { LaneState } = {}
	for i = 1, 3 do
		lanes[i] = {
			front = 0.5,
			health = { { outerHealth, innerHealth }, { outerHealth, innerHealth } },
			control = {},
		}
	end
	local players: { Player } = {}
	local strength = { 0, 0 }
	local counts = { 0, 0 }
	for team = 1, 2 do
		for i, p in powers[team] do
			local skill = if skills then skills[team][i] else 1
			table.insert(players, {
				team = team,
				power = p,
				effective = p * skill,
				fight = p * p * skill,
				lane = math.floor(random() * 3) + 1,
				away = 0,
			})
			strength[team] += p
			counts[team] += 1
		end
	end
	local equalisers = {
		Balance.equaliser(1, strength, counts, balance),
		Balance.equaliser(2, strength, counts, balance),
	}

	local t = 0
	local dt = params.dt
	local laneLevel: { { number } }
	local laneCount: { { number } }
	local firstGuardian = 0
	local bossUpAt = balance.boss.firstMinutes * 60
	local bossBuffUntil = { -1, -1 }
	local defendUntil = { -1, -1 }
	local sampleEvery = 10
	local sinceSample = 0

	-- Where the front stops for each team: the first standing structure on the defender's side.
	local function limits(lane: LaneState): (number, number)
		-- Team 1 pushes up to team 2's first standing structure (mirrored positions).
		local high = if lane.health[2][1] > 0 then 1 - OUTER elseif lane.health[2][2] > 0 then 1 - INNER else 1
		local low = if lane.health[1][1] > 0 then OUTER elseif lane.health[1][2] > 0 then INNER else 0
		return low, high
	end

	local function titanOpen(team: number): boolean
		for _, lane in lanes do
			if lane.health[team][2] <= 0 then
				return true
			end
		end
		return false
	end

	while t < params.maxMinutes * 60 do
		local minutes = t / 60
		-- Jungle boss: once up, a team kills it after a while; the stronger side present is more
		-- likely to.
		if t >= bossUpAt then
			local alive = { 0, 0 }
			for _, p in players do
				if p.away <= 0 then
					alive[p.team] += p.effective
				end
			end
			local total = alive[1] ^ 2 + alive[2] ^ 2
			local killer = if total > 0 and random() < alive[1] ^ 2 / total then 1 else 2
			bossBuffUntil[killer] = t + params.bossSeconds + balance.boss.buffSeconds
			bossUpAt = t + params.bossSeconds + balance.boss.respawnMinutes * 60
		end

		-- Lane forces.
		local laneForce: { { number } } = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
		local lanePower: { { number } } = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
		local laneFight: { { number } } = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
		-- Sum of power (levels and pets only) and head count, for the underdog bonus in fights.
		laneLevel = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
		laneCount = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
		for _, p in players do
			if p.away <= 0 then
				lanePower[p.lane][p.team] += p.effective
				laneFight[p.lane][p.team] += p.fight
				laneLevel[p.lane][p.team] += p.power
				laneCount[p.lane][p.team] += 1
			end
		end
		-- Structures lost by each team (for the behind bonus).
		local lost = { 0, 0 }
		for _, lane in lanes do
			for team = 1, 2 do
				for kind = 1, 2 do
					if lane.health[team][kind] <= 0 then
						lost[team] += 1
					end
				end
			end
		end
		local siege = Balance.siegeCount(minutes, balance) * params.siegeWave
		for team = 1, 2 do
			local wave = equalisers[team].waveStrength
					* Balance.escalation(minutes, balance)
					* (if t < bossBuffUntil[team] then 1 + balance.boss.waveBuff else 1)
					* Balance.behindBonus(lost[team] - lost[3 - team], balance)
				+ siege
			for i = 1, 3 do
				laneForce[i][team] = wave * params.waveForce + lanePower[i][team] * params.playerForce
			end
		end

		for i, lane in lanes do
			local low, high = limits(lane)
			local f1, f2 = laneForce[i][1], laneForce[i][2]
			-- Defenders at a standing structure get its help.
			-- Deeper defences hold harder: outer x1, inner x1.5, the Titan x2.
			if lane.front >= high - 1e-6 then
				f2 += params.structureForce * (if high <= 1 - OUTER then 1 elseif high < 1 then 1.5 else 2)
			end
			if lane.front <= low + 1e-6 then
				f1 += params.structureForce * (if low >= OUTER then 1 elseif low > 0 then 1.5 else 2)
			end
			local advantage = (f1 - f2) / math.max(1e-6, f1 + f2)
			local drift = (random() * 2 - 1) * params.noise
			lane.front = math.clamp(lane.front + advantage * params.frontSpeed * dt + drift, low, high)

			-- Sieges.
			for attacker = 1, 2 do
				local defender = 3 - attacker
				local atWall = if attacker == 1 then lane.front >= high - 1e-6 else lane.front <= low + 1e-6
				local pushing = if attacker == 1 then advantage > 0 else advantage < 0
				if atWall and pushing then
					local wave = laneForce[i][attacker] - lanePower[i][attacker] * params.playerForce
					local dps = lanePower[i][attacker] * params.playerStructureDps
						+ (wave / params.waveForce) * params.waveStructureDps
					defendUntil[defender] = t + cfg.structures.alertSeconds
					local h = lane.health[defender]
					if h[1] > 0 then
						h[1] -= dps * dt
						if h[1] <= 0 and firstGuardian == 0 then
							firstGuardian = attacker
						end
					elseif h[2] > 0 then
						h[2] -= dps * dt
					elseif titanOpen(defender) then
						titanHealth[defender] -= dps * dt
					end
				end
			end
		end

		-- Deaths and respawns.
		for _, p in players do
			if p.away > 0 then
				p.away -= dt
				if p.away <= 0 then
					-- Back in a lane: defend the most threatened lane half the time.
					if random() < 0.5 then
						local worst, worstThreat = 1, -math.huge
						for i, lane in lanes do
							-- How far the enemy has pushed towards this team's base.
							local threat = if p.team == 1 then 1 - lane.front else lane.front
							if threat > worstThreat then
								worst, worstThreat = i, threat
							end
						end
						p.lane = worst
					else
						p.lane = math.floor(random() * 3) + 1
					end
				end
				continue
			end
			local mine = laneFight[p.lane][p.team]
			local theirs = laneFight[p.lane][3 - p.team]
			local risk = 0
			if theirs > 0 then
				-- Underdog: weaker attackers hit a stronger player harder (by average power).
				local myAverage = laneLevel[p.lane][p.team] / math.max(1, laneCount[p.lane][p.team])
				local theirAverage = laneLevel[p.lane][3 - p.team] / math.max(1, laneCount[p.lane][3 - p.team])
				risk += params.deathRate * 2 * theirs / (mine + theirs) * Balance.underdog(
					theirAverage,
					myAverage,
					balance
				)
			end
			local lane = lanes[p.lane]
			local low, high = limits(lane)
			local sieging = if p.team == 1
				then lane.front >= high - 1e-6 and high < 1
				else lane.front <= low + 1e-6 and low > 0
			if sieging then
				risk += params.structureDeathRate
			end
			if random() < risk * dt then
				local delay = Round.respawnDelay(respawn, t) * equalisers[p.team].respawnScale
				if t < defendUntil[p.team] then
					delay *= Balance.defenderRespawnScale(minutes, balance)
				end
				p.away = delay + params.returnSeconds
			end
		end

		t += dt
		sinceSample += dt
		if sinceSample >= sampleEvery then
			sinceSample = 0
			for _, lane in lanes do
				table.insert(lane.control, if lane.front > 0.53 then 1 elseif lane.front < 0.47 then -1 else 0)
			end
		end
		for team = 1, 2 do
			if titanHealth[team] <= 0 then
				local reversals = 0
				for _, lane in lanes do
					reversals += Balance.reversals(lane.control, 3)
				end
				return {
					minutes = t / 60,
					winner = 3 - team,
					firstGuardian = firstGuardian,
					reversals = reversals,
					share = strength[1] / (strength[1] + strength[2]),
				}
			end
		end
	end
	local reversals = 0
	for _, lane in lanes do
		reversals += Balance.reversals(lane.control, 3)
	end
	return {
		minutes = params.maxMinutes,
		winner = 0,
		firstGuardian = firstGuardian,
		reversals = reversals,
		share = strength[1] / (strength[1] + strength[2]),
	}
end

export type Summary = {
	rounds: number,
	medianMinutes: number,
	p25Minutes: number,
	p75Minutes: number,
	draws: number,
	-- Share of decided rounds won by the team that killed the first guardian.
	firstGuardianWinRate: number,
	-- Share of decided rounds won by team 1.
	team1WinRate: number,
	reversalsPerRound: number,
}

function RoundSim.summarise(results: { Result }): Summary
	local lengths: { number } = {}
	local decided, firstWins, firstTotal, team1Wins, draws, reversals = 0, 0, 0, 0, 0, 0
	for _, r in results do
		table.insert(lengths, r.minutes)
		reversals += r.reversals
		if r.winner == 0 then
			draws += 1
		else
			decided += 1
			if r.winner == 1 then
				team1Wins += 1
			end
			if r.firstGuardian ~= 0 then
				firstTotal += 1
				if r.firstGuardian == r.winner then
					firstWins += 1
				end
			end
		end
	end
	table.sort(lengths)
	local function pct(p: number): number
		if #lengths == 0 then
			return 0
		end
		return lengths[math.clamp(math.ceil(p * #lengths), 1, #lengths)]
	end
	return {
		rounds = #results,
		medianMinutes = pct(0.5),
		p25Minutes = pct(0.25),
		p75Minutes = pct(0.75),
		draws = draws,
		firstGuardianWinRate = if firstTotal > 0 then firstWins / firstTotal else 0,
		team1WinRate = if decided > 0 then team1Wins / decided else 0,
		reversalsPerRound = if #results > 0 then reversals / #results else 0,
	}
end

return RoundSim
