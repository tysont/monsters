--!strict
-- Contract tests for the Phase 11 balance rules (Shared.Balance).

local Balance = require("../../src/shared/Balance")
local Config = require("../../src/shared/Config")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect
	local cfg = Config.resolve("test").balance

	t.test("equalisers help only the weaker team, scale with the gap, and cap", function()
		local even = Balance.equaliser(1, { 10, 10 }, { 8, 8 }, cfg)
		expect.equal(even.waveStrength, 1)
		expect.equal(even.respawnScale, 1)
		-- Team 2 is 20% weaker: half of the full gap.
		local weak = Balance.equaliser(2, { 10, 8 }, { 8, 8 }, cfg)
		expect.near(weak.waveStrength, 1 + cfg.equaliser.waveStrength * 0.2 / cfg.equaliser.gapForFull, 1e-9)
		expect.truthy(weak.respawnScale < 1)
		expect.truthy(weak.rewardScale > 1)
		local strong = Balance.equaliser(1, { 10, 8 }, { 8, 8 }, cfg)
		expect.equal(strong.waveStrength, 1)
		-- A huge gap is capped.
		local crushed = Balance.equaliser(2, { 100, 1 }, { 8, 8 }, cfg)
		expect.near(crushed.waveStrength, 1 + cfg.equaliser.waveStrength, 1e-9)
		expect.near(crushed.respawnScale, 1 - cfg.equaliser.respawn, 1e-9)
		-- Missing players add wave strength, capped.
		local short = Balance.equaliser(1, { 10, 10 }, { 6, 8 }, cfg)
		expect.near(short.waveStrength, 1 + math.min(cfg.equaliser.shortHandedMax, 2 * cfg.equaliser.shortHanded), 1e-9)
	end)

	t.test("the team behind on structures gets stronger waves, capped", function()
		expect.equal(Balance.behindBonus(0, cfg), 1)
		expect.equal(Balance.behindBonus(-2, cfg), 1)
		expect.near(Balance.behindBonus(1, cfg), 1 + cfg.equaliser.behindPerStructure, 1e-9)
		expect.near(Balance.behindBonus(20, cfg), 1 + cfg.equaliser.behindMax, 1e-9)
	end)

	t.test("waves escalate over the round and siege minions join later", function()
		expect.equal(Balance.escalation(0, cfg), 1)
		expect.equal(Balance.escalation(cfg.escalation.startMinutes, cfg), 1)
		expect.truthy(Balance.escalation(cfg.escalation.startMinutes + 5, cfg) > 1)
		expect.near(Balance.escalation(1000, cfg), 1 + cfg.escalation.max, 1e-9)
		expect.equal(Balance.siegeCount(cfg.escalation.siegeAfterMinutes - 1, cfg), 0)
		expect.equal(Balance.siegeCount(cfg.escalation.siegeAfterMinutes, cfg), 1)
		expect.equal(Balance.siegeCount(1000, cfg), cfg.escalation.siegeMax)
	end)

	t.test("comeback help is strong early and fades to nothing", function()
		local c = cfg.comeback
		expect.equal(Balance.defenderRespawnScale(0, cfg), c.defenderRespawnScale)
		local mid = Balance.defenderRespawnScale((c.fadeStartMinutes + c.fadeEndMinutes) / 2, cfg)
		expect.truthy(mid > c.defenderRespawnScale and mid < 1)
		expect.near(Balance.defenderRespawnScale(c.fadeEndMinutes + 1, cfg), 1, 1e-9)
	end)

	t.test("underdog bonus: none between equals, capped against the strongest", function()
		expect.equal(Balance.underdog(1.2, 1.2, cfg), 1)
		expect.equal(Balance.underdog(1.5, 1, cfg), 1)
		expect.near(Balance.underdog(1, 1.2, cfg), 1 + cfg.underdog.k * 0.2, 1e-9)
		expect.near(Balance.underdog(1, 1.5, cfg), 1 + math.min(cfg.underdog.cap, cfg.underdog.k * 0.5), 1e-9)
	end)

	t.test("three new players beat one maxed player in a straight fight (the 1.5x ceiling)", function()
		-- Effective damage per second over effective health, with the underdog bonus.
		local new, maxed = 1, 1.5
		local newDps = 3 * new * Balance.underdog(new, maxed, cfg)
		local maxedDps = maxed * Balance.underdog(maxed, new, cfg)
		-- Time for the trio to kill the maxed player vs. the maxed player killing all three.
		local trioTime = maxed / newDps
		local soloTime = 3 * new / maxedDps
		expect.truthy(trioTime < soloTime / 2)
	end)

	t.test("bounties start at high power or a streak and grow with the streak", function()
		expect.equal(Balance.bounty(1.1, 1, cfg), 0)
		expect.equal(Balance.bounty(cfg.bounty.power, 0, cfg), cfg.bounty.base)
		expect.equal(Balance.bounty(1, cfg.bounty.streak + 2, cfg), cfg.bounty.base + 2 * cfg.bounty.perStreak)
		expect.equal(Balance.bounty(1, 1000, cfg), cfg.bounty.max)
	end)

	t.test("payout: losers get most of it, contribution, long and close rounds and staying add", function()
		local base = {
			won = true,
			score = 10,
			averageScore = 10,
			minutes = 10,
			lost = { 0, 7 },
			structuresPerTeam = 7,
			stayed = false,
		}
		local win = Balance.payout(base, cfg)
		expect.equal(win, cfg.payout.win)
		local loser = table.clone(base)
		loser.won = false
		expect.equal(Balance.payout(loser, cfg), math.floor(cfg.payout.win * cfg.payout.loseShare + 0.5))
		local star = table.clone(base)
		star.score = 30
		expect.truthy(Balance.payout(star, cfg) > win)
		local idler = table.clone(base)
		idler.score = 0
		expect.truthy(Balance.payout(idler, cfg) < win)
		local epic = table.clone(base)
		epic.minutes = 30
		epic.lost = { 6, 7 }
		epic.stayed = true
		expect.truthy(Balance.payout(epic, cfg) > win * 1.3)
	end)

	t.test("idle after a quiet spell, removed after a long one", function()
		local idle, kick = Balance.idle(0, cfg.idle.idleSeconds - 1, cfg)
		expect.falsy(idle)
		expect.falsy(kick)
		idle, kick = Balance.idle(0, cfg.idle.idleSeconds, cfg)
		expect.truthy(idle)
		expect.falsy(kick)
		idle, kick = Balance.idle(0, cfg.idle.kickSeconds, cfg)
		expect.truthy(kick)
	end)

	t.test("front-line reversals count sustained changes of side only", function()
		expect.equal(Balance.reversals({ 1, 1, -1, 1, 1 }, 2), 0)
		expect.equal(Balance.reversals({ 1, 1, -1, -1, -1, 1, 1 }, 2), 2)
		expect.equal(Balance.reversals({ 0, 0, -1, -1, 0, 1, 1, 1 }, 3), 1)
	end)
end
