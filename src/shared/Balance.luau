--!strict
-- Phase 11 balance rules: equalisers, escalation, fading comeback help, the underdog bonus,
-- bounties, the round payout and idle detection. Pure (no engine access), unit tested under Lune,
-- and shared by the server and the headless round simulator (scripts/sim.luau).
--
--   Equalisers   small, capped help for the weaker team, scaled by the strength gap (as a share
--                of the stronger team's strength) and by missing players: stronger minion waves,
--                shorter respawns, more XP. They nudge a match towards even; they never make a
--                far weaker player beat a far stronger one.
--   Escalation   minion waves get stronger as the round goes on, and siege minions join them
--                after a while, so rounds end.
--   Comeback     the Titan defenders' faster respawn is strongest early and fades away.
--   Underdog     damage against a stronger target is multiplied by
--                1 + k * max(0, Ptarget / Pattacker - 1), capped (Appendix A).
--   Bounties     a strong player or one on a kill streak carries a bounty: extra XP for whoever
--                defeats them.
--   Payout       end of round XP from contribution; the loser gets most of the winner's amount;
--                long and close rounds pay more; staying to the end pays a bonus.

export type BalanceConfig = {
	equaliser: {
		-- The strength gap (as a fraction of the stronger team's strength) at which every
		-- equaliser reaches its cap.
		gapForFull: number,
		-- Caps: minion wave health and damage, respawn time reduction, XP increase.
		waveStrength: number,
		respawn: number,
		reward: number,
		-- Extra wave strength per missing player (headcount behind), up to shortHandedMax.
		shortHanded: number,
		shortHandedMax: number,
		-- Extra wave strength per structure the team has lost more than the other, up to behindMax.
		behindPerStructure: number,
		behindMax: number,
	},
	escalation: {
		-- Wave strength starts growing after this many minutes, by perMinute, up to max.
		startMinutes: number,
		perMinute: number,
		max: number,
		-- Siege minions join waves after this many minutes, one more every siegeEveryMinutes.
		siegeAfterMinutes: number,
		siegeEveryMinutes: number,
		siegeMax: number,
	},
	comeback: {
		-- The Titan defenders' respawn scale while it is under attack, at full strength until
		-- fadeStartMinutes, then fading to 1 (no help) by fadeEndMinutes.
		defenderRespawnScale: number,
		fadeStartMinutes: number,
		fadeEndMinutes: number,
	},
	underdog: { k: number, cap: number },
	bounty: {
		-- A bounty starts at this power or this kill streak.
		power: number,
		streak: number,
		-- XP for defeating a bounty: base, plus perStreak for each kill past the threshold.
		base: number,
		perStreak: number,
		max: number,
	},
	payout: {
		-- XP for winning; the loser gets loseShare of it.
		win: number,
		loseShare: number,
		-- Contribution (score / the round's average score) moves the payout between
		-- (1 - contributionWeight) and (1 + contributionWeight).
		contributionWeight: number,
		-- Long rounds: up to +longBonus, growing from longFromMinutes to longFullMinutes.
		longBonus: number,
		longFromMinutes: number,
		longFullMinutes: number,
		-- Close rounds (few structures between the teams' losses): up to +closeBonus.
		closeBonus: number,
		-- Present for the whole second half of the round.
		stayBonus: number,
	},
	idle: {
		-- Seconds without input before a player counts as idle (left out of team strength and
		-- headcount for joiners), and before they are removed.
		idleSeconds: number,
		kickSeconds: number,
	},
	boss: {
		-- The neutral jungle boss first appears this far into the round, then this long after it
		-- dies. The team that kills it gets stronger waves for buffSeconds.
		firstMinutes: number,
		respawnMinutes: number,
		buffSeconds: number,
		waveBuff: number,
		-- Where it appears (it alternates), and XP for the killing team nearby.
		positions: { { x: number, z: number } },
		killXp: number,
		xpRange: number,
	},
}

export type Equaliser = {
	waveStrength: number,
	respawnScale: number,
	rewardScale: number,
}

local Balance = {}

local NONE: Equaliser = table.freeze({ waveStrength = 1, respawnScale = 1, rewardScale = 1 })

-- Help for `team` given each team's strength and headcount. The stronger team (or either when
-- even) gets none.
function Balance.equaliser(team: number, strength: { number }, counts: { number }, cfg: BalanceConfig): Equaliser
	local other = 3 - team
	local mine, theirs = strength[team] or 0, strength[other] or 0
	local e = cfg.equaliser
	local gapFraction = if theirs > 0 and theirs > mine then (theirs - mine) / theirs else 0
	local t = math.clamp(gapFraction / e.gapForFull, 0, 1)
	local missing = math.max(0, (counts[other] or 0) - (counts[team] or 0))
	local shortHanded = math.min(e.shortHandedMax, missing * e.shortHanded)
	if t <= 0 and shortHanded <= 0 then
		return NONE
	end
	return {
		waveStrength = 1 + e.waveStrength * t + shortHanded,
		respawnScale = 1 - e.respawn * t,
		rewardScale = 1 + e.reward * t,
	}
end

-- Extra wave strength for a team that has lost `deficit` more structures than the other.
function Balance.behindBonus(deficit: number, cfg: BalanceConfig): number
	if deficit <= 0 then
		return 1
	end
	return 1 + math.min(cfg.equaliser.behindMax, deficit * cfg.equaliser.behindPerStructure)
end

-- Wave strength multiplier from escalation at `minutes` into the round.
function Balance.escalation(minutes: number, cfg: BalanceConfig): number
	local e = cfg.escalation
	return 1 + math.clamp((minutes - e.startMinutes) * e.perMinute, 0, e.max)
end

-- Siege minions per wave per lane at `minutes` into the round.
function Balance.siegeCount(minutes: number, cfg: BalanceConfig): number
	local e = cfg.escalation
	if minutes < e.siegeAfterMinutes then
		return 0
	end
	return math.min(e.siegeMax, 1 + math.floor((minutes - e.siegeAfterMinutes) / e.siegeEveryMinutes))
end

-- The Titan defenders' respawn scale while it is under attack, `minutes` into the round.
function Balance.defenderRespawnScale(minutes: number, cfg: BalanceConfig): number
	local c = cfg.comeback
	if minutes <= c.fadeStartMinutes then
		return c.defenderRespawnScale
	end
	local t = math.clamp((minutes - c.fadeStartMinutes) / math.max(1e-6, c.fadeEndMinutes - c.fadeStartMinutes), 0, 1)
	return c.defenderRespawnScale + (1 - c.defenderRespawnScale) * t
end

-- Damage multiplier for an attacker of power `attacker` hitting a target of power `target`.
function Balance.underdog(attacker: number, target: number, cfg: BalanceConfig): number
	if attacker <= 0 then
		return 1
	end
	return 1 + math.min(cfg.underdog.cap, cfg.underdog.k * math.max(0, target / attacker - 1))
end

-- The bounty on a player (XP for defeating them), 0 for none.
function Balance.bounty(power: number, streak: number, cfg: BalanceConfig): number
	local b = cfg.bounty
	if power < b.power and streak < b.streak then
		return 0
	end
	return math.min(b.max, b.base + b.perStreak * math.max(0, streak - b.streak))
end

export type PayoutInput = {
	won: boolean,
	-- This player's score and the round's average score.
	score: number,
	averageScore: number,
	minutes: number,
	-- Structures lost by each team (closeness).
	lost: { number },
	-- Structures per team (for closeness).
	structuresPerTeam: number,
	stayed: boolean,
}

-- How close a round was, 0 (one-sided) to 1 (both teams lost as many structures).
function Balance.closeness(lost: { number }, structuresPerTeam: number): number
	return 1 - math.clamp(math.abs((lost[1] or 0) - (lost[2] or 0)) / math.max(1, structuresPerTeam), 0, 1)
end

-- End of round XP for one player.
function Balance.payout(input: PayoutInput, cfg: BalanceConfig): number
	local p = cfg.payout
	local base = p.win * (if input.won then 1 else p.loseShare)
	local contribution = if input.averageScore > 0 then input.score / input.averageScore else 1
	local factor = 1 + p.contributionWeight * math.clamp(contribution - 1, -1, 1)
	local long = p.longBonus
		* math.clamp((input.minutes - p.longFromMinutes) / math.max(1e-6, p.longFullMinutes - p.longFromMinutes), 0, 1)
	local close = p.closeBonus * Balance.closeness(input.lost, input.structuresPerTeam)
	local amount = base * factor * (1 + long + close)
	if input.stayed then
		amount += p.stayBonus
	end
	return math.floor(amount + 0.5)
end

-- Whether a player who last gave input at `lastInputAt` is idle at `now`, and should be removed.
function Balance.idle(lastInputAt: number, now: number, cfg: BalanceConfig): (boolean, boolean)
	local quiet = now - lastInputAt
	return quiet >= cfg.idle.idleSeconds, quiet >= cfg.idle.kickSeconds
end

-- Front-line reversals in a series of lane-control samples (+1 team 1 ahead, -1 team 2 ahead,
-- 0 even). A reversal is a change of side that then holds for at least `hold` samples.
function Balance.reversals(samples: { number }, hold: number): number
	local side = 0
	local count = 0
	local pending = 0
	local run = 0
	for _, s in samples do
		local sign = if s > 0 then 1 elseif s < 0 then -1 else 0
		if sign == 0 then
			continue
		end
		if side == 0 then
			side = sign
		elseif sign ~= side then
			if sign == pending then
				run += 1
			else
				pending, run = sign, 1
			end
			if run >= hold then
				count += 1
				side = sign
				pending, run = 0, 0
			end
		else
			pending, run = 0, 0
		end
	end
	return count
end

return Balance
