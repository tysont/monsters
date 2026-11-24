--!strict
-- Every monster type by ID. To add a monster type, write its definition file in this folder
-- (see Types.luau for the format) and list it here; no other code changes.

local Types = require("@self/Types")

export type Definition = Types.Definition
export type Attack = Types.Attack

local Monsters: { [string]: Types.Definition } = {
	-- Lane structures (Phase 6).
	outerGuardian = require("@self/OuterGuardian"),
	innerGuardian = require("@self/InnerGuardian"),
	titan = require("@self/Titan"),
	-- Combat gym (Phase 3).
	slammer = require("@self/Slammer"),
	-- Jungle (Phase 7).
	shellback = require("@self/Shellback"),
	splitter = require("@self/Splitter"),
	splitling = require("@self/Splitling"),
	burrower = require("@self/Burrower"),
}

return Monsters
