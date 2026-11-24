--!strict
-- Telemetry (Phase 11, Appendix B), pure and unit tested under Lune.
--
--   Events: a name from EVENTS plus string/number fields. TelemetryService sends player events to
--   Roblox analytics (AnalyticsService:LogCustomEvent: one value and at most three custom fields,
--   all strings) and keeps every event in a per-round log.
--   Round records: when a round ends its log becomes one compact record (length, winner, team
--   sizes, front-line reversals, first guardian, kills, camps, eggs, classes and results,
--   performance) for the custom sink, a DataStore that keeps the last rounds.
--   Dashboard: round length distribution, first-guardian win rate, reversals per round, class
--   pick and win rates, from a list of records.

local Balance = require("./Balance")

export type Fields = { [string]: string | number | boolean }

export type Event = {
	name: string,
	-- Seconds into the round (or since the server started outside a round).
	at: number,
	fields: Fields,
}

-- Every event name (Appendix B). Roblox caps custom event names at 100.
local EVENTS: { [string]: boolean } = {
	round_start = true,
	round_end = true,
	guardian_killed = true,
	titan_phase = true,
	player_join = true,
	player_leave = true,
	player_kill = true,
	camp_cleared = true,
	egg_event = true,
	level_up = true,
	pet_progress = true,
	economy = true,
	purchase = true,
	onboarding_step = true,
	performance_sample = true,
	boss_killed = true,
	bounty_claimed = true,
}

-- For each event sent to Roblox analytics: the numeric field used as its value and up to three
-- fields shown as custom fields ("Label - value").
local ANALYTICS: { [string]: { value: string?, fields: { string } } } = {
	player_join = { fields = { "team", "class", "level" } },
	player_leave = { value = "sessionMinutes", fields = { "team", "class", "roundMinute" } },
	player_kill = { fields = { "killerClass", "victimClass", "bounty" } },
	camp_cleared = { value = "seconds", fields = { "monster", "groupSize", "tier" } },
	egg_event = { fields = { "action", "kind", "rarity" } },
	level_up = { value = "level", fields = { "class", "level" } },
	pet_progress = { value = "xp", fields = { "kind" } },
	bounty_claimed = { value = "amount", fields = { "killerClass" } },
}

local Telemetry = {}

function Telemetry.known(name: string): boolean
	return EVENTS[name] == true
end

local function label(key: string): string
	-- "groupSize" -> "Group size"
	local spaced = string.gsub(key, "(%u)", function(c: string): string
		return " " .. string.lower(c)
	end)
	return string.upper(string.sub(spaced, 1, 1)) .. string.sub(spaced, 2)
end

-- What to send to AnalyticsService for an event, or nil if it is not sent there:
-- the event name, its value, and the custom field values in order (CustomField01 to 03).
function Telemetry.analytics(event: Event): (string?, number?, { string }?)
	local spec = ANALYTICS[event.name]
	if spec == nil then
		return nil, nil, nil
	end
	local value: number? = nil
	if spec.value then
		local v = event.fields[spec.value]
		value = if type(v) == "number" then v else nil
	end
	local fields: { string } = {}
	for i, key in spec.fields do
		if i > 3 then
			break
		end
		local v = event.fields[key]
		table.insert(fields, `{label(key)} - {if v == nil then "none" else tostring(v)}`)
	end
	return event.name, value, fields
end

-- Per-round log -------------------------------------------------------------------------------

export type RoundLog = {
	round: number,
	events: { Event },
	-- Lane control samples per lane: +1 team 1 ahead, -1 team 2 ahead, 0 even.
	control: { [string]: { number } },
	-- Team sizes sampled over the round.
	sizes: { { number } },
	frameMs: { number },
}

export type RoundRecord = {
	round: number,
	minutes: number,
	winner: number,
	-- Average team sizes over the round.
	size1: number,
	size2: number,
	reversals: number,
	-- The team that destroyed the first guardian (0 for none).
	firstGuardian: number,
	kills: number,
	camps: number,
	eggs: number,
	bosses: number,
	-- Class of each player present at the end and whether their team won: "mage:1,knight:0".
	classes: string,
	frameMs: number,
}

function Telemetry.newRound(round: number): RoundLog
	return { round = round, events = {}, control = {}, sizes = {}, frameMs = {} }
end

function Telemetry.record(log: RoundLog, event: Event)
	table.insert(log.events, event)
end

function Telemetry.sampleControl(log: RoundLog, lane: string, value: number)
	local list = log.control[lane]
	if list == nil then
		list = {}
		log.control[lane] = list
	end
	table.insert(list, value)
end

-- Lane control from the two teams' minion fronts (progress from each team's own base, 0 to 1):
-- positive when team 1 has pushed further.
function Telemetry.laneControl(front1: number, front2: number): number
	local meet = (front1 + (1 - front2)) / 2
	return if meet > 0.53 then 1 elseif meet < 0.47 then -1 else 0
end

-- Samples in a row needed for a side change to count as a reversal.
Telemetry.REVERSAL_HOLD = 3

