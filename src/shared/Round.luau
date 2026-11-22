--!strict
-- The round state machine and related rules, pure and unit tested under Lune. RoundService
-- drives it with the server clock and replicates its state to clients as attributes.
--
--   Starting -> Active -> Ending -> Intermission -> Starting (next round) -> ...
--
-- Starting, Ending and Intermission end on a timer. Active ends only when `finish` is called
-- (a Titan dies, from Phase 6, or a dev command).

local Config = require("./Config")

export type Phase = "Starting" | "Active" | "Ending" | "Intermission"

export type State = {
	phase: Phase,
	-- Starts at 1 and increases each time a new round starts.
	round: number,
	-- Server time the current phase started.
	phaseStartedAt: number,
	-- Server time the current phase ends, or nil while Active.
	phaseEndsAt: number?,
	-- Server time the current round became Active (nil before that).
	activeSince: number?,
	-- Winning team of the round, set when it finishes.
	winner: number?,
}

export type Durations = {
	startingSeconds: number,
	endingSeconds: number,
	intermissionSeconds: number,
}

local Round = {}

-- Names of the attributes RoundService sets on ReplicatedStorage for clients.
Round.Attributes = table.freeze({
	phase = "RoundPhase",
	round = "RoundNumber",
	phaseEndsAt = "RoundPhaseEndsAt",
	activeSince = "RoundActiveSince",
	winner = "RoundWinner",
})

local function enter(state: State, phase: Phase, now: number, seconds: number?): State
	return {
		phase = phase,
		round = state.round,
		phaseStartedAt = now,
		phaseEndsAt = if seconds then now + seconds else nil,
		activeSince = state.activeSince,
		winner = state.winner,
	}
end

function Round.new(now: number, durations: Durations): State
	return {
		phase = "Starting",
		round = 1,
		phaseStartedAt = now,
		phaseEndsAt = now + durations.startingSeconds,
		activeSince = nil,
		winner = nil,
	}
end

-- Advances timed phases. Returns the new state and the phases entered, in order (empty when
-- nothing changed). Several phases can be entered at once if `now` jumped past more than one.
function Round.advance(state: State, now: number, durations: Durations): (State, { Phase })
	local entered: { Phase } = {}
	local current = state
	while current.phaseEndsAt ~= nil and now >= current.phaseEndsAt do
		local at = current.phaseEndsAt :: number
		if current.phase == "Starting" then
			current = enter(current, "Active", at, nil)
			current.activeSince = at
		elseif current.phase == "Ending" then
			current = enter(current, "Intermission", at, durations.intermissionSeconds)
		elseif current.phase == "Intermission" then
			current = enter(current, "Starting", at, durations.startingSeconds)
			current.round += 1
			current.activeSince = nil
			current.winner = nil
		else
			break
		end
		table.insert(entered, current.phase)
	end
	return current, entered
end

-- Ends an Active round with a winner. Returns the new state, or nil if the round is not Active.
function Round.finish(state: State, now: number, winner: number, durations: Durations): State?
	if state.phase ~= "Active" then
		return nil
	end
	local nextState = enter(state, "Ending", now, durations.endingSeconds)
	nextState.winner = winner
	return nextState
end

-- Whether players can move and fight.
function Round.inputAllowed(phase: Phase): boolean
	return phase ~= "Ending"
end

-- Seconds a defeated player waits before respawning, growing with round length.
function Round.respawnDelay(respawn: Config.RespawnConfig, activeSeconds: number): number
	local minutes = math.max(0, activeSeconds) / 60
	return math.min(respawn.maxSeconds, respawn.baseSeconds + respawn.perMinuteSeconds * minutes)
end

-- Seconds for a time remaining value, rounded up, for display ("0:07").
function Round.formatClock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

return Round
