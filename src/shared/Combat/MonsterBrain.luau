--!strict
-- The monster behaviour state machine, shared by every monster (gym monsters, guardians, Titans,
-- and jungle monsters from Phase 7). Pure: time and randomness are passed in, so it is unit
-- tested under Lune. MonsterService owns targeting, movement and hit resolution and drives this.
--
--   idle -> telegraph -> attack -> recover -> idle
--                                    |
--                                    +-> stagger (damage while recovering fills the bar) -> idle
--   any -> dead
--
-- `update` returns at most one event per call:
--   telegraph  an attack was chosen; the caller fixes its aim and calls update again at `endsAt`
--   impact     the telegraph finished; the caller resolves the hits
--   phase      the monster entered a new phase (Titans)

local Config = require("../Config")

export type State = "idle" | "telegraph" | "attack" | "recover" | "stagger" | "dead"

export type Brain = {
	state: State,
	stateEndsAt: number,
	-- The attack being telegraphed or just landed.
	attack: Config.MonsterAttack?,
	-- When each attack (by ID) may be chosen again.
	readyAt: { [string]: number },
	-- Stagger bar fill, in damage.
	stagger: number,
	phase: number,
	lastUpdate: number,
}

export type Event = {
	kind: "telegraph" | "impact" | "phase",
	attack: Config.MonsterAttack?,
	endsAt: number?,
	phase: number?,
}

export type Input = {
	-- Distance from the monster's edge to the target's edge, or nil for no target.
	distance: number?,
	healthFraction: number,
}

-- How long the attack state lasts after impact (the swing follow-through).
local ATTACK_SECONDS = 0.2
-- Telegraphs never get shorter than this, however fast a phase is.
local MIN_TELEGRAPH = 0.5

local MonsterBrain = {}

MonsterBrain.ATTACK_SECONDS = ATTACK_SECONDS
MonsterBrain.MIN_TELEGRAPH = MIN_TELEGRAPH

function MonsterBrain.new(now: number): Brain
	return {
		state = "idle",
		stateEndsAt = 0,
		attack = nil,
		readyAt = {},
		stagger = 0,
		phase = 1,
		lastUpdate = now,
	}
end

-- The phase for a health fraction: 1 until the first threshold, then 2, and so on.
function MonsterBrain.phaseFor(definition: Config.MonsterDefinition, healthFraction: number): number
	local phase = 1
	for _, threshold in definition.phases do
		if healthFraction <= threshold then
			phase += 1
		end
	end
	return phase
end

-- Time multiplier for a phase (telegraph, recovery and cooldown).
function MonsterBrain.tempo(definition: Config.MonsterDefinition, phase: number): number
	return definition.phaseTempo ^ (phase - 1)
end

function MonsterBrain.telegraphSeconds(
	definition: Config.MonsterDefinition,
	attack: Config.MonsterAttack,
	phase: number
): number
	return math.max(MIN_TELEGRAPH, attack.telegraphSeconds * MonsterBrain.tempo(definition, phase))
end

function MonsterBrain.recoverSeconds(
	definition: Config.MonsterDefinition,
	attack: Config.MonsterAttack,
	phase: number
): number
	return attack.recoverSeconds * MonsterBrain.tempo(definition, phase)
end

-- Attacks usable right now against a target `distance` away, in definition order.
function MonsterBrain.available(
	brain: Brain,
	definition: Config.MonsterDefinition,
	distance: number,
	now: number
): { Config.MonsterAttack }
	local list: { Config.MonsterAttack } = {}
	for _, attack in definition.attacks do
		local ready = brain.readyAt[attack.id] or -math.huge
		if
			(attack.minPhase or 1) <= brain.phase
			and distance >= attack.minRange
			and distance <= attack.maxRange
			and now >= ready
		then
			table.insert(list, attack)
		end
	end
	return list
end

