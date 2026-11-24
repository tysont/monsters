--!strict
-- Springs that respect the reduced-motion setting: with reduced motion on they settle at once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UiState = require("./UiState")

local INSTANT = 10000

local Motion = {}

-- A spring towards `goal`. `speed` and `damping` are Fusion spring parameters.
function Motion.spring<T>(scope: UiState.Scope, goal: Fusion.UsedAs<T>, speed: number, damping: number?): Fusion.Spring<T>
	local reduced = UiState.settings.reducedMotion
	local effectiveSpeed = scope:Computed(function(use)
		return if use(reduced) then INSTANT else speed
	end)
	return scope:Spring(goal, effectiveSpeed, damping or 1)
end

return Motion
