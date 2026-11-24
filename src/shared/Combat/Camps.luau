--!strict
-- Jungle camps: where they are, how hard, which monster, and how health scales with the number
-- of attackers. Pure, unit tested under Lune.
--
--   Tier by distance from the centre line (x = 0): the centre camps are the hardest (tier 3).
--   Monster type: camp k of quadrant q uses types[(k + q - 2) % #types + 1], so each quadrant has
--   one of each type and each type appears at every tier somewhere on the map.

local Config = require("../Config")
local Map = require("../Map")

export type Camp = {
	-- 1-based, in map marker order.
	index: number,
	position: Map.Point,
	tier: number,
	monster: string,
	-- Attribute-safe key, e.g. "C3".
	key: string,
}

local Camps = {}

function Camps.tierFor(x: number, config: Config.CampConfig): number
	local d = math.abs(x)
	if d <= config.tierEdges[2] then
		return 3
	elseif d <= config.tierEdges[1] then
		return 2
	end
	return 1
end

function Camps.list(map: Map.MapData, config: Config.CampConfig): { Camp }
	local markers = Map.markersOf(map, "camp")
	-- Map.build adds camps quadrant by quadrant in authored order.
	local perQuadrant = math.max(1, #markers // 4)
	local out: { Camp } = {}
	for i, marker in markers do
		local quadrant = (i - 1) // perQuadrant + 1
		local k = (i - 1) % perQuadrant + 1
		local types = config.types
		table.insert(out, {
			index = i,
			position = marker.position,
			tier = Camps.tierFor(marker.position.x, config),
			monster = types[(k + quadrant - 2) % #types + 1],
			key = `C{i}`,
		})
	end
	return out
end

-- Health multiplier for `attackers` distinct attackers (never below 1).
function Camps.groupScale(attackers: number, config: Config.CampConfig): number
	return math.clamp(1 + config.groupScalePerAttacker * (attackers - 1), 1, config.maxGroupScale)
end

return Camps