-- Picks one attack by weight. `roll` is in [0, 1).
function MonsterBrain.pick(attacks: { Config.MonsterAttack }, roll: number): Config.MonsterAttack?
	local total = 0
	for _, attack in attacks do
		total += attack.weight or 1
	end
	if total <= 0 then
		return nil
	end
	local at = roll * total
	for _, attack in attacks do
		at -= attack.weight or 1
		if at < 0 then
			return attack
		end
	end
	return attacks[#attacks]
end

-- Whether any attack could reach a target `distance` away (ignoring cooldowns). Mobile monsters
-- walk closer until this is true.
function MonsterBrain.inReach(brain: Brain, definition: Config.MonsterDefinition, distance: number): boolean
	for _, attack in definition.attacks do
		if (attack.minPhase or 1) <= brain.phase and distance >= attack.minRange and distance <= attack.maxRange then
			return true
		end
	end
	return false
end

function MonsterBrain.update(
	brain: Brain,
	definition: Config.MonsterDefinition,
	now: number,
	input: Input,
	random: () -> number
): Event?
	local dt = math.max(0, now - brain.lastUpdate)
	brain.lastUpdate = now
	if brain.state == "dead" then
		return nil
	end

	if brain.state ~= "recover" and brain.state ~= "stagger" then
		brain.stagger = math.max(0, brain.stagger - definition.stagger.decayPerSecond * dt)
	end

	local phase = MonsterBrain.phaseFor(definition, input.healthFraction)
	if phase > brain.phase then
		brain.phase = phase
		return { kind = "phase", phase = phase }
	end

	if brain.state == "telegraph" then
		if now >= brain.stateEndsAt then
			local attack = brain.attack :: Config.MonsterAttack
			brain.state = "attack"
			brain.stateEndsAt = now + ATTACK_SECONDS
			brain.readyAt[attack.id] = now + attack.cooldown * MonsterBrain.tempo(definition, brain.phase)
			return { kind = "impact", attack = attack }
		end
		return nil
	elseif brain.state == "attack" then
		if now >= brain.stateEndsAt then
			local attack = brain.attack :: Config.MonsterAttack
			brain.state = "recover"
			brain.stateEndsAt = now + MonsterBrain.recoverSeconds(definition, attack, brain.phase)
		end
		return nil
	elseif brain.state == "recover" or brain.state == "stagger" then
		if now >= brain.stateEndsAt then
			brain.state = "idle"
			brain.attack = nil
		else
			return nil
		end
	end

	-- Idle: start an attack if one fits.
	local distance = input.distance
	if distance == nil then
		return nil
	end
	local attack = MonsterBrain.pick(MonsterBrain.available(brain, definition, distance, now), random())
	if attack == nil then
		return nil
	end
	brain.state = "telegraph"
	brain.attack = attack
	brain.stateEndsAt = now + MonsterBrain.telegraphSeconds(definition, attack, brain.phase)
	return { kind = "telegraph", attack = attack, endsAt = brain.stateEndsAt }
end

-- Interrupts the monster for `seconds` (a stun): any telegraph or attack in progress is cancelled
-- and it recovers, so damage in the meantime fills its stagger bar.
function MonsterBrain.interrupt(brain: Brain, now: number, seconds: number)
	if brain.state == "dead" then
		return
	end
	if brain.state == "stagger" then
		brain.stateEndsAt = math.max(brain.stateEndsAt, now + seconds)
		return
	end
	brain.state = "recover"
	brain.attack = nil
	brain.stateEndsAt = now + seconds
end

-- Records damage taken. Damage during recovery fills the stagger bar; a full bar staggers the
-- monster. Returns true when a stagger starts.
function MonsterBrain.onDamaged(
	brain: Brain,
	definition: Config.MonsterDefinition,
	amount: number,
	now: number
): boolean
	if brain.state ~= "recover" then
		return false
	end
	brain.stagger += amount
	if brain.stagger >= definition.stagger.threshold then
		brain.state = "stagger"
		brain.stateEndsAt = now + definition.stagger.seconds
		brain.stagger = 0
		brain.attack = nil
		return true
	end
	return false
end

-- Multiplier on damage the monster takes (the stagger bonus window).
function MonsterBrain.vulnerability(brain: Brain, definition: Config.MonsterDefinition): number
	return if brain.state == "stagger" then definition.stagger.bonus else 1
end

-- Stagger bar for display, 0 to 1: the fill, or while staggered the time left.
function MonsterBrain.staggerFraction(brain: Brain, definition: Config.MonsterDefinition, now: number): number
	if brain.state == "stagger" then
		return math.clamp((brain.stateEndsAt - now) / definition.stagger.seconds, 0, 1)
	end
	return math.clamp(brain.stagger / definition.stagger.threshold, 0, 1)
end

function MonsterBrain.kill(brain: Brain)
	brain.state = "dead"
	brain.attack = nil
end

return MonsterBrain
