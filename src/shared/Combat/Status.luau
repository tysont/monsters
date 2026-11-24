--!strict
-- Status effects on combatants (Phase 10). Pure, unit tested under Lune.
--
--   slow        movement speed times (1 - magnitude). The strongest slow applies, capped at
--               rules.maxSlow; slows from different sources do not add up.
--   stun        no moving, attacking or casting. A new stun extends to the longer of the two.
--               When a stun ends the target cannot be stunned again for rules.stunImmunity
--               seconds, so nobody is chain-stunned.
--   shield      absorbs `magnitude` damage before health. Shields from different sources add
--               up to rules.maxShieldFraction of max health; damage drains the one that ends
--               first.
--   regen       heals `magnitude` per second (heal over time). Different sources add up.
--   taunt       monsters and minions attack the source. The latest taunt wins.
--   vulnerable  takes (1 + magnitude) times damage. The strongest applies; no adding up.
--   empower     deals (1 + magnitude) times damage. The strongest applies; no adding up.
--
-- One instance per (kind, source): reapplying from the same source refreshes it (the longer
-- duration and the larger magnitude).

export type Kind = "slow" | "stun" | "shield" | "regen" | "taunt" | "vulnerable" | "empower"

export type Effect = {
	kind: Kind,
	-- Combatant ID that applied it.
	source: number,
	magnitude: number,
	duration: number,
}

export type Active = {
	kind: Kind,
	source: number,
	magnitude: number,
	endsAt: number,
}

export type Set = {
	list: { Active },
	-- No new stuns before this time.
	stunImmuneUntil: number,
}

export type Rules = {
	maxSlow: number,
	stunImmunity: number,
	maxShieldFraction: number,
}

-- Every kind as records (iterating string literals widens them in strict mode).
local KINDS: { { kind: Kind } } = {
	{ kind = "slow" },
	{ kind = "stun" },
	{ kind = "shield" },
	{ kind = "regen" },
	{ kind = "taunt" },
	{ kind = "vulnerable" },
	{ kind = "empower" },
}

local Status = {}

Status.KINDS = KINDS

function Status.new(): Set
	return { list = {}, stunImmuneUntil = -math.huge }
end

-- Drops expired effects (and spent shields). Returns whether anything was removed.
function Status.prune(set: Set, now: number, rules: Rules): boolean
	local removed = false
	local list = set.list
	for i = #list, 1, -1 do
		local a = list[i]
		local stun = a.kind == "stun"
		local spent = a.kind == "shield" and a.magnitude <= 0
		if now >= a.endsAt or spent then
			if stun then
				set.stunImmuneUntil = math.max(set.stunImmuneUntil, a.endsAt + rules.stunImmunity)
			end
			table.remove(list, i)
			removed = true
		end
	end
	return removed
end

local function find(set: Set, kind: Kind, source: number?): Active?
	for _, a in set.list do
		if a.kind == kind and (source == nil or a.source == source) then
			return a
		end
	end
	return nil
end

local function shieldTotal(set: Set, now: number): number
	local total = 0
	for _, a in set.list do
		if a.kind == "shield" and now < a.endsAt then
			total += a.magnitude
		end
	end
	return total
end

-- Applies an effect. `maxHealth` caps shields. Returns false if it had no effect (stun
-- immunity, or a shield cap already reached).
function Status.apply(set: Set, effect: Effect, now: number, maxHealth: number, rules: Rules): boolean
	if effect.duration <= 0 then
		return false
	end
	Status.prune(set, now, rules)
	local endsAt = now + effect.duration
	local kind: string = effect.kind
	if kind == "stun" then
		if now < set.stunImmuneUntil then
			return false
		end
		-- One stun at a time, whoever applied it.
		local stun = find(set, "stun")
		if stun then
			stun.endsAt = math.max(stun.endsAt, endsAt)
			return true
		end
	elseif kind == "taunt" then
		-- The latest taunt replaces any other.
		for i = #set.list, 1, -1 do
			if set.list[i].kind == "taunt" then
				table.remove(set.list, i)
			end
		end
	end
	local magnitude = effect.magnitude
	if kind == "shield" then
		local own = find(set, "shield", effect.source)
		local others = shieldTotal(set, now) - (if own then own.magnitude else 0)
		local room = math.max(0, maxHealth * rules.maxShieldFraction - others)
		magnitude = math.min(magnitude, room)
		if magnitude <= 0 then
			return false
		end
	end
	local existing = find(set, effect.kind, effect.source)
	if existing then
		existing.endsAt = math.max(existing.endsAt, endsAt)
		existing.magnitude = math.max(existing.magnitude, magnitude)
		return true
	end
	local active: Active = { kind = effect.kind, source = effect.source, magnitude = magnitude, endsAt = endsAt }
	table.insert(set.list, active)
	return true
