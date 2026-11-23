--!strict
-- Live-tunable combat numbers for the dev tuning panel (Phase 3 fun gate). Defaults come from
-- Config.combat.tuning; dev overrides are stored as attributes on ReplicatedStorage.CombatTuning
-- (created by CombatService), so the server and every client read the same values.
-- The definitions and `clamp` are pure; `get` reads the replicated attributes.

local Config = require("../Config")

export type Key =
	"attackCooldown"
	| "attackRange"
	| "attackArc"
	| "dodgeDistance"
	| "dodgeCooldown"
	| "iframes"
	| "hitStop"
	| "knockback"
	| "enemyHealthScale"

export type Definition = {
	key: Key,
	label: string,
	min: number,
	max: number,
	step: number,
}

local Tuning = {}

Tuning.FOLDER_NAME = "CombatTuning"

Tuning.definitions = table.freeze({
	{ key = "attackCooldown", label = "Attack cooldown (s)", min = 0.15, max = 2, step = 0.05 },
	{ key = "attackRange", label = "Attack range", min = 3, max = 15, step = 0.5 },
	{ key = "attackArc", label = "Attack arc (deg)", min = 30, max = 360, step = 10 },
	{ key = "dodgeDistance", label = "Dodge distance", min = 4, max = 30, step = 1 },
	{ key = "dodgeCooldown", label = "Dodge cooldown (s)", min = 0.2, max = 5, step = 0.1 },
	{ key = "iframes", label = "Dodge invulnerable (s)", min = 0, max = 1, step = 0.05 },
	{ key = "hitStop", label = "Hit-stop (s)", min = 0, max = 0.2, step = 0.01 },
	{ key = "knockback", label = "Knockback", min = 0, max = 60, step = 2 },
	{ key = "enemyHealthScale", label = "Enemy health x", min = 0.25, max = 4, step = 0.25 },
} :: { Definition })

function Tuning.definition(key: string): Definition?
	for _, d in Tuning.definitions do
		if d.key == key then
			return d
		end
	end
	return nil
end

-- Clamps to the definition's range and snaps to its step.
function Tuning.clamp(definition: Definition, value: number): number
	local snapped = math.floor((value - definition.min) / definition.step + 0.5) * definition.step + definition.min
	-- Round away floating point noise from the step arithmetic.
	snapped = math.floor(snapped * 1000 + 0.5) / 1000
	return math.clamp(snapped, definition.min, definition.max)
end

function Tuning.default(key: Key): number
	return (Config.get().combat.tuning :: any)[key]
end

local folder: Instance? = nil

-- The current value: a dev override if set, otherwise the Config default.
function Tuning.get(key: Key): number
	if folder == nil then
		folder = game:GetService("ReplicatedStorage"):FindFirstChild(Tuning.FOLDER_NAME)
	end
	local override = if folder then folder:GetAttribute(key) else nil
	if type(override) == "number" then
		return override
	end
	return Tuning.default(key)
end

return Tuning
