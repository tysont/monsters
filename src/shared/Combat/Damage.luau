--!strict
-- The one damage pipeline. Every hit in the game (player melee, monster attacks, later abilities)
-- goes through `Damage.apply`. Pure: the caller supplies the time and applies the result to the
-- world (Humanoid health, NPC rows, effects). Unit tested under Lune.

export type Combatant = {
	-- Players use their UserId; NPCs use negative IDs.
	id: number,
	-- nil for monsters (hostile to every team, friendly to each other).
	team: number?,
	health: number,
	maxHealth: number,
	defence: number,
	alive: boolean,
	-- Server time until which hits are ignored (dodge invulnerability).
	invulnerableUntil: number,
	-- Spawn protection (ForceField) and similar: hits are ignored while true.
	protected: boolean,
	-- Server time of the last damage taken (for out-of-combat regeneration).
	lastDamagedAt: number,
	-- Last time each source damaged this combatant (for assists).
	contributors: { [number]: number },
}

export type Hit = {
	sourceId: number,
	sourceTeam: number?,
	-- Damage before defence.
	amount: number,
	kind: string,
	now: number,
	-- Multipliers applied on top (underdog bonus, stagger window, ...).
	modifiers: { number }?,
}

export type Result = {
	applied: boolean,
	-- Why the hit did nothing: "dead", "friendly", "protected", "dodged".
	reason: string?,
	amount: number,
	killed: boolean,
	-- Other combatants who damaged the target within the assist window (on a kill).
	assists: { number },
}

local Damage = {}

function Damage.newCombatant(id: number, team: number?, maxHealth: number, defence: number): Combatant
	return {
		id = id,
		team = team,
		health = maxHealth,
		maxHealth = maxHealth,
		defence = defence,
		alive = true,
		invulnerableUntil = -math.huge,
		protected = false,
		lastDamagedAt = -math.huge,
		contributors = {},
	}
end

-- Whether two teams can hurt each other. Monsters (nil) never hurt monsters.
function Damage.hostile(a: number?, b: number?): boolean
	return a ~= b
end

-- Final damage after defence and modifiers, at least 1 for any positive amount.
function Damage.finalAmount(amount: number, defence: number, modifiers: { number }?): number
	local value = amount * 100 / (100 + math.max(0, defence))
	local list: { number } = modifiers or {}
	for _, m in list do
		value *= m
	end
	if value <= 0 then
		return 0
	end
	return math.max(1, math.floor(value + 0.5))
end

local function miss(reason: string): Result
	return { applied = false, reason = reason, amount = 0, killed = false, assists = {} }
end

-- Applies a hit to `target` (mutating it) and reports what happened.
function Damage.apply(target: Combatant, hit: Hit, assistWindow: number): Result
	if not target.alive then
		return miss("dead")
	end
	if not Damage.hostile(hit.sourceTeam, target.team) then
		return miss("friendly")
	end
	if target.protected then
		return miss("protected")
	end
	if hit.now < target.invulnerableUntil then
		return miss("dodged")
	end

	local amount = math.min(target.health, Damage.finalAmount(hit.amount, target.defence, hit.modifiers))
	target.health -= amount
	target.lastDamagedAt = hit.now
	target.contributors[hit.sourceId] = hit.now

	local killed = target.health <= 0
	local assists: { number } = {}
	if killed then
		target.alive = false
		target.health = 0
		for id, at in target.contributors do
			if id ~= hit.sourceId and hit.now - at <= assistWindow then
				table.insert(assists, id)
			end
		end
		table.sort(assists)
	end
	return { applied = true, amount = amount, killed = killed, assists = assists }
end

-- Heals up to max health. Returns the amount healed.
function Damage.heal(target: Combatant, amount: number): number
	if not target.alive or amount <= 0 then
		return 0
	end
	local healed = math.min(amount, target.maxHealth - target.health)
	target.health += healed
	return healed
end

return Damage