function Telemetry.summarise(
	log: RoundLog,
	minutes: number,
	winner: number,
	classes: { { class: string, won: boolean } }
): RoundRecord
	local counts: { [string]: number } = {}
	local firstGuardian = 0
	for _, e in log.events do
		counts[e.name] = (counts[e.name] or 0) + 1
		if e.name == "guardian_killed" and firstGuardian == 0 and e.fields.kind == "outerGuardian" then
			local by = e.fields.byTeam
			firstGuardian = if type(by) == "number" then by else 0
		end
	end
	local reversals = 0
	for _, samples in log.control do
		reversals += Balance.reversals(samples, Telemetry.REVERSAL_HOLD)
	end
	local s1, s2 = 0, 0
	for _, s in log.sizes do
		s1 += s[1]
		s2 += s[2]
	end
	local n = math.max(1, #log.sizes)
	local frame = 0
	for _, f in log.frameMs do
		frame += f
	end
	local parts: { string } = {}
	for _, c in classes do
		table.insert(parts, `{c.class}:{if c.won then 1 else 0}`)
	end
	return {
		round = log.round,
		minutes = math.floor(minutes * 10 + 0.5) / 10,
		winner = winner,
		size1 = math.floor(s1 / n * 10 + 0.5) / 10,
		size2 = math.floor(s2 / n * 10 + 0.5) / 10,
		reversals = reversals,
		firstGuardian = firstGuardian,
		kills = counts.player_kill or 0,
		camps = counts.camp_cleared or 0,
		eggs = counts.egg_event or 0,
		bosses = counts.boss_killed or 0,
		classes = table.concat(parts, ","),
		frameMs = if #log.frameMs > 0 then math.floor(frame / #log.frameMs * 100 + 0.5) / 100 else 0,
	}
end

-- Dashboard -----------------------------------------------------------------------------------

export type Dashboard = {
	rounds: number,
	medianMinutes: number,
	p25Minutes: number,
	p75Minutes: number,
	-- Rounds per 5-minute bucket: "0-5" ... "40+".
	lengthBuckets: { { label: string, count: number } },
	-- Share of rounds (with a first guardian) won by the team that took it.
	firstGuardianWinRate: number?,
	reversalsPerRound: number,
	-- Per class: share of player-rounds and win rate.
	classes: { { class: string, pickRate: number, winRate: number } },
}

local function percentile(sorted: { number }, p: number): number
	if #sorted == 0 then
		return 0
	end
	local i = math.clamp(math.ceil(p * #sorted), 1, #sorted)
	return sorted[i]
end

function Telemetry.dashboard(records: { RoundRecord }): Dashboard
	local lengths: { number } = {}
	local firstTotal, firstWins = 0, 0
	local reversals = 0
	local picks: { [string]: { n: number, wins: number } } = {}
	local totalPicks = 0
	for _, r in records do
		table.insert(lengths, r.minutes)
		reversals += r.reversals
		if r.firstGuardian ~= 0 and r.winner ~= 0 then
			firstTotal += 1
			if r.firstGuardian == r.winner then
				firstWins += 1
			end
		end
		for class, won in string.gmatch(r.classes, "(%a+):(%d)") do
			local p = picks[class] or { n = 0, wins = 0 }
			p.n += 1
			p.wins += tonumber(won) or 0
			picks[class] = p
			totalPicks += 1
		end
	end
	table.sort(lengths)
	local buckets: { { label: string, count: number } } = {}
	for i = 0, 8 do
		local from = i * 5
		table.insert(buckets, { label = if i == 8 then "40+" else `{from}-{from + 5}`, count = 0 })
	end
	for _, m in lengths do
		local i = math.min(9, math.floor(m / 5) + 1)
		buckets[i].count += 1
	end
	local classes: { { class: string, pickRate: number, winRate: number } } = {}
	for class, p in picks do
		table.insert(classes, {
			class = class,
			pickRate = if totalPicks > 0 then p.n / totalPicks else 0,
			winRate = if p.n > 0 then p.wins / p.n else 0,
		})
	end
	table.sort(classes, function(a, b): boolean
		return a.class < b.class
	end)
	return {
		rounds = #records,
		medianMinutes = percentile(lengths, 0.5),
		p25Minutes = percentile(lengths, 0.25),
		p75Minutes = percentile(lengths, 0.75),
		lengthBuckets = buckets,
		firstGuardianWinRate = if firstTotal > 0 then firstWins / firstTotal else nil,
		reversalsPerRound = if #records > 0 then reversals / #records else 0,
		classes = classes,
	}
end

-- The dashboard as text lines (dev command, simulator report).
function Telemetry.format(d: Dashboard): { string }
	local lines = {
		`{d.rounds} round(s). Length: median {d.medianMinutes} min (25% {d.p25Minutes}, 75% {d.p75Minutes}).`,
	}
	local bars: { string } = {}
	for _, b in d.lengthBuckets do
		if b.count > 0 then
			table.insert(bars, `{b.label}: {b.count}`)
		end
	end
	table.insert(lines, "Length (min): " .. table.concat(bars, ", "))
	local fg = d.firstGuardianWinRate
	table.insert(
		lines,
		`First guardian win rate: {if fg then string.format("%.0f%%", fg * 100) else "n/a"}. Reversals per round: {string.format(
			"%.1f",
			d.reversalsPerRound
		)}.`
	)
	for _, c in d.classes do
		table.insert(
			lines,
			`{c.class}: picked {string.format("%.0f%%", c.pickRate * 100)}, won {string.format(
				"%.0f%%",
				c.winRate * 100
			)}`
		)
	end
	return lines
end

return Telemetry
