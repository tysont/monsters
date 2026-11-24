--!strict
-- Session locking for player profiles. Pure (the data store is injected), unit tested under Lune.
--
-- A stored record is { data, lock = { session, at } }. Loading claims the lock with an atomic
-- update: it succeeds if there is no lock, the lock is ours, or the lock is stale (its owner has
-- not refreshed it for `staleSeconds`, e.g. a crashed server). Saving refreshes the lock; the
-- final save on leave releases it. A save from a session that no longer holds the lock is
-- refused, so two servers can never both write one profile.

export type Lock = { session: string, at: number }

export type Record = { data: any, lock: Lock? }

-- updateAsync(key, transform): calls transform with the current record (or nil) and stores what
-- it returns; returning nil leaves the record unchanged. Returns the stored record.
export type Store = {
	update: (key: string, transform: (current: Record?) -> Record?) -> Record?,
}

export type LoadResult = {
	ok: boolean,
	-- "locked" when another live session holds the profile.
	reason: string?,
	-- The session holding the lock, when locked.
	holder: string?,
	data: any,
}

local SessionLock = {}

function SessionLock.load(store: Store, key: string, session: string, now: number, staleSeconds: number): LoadResult
	local claimed = false
	local lockedBy: string? = nil
	local result = store.update(key, function(current: Record?): Record?
		claimed, lockedBy = false, nil
		local record: Record = current or { data = nil, lock = nil }
		local lock = record.lock
		if lock and lock.session ~= session and now - lock.at < staleSeconds then
			lockedBy = lock.session
			return nil
		end
		claimed = true
		return { data = record.data, lock = { session = session, at = now } }
	end)
	if not claimed then
		return { ok = false, reason = "locked", holder = lockedBy, data = nil }
	end
	return { ok = true, reason = nil, holder = nil, data = if result then result.data else nil }
end

-- Writes `data` if this session still holds the lock; `release` gives the lock up. Returns
-- whether the write happened.
function SessionLock.save(store: Store, key: string, session: string, data: any, now: number, release: boolean): boolean
	local wrote = false
	store.update(key, function(current: Record?): Record?
		wrote = false
		local lock = current and current.lock
		if lock == nil or lock.session ~= session then
			-- Someone else took over (or it was released): never overwrite their data.
			return nil
		end
		wrote = true
		return { data = data, lock = if release then nil else { session = session, at = now } }
	end)
	return wrote
end

-- An in-memory store with the same semantics (tests, and Studio without API access).
function SessionLock.memoryStore(): Store
	local records: { [string]: Record } = {}
	return {
		update = function(key: string, transform: (current: Record?) -> Record?): Record?
			local current = records[key]
			local copy: Record? = if current then table.clone(current) else nil
			local nextRecord = transform(copy)
			if nextRecord ~= nil then
				records[key] = nextRecord
				return nextRecord
			end
			return current
		end,
	}
end

return SessionLock
