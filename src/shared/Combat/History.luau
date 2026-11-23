--!strict
-- A short ring buffer of timestamped positions, used to rewind targets by an attacker's latency
-- when validating hits. Pure, unit tested under Lune.

export type Sample = { t: number, x: number, y: number, z: number }

export type History = {
	samples: { Sample },
	capacity: number,
	-- Index of the newest sample.
	head: number,
	count: number,
}

local History = {}

function History.new(capacity: number): History
	return { samples = table.create(capacity), capacity = capacity, head = 0, count = 0 }
end

-- Adds a sample. Times must not go backwards.
function History.record(history: History, t: number, x: number, y: number, z: number)
	history.head = history.head % history.capacity + 1
	local slot = history.samples[history.head]
	if slot then
		slot.t, slot.x, slot.y, slot.z = t, x, y, z
	else
		history.samples[history.head] = { t = t, x = x, y = y, z = z }
	end
	history.count = math.min(history.count + 1, history.capacity)
end

-- The i-th newest sample (1 = newest).
local function at(history: History, i: number): Sample
	local index = (history.head - i) % history.capacity + 1
	return history.samples[index]
end

-- Position at time `t`, interpolated between samples and clamped to the oldest and newest.
-- Returns nil when there are no samples.
function History.sample(history: History, t: number): (number?, number?, number?)
	if history.count == 0 then
		return nil, nil, nil
	end
	local newest = at(history, 1)
	if t >= newest.t then
		return newest.x, newest.y, newest.z
	end
	for i = 2, history.count do
		local older = at(history, i)
		if t >= older.t then
			local newer = at(history, i - 1)
			local span = newer.t - older.t
			local a = if span > 0 then (t - older.t) / span else 1
			return older.x + (newer.x - older.x) * a,
				older.y + (newer.y - older.y) * a,
				older.z + (newer.z - older.z) * a
		end
	end
	local oldest = at(history, history.count)
	return oldest.x, oldest.y, oldest.z
end

return History
