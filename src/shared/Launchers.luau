--!strict
-- Launch pads: each base has one pad per lane, just inside the base by that lane's gate. Using a
-- pad flies you in an arc to the furthest guardian your team still holds in that lane (the outer
-- guardian, or the inner one once the outer has fallen), landing a little on your side of it.
-- With both guardians in a lane down, that lane's pad is idle.
--
-- Pure Luau (no engine access), unit tested under Lune. The server places pads and picks
-- destinations from this; the client flies the arc with `height`/`climb`.

local Config = require("./Config")
local LanePath = require("./Map/LanePath")
local Map = require("./Map")
local Structures = require("./Combat/Structures")

export type LauncherConfig = Config.LauncherConfig

export type Pad = {
	-- Attribute-safe identifier, e.g. "L1_top".
	key: string,
	team: number,
	lane: Map.LaneId,
	position: Map.Point,
}

local Launchers = {}

-- Team 1's point mirrored for team 2 (the map is mirrored across x = 0).
local function forTeam(p: Map.Point, team: number): Map.Point
	return if team == 1 then p else { x = -p.x, z = p.z }
end

function Launchers.key(team: number, lane: Map.LaneId): string
	return `L{team}_{lane}`
end

-- Every pad on the map: per team, one per lane.
function Launchers.pads(map: Map.MapData, config: LauncherConfig): { Pad }
	local out: { Pad } = {}
	for team = 1, 2 do
		for _, lane in map.lanes do
			local gate = lane.path.points[1]
			local position = forTeam({ x = gate.x - config.padInset, z = gate.z }, team)
			table.insert(out, { key = Launchers.key(team, lane.id), team = team, lane = lane.id, position = position })
		end
	end
	return out
end

-- The guardian a pad flies to: the outer guardian while it stands, else the inner one, else nil.
function Launchers.destination(team: number, lane: Map.LaneId, dead: { [string]: boolean }): Structures.Kind?
	if not dead[Structures.key("outerGuardian", team, lane)] then
		return "outerGuardian" :: Structures.Kind
	elseif not dead[Structures.key("innerGuardian", team, lane)] then
		return "innerGuardian" :: Structures.Kind
	end
	return nil
end

-- Where a flight to the guardian at `guardian` (a team `team` guardian in `lane`) lands: on the
-- lane, `landingOffset` studs from the guardian towards the team's own base.
function Launchers.landing(
	map: Map.MapData,
	team: number,
	lane: Map.LaneId,
	guardian: Map.Point,
	config: LauncherConfig
): Map.Point
	local path = map.laneById[lane]
	-- Lanes run from team 1's base, so work in team 1's frame and mirror back.
	local along = LanePath.project(path, forTeam(guardian, team))
	return forTeam(LanePath.pointAt(path, math.max(0, along - config.landingOffset)), team)
end

-- Flight time for a flight covering `distance` studs horizontally.
function Launchers.flightSeconds(distance: number, config: LauncherConfig): number
	return math.clamp(distance / config.flightSpeed + config.flightBase, config.minSeconds, config.maxSeconds)
end

-- Arc peak above the straight line between take-off and landing.
function Launchers.apex(distance: number, config: LauncherConfig): number
	return math.clamp(distance * config.apexPerStud, config.minApex, config.maxApex)
end

-- Height at fraction `s` (0..1) of the flight: the straight line from `fromY` to `toY` plus a
-- parabola peaking at `apex` halfway.
function Launchers.height(s: number, fromY: number, toY: number, apex: number): number
	return fromY + (toY - fromY) * s + 4 * apex * s * (1 - s)
end

-- d(height)/ds, for the vertical velocity during the flight.
function Launchers.climb(s: number, fromY: number, toY: number, apex: number): number
	return (toY - fromY) + 4 * apex * (1 - 2 * s)
end

return Launchers
