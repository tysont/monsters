--!strict
-- Responsive layout. UI is designed in points at a 1600 x 900 reference; every screen gets a
-- UIScale from the viewport so it reads the same from 1366 x 768 to 4K and on ultrawide.
-- Screens sit inside the core UI safe area, so nothing overlaps the Roblox top bar.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local UiState = require("./UiState")

local Children = Fusion.Children

local REFERENCE = Vector2.new(1600, 900)
local MIN_SCALE = 0.8
local MAX_SCALE = 2.4

local Layout = {}

function Layout.scaleFor(viewport: Vector2): number
	return math.clamp(math.min(viewport.X / REFERENCE.X, viewport.Y / REFERENCE.Y), MIN_SCALE, MAX_SCALE)
end

local watching = false

-- Keeps UiState.scale in step with the camera viewport.
function Layout.watch()
	if watching then
		return
	end
	watching = true
	local function update()
		local camera = workspace.CurrentCamera
		if camera then
			UiState.scale:set(Layout.scaleFor(camera.ViewportSize))
		end
	end
	update()
	local connection: RBXScriptConnection? = nil
	local function hook()
		if connection then
			connection:Disconnect()
		end
		local camera = workspace.CurrentCamera
		if camera then
			connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
		end
		update()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook)
	hook()
end

-- A ScreenGui whose `Root` frame is in points: it is scaled by UiState.scale and sized so that
-- after scaling it exactly fills the safe area.
function Layout.screen(
	scope: UiState.Scope,
	name: string,
	displayOrder: number,
	parent: Instance,
	children: { Fusion.Child }
): ScreenGui
	local scale = UiState.scale
	return scope:New("ScreenGui")({
		Name = name,
		Parent = parent,
		DisplayOrder = displayOrder,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		[Children] = {
			scope:New("Frame")({
				Name = "Root",
				BackgroundTransparency = 1,
				Size = scope:Computed(function(use)
					local s = use(scale)
					return UDim2.fromScale(1 / s, 1 / s)
				end),
				[Children] = {
					scope:New("UIScale")({ Scale = scale }),
					children :: any,
				},
			}),
		},
	}) :: ScreenGui
end

return Layout
