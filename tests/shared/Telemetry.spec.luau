--!strict
-- Contract tests for telemetry (Shared.Telemetry): analytics mapping, round records and the
-- balance dashboard.

local TestKit = require("../TestKit")
local Telemetry = require("../../src/shared/Telemetry")

return function(t: TestKit.Context)
	local expect = t.expect

	t.test("player events map to one value and at most three string custom fields", function()
		local name, value, fields = Telemetry.analytics({
			name = "camp_cleared",
			at = 10,
			fields = { monster = "splitter", groupSize = 4, tier = 3, seconds = 13.1 },
		})
		expect.equal(name, "camp_cleared")
		expect.equal(value, 13.1)
		local list = fields :: { string }
		expect.equal(#list, 3)
		expect.equal(list[1], "Monster - splitter")
		expect.equal(list[2], "Group size - 4")
		-- Round-level events are not sent to Roblox analytics.
		expect.equal((Telemetry.analytics({ name = "round_end", at = 0, fields = {} })), nil)
		expect.truthy(Telemetry.known("player_kill"))
		expect.falsy(Telemetry.known("made_up"))
	end)

	t.test("lane control comes from where the two minion fronts meet", function()
		expect.equal(Telemetry.laneControl(0.7, 0.2), 1)
		expect.equal(Telemetry.laneControl(0.2, 0.7), -1)
		expect.equal(Telemetry.laneControl(0.5, 0.5), 0)
	end)

	t.test("a round log becomes a compact record", function()
		local log = Telemetry.newRound(3)
		Telemetry.record(log, { name = "player_kill", at = 60, fields = {} })
		Telemetry.record(log, { name = "guardian_killed", at = 300, fields = { kind = "innerGuardian", byTeam = 1 } })
		Telemetry.record(log, { name = "guardian_killed", at = 200, fields = { kind = "outerGuardian", byTeam = 2 } })
		for _, v in { 1, 1, 1, -1, -1, -1, -1, 1, 1, 1 } do
			Telemetry.sampleControl(log, "middle", v)
		end
		table.insert(log.sizes, { 4, 6 })
		table.insert(log.sizes, { 6, 6 })
		local record =
			Telemetry.summarise(log, 24.25, 2, { { class = "mage", won = true }, { class = "knight", won = false } })
		expect.equal(record.round, 3)
		expect.equal(record.minutes, 24.3)
		expect.equal(record.firstGuardian, 2)
		expect.equal(record.reversals, 2)
		expect.equal(record.kills, 1)
		expect.equal(record.size1, 5)
		expect.equal(record.classes, "mage:1,knight:0")
	end)

	t.test("dashboard: length percentiles, first guardian win rate, class rates", function()
		local function r(minutes: number, winner: number, first: number, classes: string): Telemetry.RoundRecord
			return {
				round = 1,
				minutes = minutes,
				winner = winner,
				size1 = 5,
				size2 = 5,
				reversals = 2,
				firstGuardian = first,
				kills = 0,
				camps = 0,
				eggs = 0,
				bosses = 0,
				classes = classes,
				frameMs = 16,
			}
		end
		local d = Telemetry.dashboard({
			r(18, 1, 1, "mage:1,healer:0"),
			r(22, 2, 1, "mage:0"),
			r(26, 1, 1, "knight:1"),
			r(41, 2, 2, "knight:1"),
		})
		expect.equal(d.rounds, 4)
		expect.equal(d.medianMinutes, 22)
		expect.near(d.firstGuardianWinRate :: number, 0.75, 1e-9)
		expect.equal(d.reversalsPerRound, 2)
		local mage = d.classes[3]
		expect.equal(mage.class, "mage")
		expect.near(mage.winRate, 0.5, 1e-9)
		expect.equal(d.lengthBuckets[9].count, 1)
		expect.truthy(#Telemetry.format(d) >= 3)
	end)
end
