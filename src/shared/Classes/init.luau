--!strict
-- Every class by ID. To add a class, write its definition file in this folder (see Types.luau
-- for the format) and list it here.

local Types = require("@self/Types")

export type Class = Types.Class
export type Ability = Types.Ability
export type Effect = Types.Effect
export type Shape = Types.Shape
export type Stats = Types.Stats
export type Milestone = Types.Milestone

local Classes: { [string]: Types.Class } = {
	knight = require("@self/Knight"),
	hunter = require("@self/Hunter"),
	mage = require("@self/Mage"),
	healer = require("@self/Healer"),
}

return Classes
