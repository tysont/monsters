--!strict
-- Contract tests for Shared.Net.RateLimiter: a token bucket of `burst` tokens per key that
-- refills at `rate` tokens per second.

local RateLimiter = require("../../src/shared/Net/RateLimiter")
local TestKit = require("../TestKit")

-- A clock the test controls.
local function fakeClock(): (() -> number, (seconds: number) -> ())
	local now = 0
	return function()
		return now
	end, function(seconds: number)
		now += seconds
	end
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- A new key can spend its whole burst at once, then is refused.
	t.test("allows a full burst then refuses", function()
		local clock = fakeClock()
		local limiter = RateLimiter.new(1, 3, clock)
		expect.truthy(limiter:allow("a"))
		expect.truthy(limiter:allow("a"))
		expect.truthy(limiter:allow("a"))
		expect.falsy(limiter:allow("a"))
	end)

	-- Tokens come back at `rate` per second.
	t.test("refills at the configured rate", function()
		local clock, advance = fakeClock()
		local limiter = RateLimiter.new(2, 1, clock)
		expect.truthy(limiter:allow("a"))
		expect.falsy(limiter:allow("a"))
		advance(0.25)
		expect.falsy(limiter:allow("a"))
		advance(0.25)
		expect.truthy(limiter:allow("a"))
	end)

	-- Refill never exceeds the burst size, however long the key was idle.
	t.test("caps refill at burst", function()
		local clock, advance = fakeClock()
		local limiter = RateLimiter.new(10, 2, clock)
		limiter:allow("a")
		advance(100)
		expect.truthy(limiter:allow("a"))
		expect.truthy(limiter:allow("a"))
		expect.falsy(limiter:allow("a"))
	end)

	-- Each key has its own bucket.
	t.test("keys are independent", function()
		local clock = fakeClock()
		local limiter = RateLimiter.new(1, 1, clock)
		expect.truthy(limiter:allow("a"))
		expect.falsy(limiter:allow("a"))
		expect.truthy(limiter:allow("b"))
	end)

	-- forget gives the key a fresh, full bucket.
	t.test("forget resets a key", function()
		local clock = fakeClock()
		local limiter = RateLimiter.new(1, 1, clock)
		limiter:allow("a")
		expect.falsy(limiter:allow("a"))
		limiter:forget("a")
		expect.truthy(limiter:allow("a"))
	end)

	-- Nonsense settings are rejected at construction.
	t.test("rejects invalid settings", function()
		expect.throws(function()
			RateLimiter.new(0, 1)
		end)
		expect.throws(function()
			RateLimiter.new(1, 0)
		end)
	end)
end
