--!strict
-- Token-bucket rate limiter keyed by anything (usually a Player).
-- Each key starts with a full bucket of `burst` tokens; tokens refill at `rate` per second.
-- Pure Luau: the clock is injectable so tests are deterministic.

export type RateLimiter<K> = {
	allow: (self: RateLimiter<K>, key: K) -> boolean,
	forget: (self: RateLimiter<K>, key: K) -> (),
}

type Bucket = { tokens: number, updatedAt: number }

local RateLimiter = {}

function RateLimiter.new<K>(rate: number, burst: number, clock: (() -> number)?): RateLimiter<K>
	assert(rate > 0 and burst >= 1, "rate must be > 0 and burst >= 1")
	local now = clock or os.clock
	local buckets: { [K]: Bucket } = {}

	local limiter = {}

	-- Spends one token for `key` if one is available. Returns false when the key is over its limit.
	function limiter.allow(_self: RateLimiter<K>, key: K): boolean
		local t = now()
		local bucket = buckets[key]
		if bucket == nil then
			bucket = { tokens = burst, updatedAt = t }
			buckets[key] = bucket
		else
			bucket.tokens = math.min(burst, bucket.tokens + (t - bucket.updatedAt) * rate)
			bucket.updatedAt = t
		end
		if bucket.tokens >= 1 then
			bucket.tokens -= 1
			return true
		end
		return false
	end

	-- Drops all state for `key` (call when a player leaves).
	function limiter.forget(_self: RateLimiter<K>, key: K)
		buckets[key] = nil
	end

	return limiter :: RateLimiter<K>
end

return RateLimiter
