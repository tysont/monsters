--!strict
-- The map, as numbers. `Shared.Map` turns this into the full resolved map and the server builds
-- the greybox from it at runtime, so changing a number here changes the map.
--
-- Coordinates are studs on the ground plane: x runs from team 1's base (west, negative x) to
-- team 2's base (east), z runs north (negative) to south (positive). Ground level is y = 0.
--
-- Only team 1's half (x <= 0) is authored. Everything is mirrored across x = 0 for team 2, so both
-- teams get identical geometry. Jungle content is authored for the north side and mirrored across
-- z = 0 for the south.
--
-- All horizontal distances are multiplied by `scale`.

local LanePath = require("../Map/LanePath")

type Point = LanePath.Point

export type Rect = {
	center: Point,
	size: Point,
}

export type LaneId = "top" | "middle" | "bottom"

export type MapLayout = {
	-- Multiplies every horizontal distance and size. Heights are not scaled.
	scale: number,
	-- Half the playable area's size; the boundary walls sit just outside it.
	halfWidth: number,
	halfDepth: number,

	laneWidth: number,
	-- Team 1's half of each lane, from its base gate to the centre line. The last point must have
	-- x = 0; the team 2 half is the mirror image.
	lanes: { [LaneId]: { Point } },

	-- Team 1's base platform.
	base: Rect,

	-- Where structures sit along each lane, as progress from the owning team's base (0) towards
	-- the enemy base (1). Hatcheries must sit between the inner and outer guardian.
	innerGuardianProgress: number,
	hatcheryProgress: number,
	outerGuardianProgress: number,
	minionSpawnProgress: number,
	-- Hatcheries sit beside the lane, this far to the side (positive = left of team 1's travel).
	hatcheryLateral: { [LaneId]: number },

	-- North jungle on team 1's side. Mirrored to all four jungle quadrants.
	jungleWalls: { Rect },
	jungleCamps: { Point },

	wallHeight: number,
	boundaryHeight: number,
	boundaryThickness: number,

	-- Expected walking speed (Roblox default WalkSpeed), used to check lane walking times.
	walkSpeed: number,
}

local MapLayout: MapLayout = {
	scale = 1,
	halfWidth = 700,
	halfDepth = 340,

	laneWidth = 28,
	lanes = {
		top = { { x = -550, z = -50 }, { x = -360, z = -280 }, { x = 0, z = -280 } },
		middle = { { x = -550, z = 0 }, { x = 0, z = 0 } },
		bottom = { { x = -550, z = 50 }, { x = -360, z = 280 }, { x = 0, z = 280 } },
	},

	base = { center = { x = -620, z = 0 }, size = { x = 140, z = 220 } },

	innerGuardianProgress = 0.14,
	hatcheryProgress = 0.22,
	outerGuardianProgress = 0.32,
	minionSpawnProgress = 0.01,
	hatcheryLateral = { top = -40, middle = -40, bottom = 40 },

	jungleWalls = {
		{ center = { x = -380, z = -150 }, size = { x = 80, z = 24 } },
		{ center = { x = -200, z = -225 }, size = { x = 90, z = 30 } },
		{ center = { x = -60, z = -160 }, size = { x = 24, z = 100 } },
		{ center = { x = -280, z = -80 }, size = { x = 100, z = 24 } },
	},
	jungleCamps = {
		{ x = -450, z = -100 },
		{ x = -250, z = -160 },
		{ x = -120, z = -80 },
	},

	wallHeight = 16,
	boundaryHeight = 40,
	boundaryThickness = 8,

	walkSpeed = 16,
}

return MapLayout