end

function Status.has(set: Set?, kind: Kind, now: number): boolean
	if set == nil then
		return false
	end
	for _, a in set.list do
		if a.kind == kind and now < a.endsAt then
			return true
		end
	end
	return false
end

function Status.stunned(set: Set?, now: number): boolean
	return Status.has(set, "stun", now)
end

local function strongest(set: Set, kind: Kind, now: number): number
	local best = 0
	for _, a in set.list do
		if a.kind == kind and now < a.endsAt and a.magnitude > best then
			best = a.magnitude
		end
	end
	return best
end

-- Movement speed multiplier: 0 while stunned, otherwise 1 minus the strongest slow.
function Status.speedMultiplier(set: Set?, now: number, rules: Rules): number
	if set == nil then
		return 1
	end
	if Status.stunned(set, now) then
		return 0
	end
	return 1 - math.min(rules.maxSlow, strongest(set, "slow", now))
end

-- Damage taken multiplier from the strongest vulnerable effect.
function Status.damageTakenMultiplier(set: Set?, now: number): number
	if set == nil then
		return 1
	end
	return 1 + strongest(set, "vulnerable", now)
end

-- Damage dealt multiplier from the strongest empower effect.
function Status.damageDealtMultiplier(set: Set?, now: number): number
	if set == nil then
		return 1
	end
	return 1 + strongest(set, "empower", now)
end

-- The combatant a taunted monster must attack, if any.
function Status.taunter(set: Set?, now: number): number?
	if set == nil then
		return nil
	end
	local taunt = find(set, "taunt")
	return if taunt and now < taunt.endsAt then taunt.source else nil
end

-- Drains shields (the one ending first goes first). Returns the damage left for health and how
-- much each shield source absorbed ({ [source] = amount }, for support credit).
function Status.absorb(set: Set?, amount: number, now: number): (number, { [number]: number })
	local by: { [number]: number } = {}
	if set == nil or amount <= 0 then
		return amount, by
	end
	local shields: { Active } = {}
	for _, a in set.list do
		if a.kind == "shield" and now < a.endsAt and a.magnitude > 0 then
			table.insert(shields, a)
		end
	end
	table.sort(shields, function(a: Active, b: Active): boolean
		return a.endsAt < b.endsAt
	end)
	local left = amount
	for _, s in shields do
		local take = math.min(left, s.magnitude)
		s.magnitude -= take
		left -= take
		by[s.source] = (by[s.source] or 0) + take
		if left <= 0 then
			break
		end
	end
	return left, by
end

function Status.shield(set: Set?, now: number): number
	return if set then shieldTotal(set, now) else 0
end

-- Heal over time due in `dt` seconds, per source (for support credit).
function Status.regen(set: Set?, now: number, dt: number): { [number]: number }
	local out: { [number]: number } = {}
	if set == nil then
		return out
	end
	for _, a in set.list do
		if a.kind == "regen" and now < a.endsAt then
			out[a.source] = (out[a.source] or 0) + a.magnitude * dt
		end
	end
	return out
end

-- The active kinds, in a fixed order, for icons: e.g. "slow,shield".
function Status.summary(set: Set?, now: number): string
	if set == nil then
		return ""
	end
	local parts: { string } = {}
	for _, entry in KINDS do
		if Status.has(set, entry.kind, now) then
			table.insert(parts, entry.kind)
		end
	end
	return table.concat(parts, ",")
end

return Status
