--!strict
-- Contract tests for Shared.Round: the phase cycle, finishing rounds, respawn delay and the clock.

local Config = require("../../src/shared/Config")
local Round = require("../../src/shared/Round")
local TestKit = require("../TestKit")

local DURATIONS: Round.Durations = { startingSeconds = 10, endingSeconds = 5, intermissionSeconds = 8 }

return function(t: TestKit.Context)
	local expect = t.expect

	-- A new machine is round 1, Starting, ending after the starting duration.
	t.test("starts in round 1 Starting", function()
		local s = Round.new(100, DURATIONS)
		expect.equal(s.phase, "Starting")
		expect.equal(s.round, 1)
		expect.equal(s.phaseEndsAt, 110)
	end)

	-- Starting becomes Active on time; Active has no end time.
	t.test("Starting becomes Active after its duration", function()
		local s = Round.new(0, DURATIONS)
		local same, none = Round.advance(s, 9.9, DURATIONS)
		expect.equal(same.phase, "Starting")
		expect.equal(#none, 0)
		local active, entered = Round.advance(s, 10, DURATIONS)
		expect.equal(active.phase, "Active")
		expect.deepEqual(entered, { "Active" })
		expect.equal(active.phaseEndsAt, nil)
		expect.equal(active.activeSince, 10)
	end)

	-- Active never ends by time alone.
	t.test("Active does not time out", function()
		local s = Round.advance(Round.new(0, DURATIONS), 10, DURATIONS)
		local later = Round.advance(s, 1e6, DURATIONS)
		expect.equal(later.phase, "Active")
	end)

	-- finish records the winner and moves to Ending; it is refused outside Active.
	t.test("finish ends an Active round only", function()
		local starting = Round.new(0, DURATIONS)
		expect.equal(Round.finish(starting, 1, 1, DURATIONS), nil)
		local active = Round.advance(starting, 10, DURATIONS)
		local ending = Round.finish(active, 30, 2, DURATIONS) :: Round.State
		expect.equal(ending.phase, "Ending")
		expect.equal(ending.winner, 2)
		expect.equal(ending.phaseEndsAt, 35)
		expect.equal(Round.finish(ending, 31, 1, DURATIONS), nil)
	end)

	-- Ending -> Intermission -> Starting of the next round, with the winner cleared.
	t.test("a finished round leads to the next round", function()
		local active = Round.advance(Round.new(0, DURATIONS), 10, DURATIONS)
		local ending = Round.finish(active, 30, 1, DURATIONS) :: Round.State
		local s, entered = Round.advance(ending, 43, DURATIONS)
		expect.deepEqual(entered, { "Intermission", "Starting" })
		expect.equal(s.phase, "Starting")
		expect.equal(s.round, 2)
		expect.equal(s.winner, nil)
		expect.equal(s.activeSince, nil)
		-- Phase times chain from the scheduled end, not from when advance was called.
		expect.equal(s.phaseStartedAt, 43)
		expect.equal(s.phaseEndsAt, 53)
	end)

	-- Acceptance support: twenty consecutive rounds cycle cleanly with nothing carried over.
	t.test("twenty rounds cycle cleanly", function()
		local now = 0
		local s = Round.new(now, DURATIONS)
		for round = 1, 20 do
			expect.equal(s.round, round)
			now = s.phaseEndsAt :: number
			s = Round.advance(s, now, DURATIONS)
			expect.equal(s.phase, "Active")
			now += 60
			s = Round.finish(s, now, (round % 2) + 1, DURATIONS) :: Round.State
			now = s.phaseEndsAt :: number
			s = Round.advance(s, now, DURATIONS)
			expect.equal(s.phase, "Intermission")
			now = s.phaseEndsAt :: number
			s = Round.advance(s, now, DURATIONS)
			expect.equal(s.phase, "Starting")
			expect.equal(s.winner, nil)
		end
		expect.equal(s.round, 21)
	end)

	-- Input is frozen only while the result is shown.
	t.test("input is frozen only in Ending", function()
		expect.truthy(Round.inputAllowed("Starting"))
		expect.truthy(Round.inputAllowed("Active"))
		expect.falsy(Round.inputAllowed("Ending"))
		expect.truthy(Round.inputAllowed("Intermission"))
	end)

	-- Respawn delay starts at the base, grows per minute, and is capped.
	t.test("respawn delay grows with round time and is capped", function()
		local respawn = Config.resolve("test").respawn
		expect.near(Round.respawnDelay(respawn, 0), respawn.baseSeconds)
		expect.near(Round.respawnDelay(respawn, 600), respawn.baseSeconds + respawn.perMinuteSeconds * 10)
		expect.near(Round.respawnDelay(respawn, 1e6), respawn.maxSeconds)
		expect.near(Round.respawnDelay(respawn, -5), respawn.baseSeconds)
	end)

	-- The clock rounds up and never goes negative.
	t.test("formatClock rounds up to whole seconds", function()
		expect.equal(Round.formatClock(6.2), "0:07")
		expect.equal(Round.formatClock(75), "1:15")
		expect.equal(Round.formatClock(-3), "0:00")
	end)
end
