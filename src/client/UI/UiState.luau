--!strict
-- Shared reactive UI state: the root Fusion scope, player settings, and the screen scale.
-- Settings live only for the session until Phase 9 adds them to the player profile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

export type Scope = Fusion.Scope<typeof(Fusion)>
export type EffectsQuality = "Low" | "Medium" | "High"

local scope: Scope = Fusion.scoped(Fusion)

local UiState = {
	scope = scope,
	settings = {
		-- Springs settle instantly and camera shake is off.
		reducedMotion = scope:Value(false) :: Fusion.Value<boolean>,
		effectsQuality = (scope:Value("High") :: any) :: Fusion.Value<EffectsQuality>,
		masterVolume = scope:Value(0.8) :: Fusion.Value<number>,
		sfxVolume = scope:Value(1) :: Fusion.Value<number>,
		musicVolume = scope:Value(0.6) :: Fusion.Value<number>,
		-- Attacks aim where the camera looks (otherwise where the character faces).
		aimWithCamera = scope:Value(true) :: Fusion.Value<boolean>,
	},
	-- Multiplier from points (1600 x 900 reference) to pixels; set by Layout.
	scale = scope:Value(1) :: Fusion.Value<number>,
}

-- Current value of a setting without subscribing.
function UiState.peek<T>(value: Fusion.Value<T>): T
	return Fusion.peek(value)
end

return UiState
