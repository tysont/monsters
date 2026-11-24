--!strict
-- Runs the round state machine (Shared.Round) on the server clock and replicates it to clients
-- as attributes on ReplicatedStorage (see Round.Attributes), so late joiners see it immediately.
--
--   Ending:        freeze input, show the result.
--   Intermission:  reshuffle teams, reset round state (roundReset), respawn everyone at their
--                  new base, unfreeze.
--   Starting:      spawn anyone missing (late joiners).
--   Active:        play. Ends only through RoundService.finish (Titan death from Phase 6, or the
--                  /endround dev command).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)

local CharacterService = require("./CharacterService")
local TeamService = require("./TeamService")

local TICK_SECONDS = 0.2

local RoundService = {
	name = "RoundService",
	dependencies = { "TeamService", "CharacterService" },
	-- Fires after every phase change with the new state.
	phaseChanged = Signal.new() :: Signal.Signal<Round.State>,
	-- Fires during Intermission after teams are reshuffled and before players respawn. Systems
	-- with per-round state (guardians, eggs, NPCs) reset themselves here.
	roundReset = Signal.new() :: Signal.Signal<number>,
}

local state: Round.State
-- Dev tool: divides the timed phase durations (Phase 14 adds this to the admin panel).
local timeScale = 1

local function now(): number
	return workspace:GetServerTimeNow()
end

local function durations(): Round.Durations
	local round = Config.get().round
	return {
		startingSeconds = round.startingSeconds / timeScale,
		endingSeconds = round.endingSeconds / timeScale,
		intermissionSeconds = round.intermissionSeconds / timeScale,
	}
end

local function publish()
	local a = Round.Attributes
	ReplicatedStorage:SetAttribute(a.phase, state.phase)
	ReplicatedStorage:SetAttribute(a.round, state.round)
	ReplicatedStorage:SetAttribute(a.phaseEndsAt, state.phaseEndsAt)
	ReplicatedStorage:SetAttribute(a.activeSince, state.activeSince)
	ReplicatedStorage:SetAttribute(a.winner, state.winner)
end

local function onEnter(phase: Round.Phase)
	if phase == "Ending" then
		CharacterService.setFrozen(true)
	elseif phase == "Intermission" then
		TeamService.reshuffle()
		RoundService.roundReset:fire(state.round)
		CharacterService.setFrozen(false)
		CharacterService.respawnAll()
	elseif phase == "Starting" then
		CharacterService.setFrozen(false)
		CharacterService.spawnMissing()
	end
	publish()
	RoundService.phaseChanged:fire(state)
end

function RoundService.state(): Round.State
	return state
end

-- Seconds the current round has been Active (0 outside Active).
function RoundService.activeSeconds(): number
	if state.phase ~= "Active" or state.activeSince == nil then
		return 0
	end
	return now() - (state.activeSince :: number)
end

-- Ends the Active round with a winner. Returns false if no round is Active.
function RoundService.finish(winner: number): boolean
	local nextState = Round.finish(state, now(), winner, durations())
	if nextState == nil then
		return false
	end
	state = nextState
	onEnter("Ending")
	return true
end

-- Dev tool: moves the Active round's clock forward by `seconds` (escalation, siege minions, the
-- jungle boss and comeback fading all follow it). Returns false outside Active.
function RoundService.skip(seconds: number): boolean
	if state.phase ~= "Active" or state.activeSince == nil then
		return false
	end
	state.activeSince = (state.activeSince :: number) - seconds
	publish()
	return true
end

-- Dev tool: speeds up timed phases. Applies from the next phase.
function RoundService.setTimeScale(scale: number)
	timeScale = math.clamp(scale, 1, 100)
end

function RoundService.init(_self: typeof(RoundService))
	state = Round.new(now(), durations())
	CharacterService.activeSeconds = RoundService.activeSeconds
	publish()
end

function RoundService.start(_self: typeof(RoundService))
	while true do
		task.wait(TICK_SECONDS)
		local nextState, entered = Round.advance(state, now(), durations())
		if #entered > 0 then
			-- Apply each phase in order so a skipped phase still runs its effects.
			for _, phase in entered do
				state = nextState
				onEnter(phase :: Round.Phase)
			end
		end
	end
end

return RoundService
