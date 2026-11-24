--!strict
-- Eggs and hatcheries on the client:
--   * world labels on every egg (kind and rarity, hatch countdown, "Hatched!") and over every
--     hatchery (free slots, raidable),
--   * prompt filtering: the deposit prompt shows only for your own team's hatcheries while you
--     carry an egg; the steal prompt only at raidable enemy hatcheries with eggs in them (the
--     server checks everything again),
--   * the hatch choice dialog, raid alerts, and the carry state for the HUD.
-- Labels are created once per egg or hatchery and only their text changes (4 Hz).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)

local Theme = require("../UI/Theme")
local Toast = require("../UI/Components/Toast")
local UiState = require("../UI/UiState")

local REFRESH_SECONDS = 0.25

local EggController = {
	name = "EggController",
	-- The hatch the player must decide on, or nil. UiController shows the dialog from this.
	pendingHatch = UiState.scope:Value(nil :: Remotes.HatchReadyEvent?),
	hatchOpen = UiState.scope:Value(false),
	-- Fires when the local player's carried egg changes (text or nil).
	carryChanged = Signal.new() :: Signal.Signal<string?>,
}

local player = Players.LocalPlayer :: Player
local labels: { [BasePart]: TextLabel? } = {}
local hatcheryLabels: { [Model]: TextLabel? } = {}

local function myTeam(): number?
	local team = player.Team
	local index = team and team:GetAttribute("TeamIndex")
	return if type(index) == "number" then index else nil
end

local function billboard(adornee: BasePart, offset: number, width: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(width, 22)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offset, 0)
	gui.MaxDistance = 140
	gui.AlwaysOnTop = true
	gui.Adornee = adornee
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextColor3 = Theme.color.text
	text.TextStrokeTransparency = 0.3
	text.FontFace = Theme.font.bold
	text.TextScaled = true
	text.Parent = gui
	gui.Parent = adornee
	return text
end

local function onEgg(instance: Instance)
	if instance:IsA("BasePart") and labels[instance] == nil then
		labels[instance] = billboard(instance, 2.6, 150)
		instance.Destroying:Connect(function()
			labels[instance] = nil
		end)
	end
end

local function eggText(part: BasePart, now: number): string
	local kind = part:GetAttribute("Kind") :: string? or "?"
	local rarity = part:GetAttribute("Rarity") :: string? or ""
	local state = part:GetAttribute("State")
	if state == "incubating" then
		local endsAt = part:GetAttribute("EndsAt")
		return `{kind}  {Round.formatClock(if type(endsAt) == "number" then endsAt - now else 0)}`
	elseif state == "hatched" then
		return "Hatched!"
	elseif state == "carried" then
		return `{rarity} {kind}`
	end
	return `{rarity} {kind} egg`
end

-- Incubating eggs per hatchery key.
local function incubatingCounts(): { [string]: number }
	local counts: { [string]: number } = {}
	for _, part in CollectionService:GetTagged("Egg") do
		local key = part:GetAttribute("Hatchery")
		if type(key) == "string" and part:GetAttribute("State") == "incubating" then
			counts[key] = (counts[key] or 0) + 1
		end
	end
	return counts
end

local function refresh()
	local now = workspace:GetServerTimeNow()
	for part, label in labels do
		local text = eggText(part, now)
		if label and label.Text ~= text then
			label.Text = text
		end
	end
	local team = myTeam()
	local carrying = player:GetAttribute("CarryingEgg") ~= nil
	local counts = incubatingCounts()
	local folder = workspace:FindFirstChild("Hatcheries")
	if folder == nil then
		return
	end
	for _, model in folder:GetChildren() do
		if model:IsA("Model") then
			local hatcheryTeam = model:GetAttribute("Team")
			local own = hatcheryTeam == team
			local raidable = model:GetAttribute("Raidable") == true
			local free = (model:GetAttribute("Free") :: number?) or 0
			local core = model:FindFirstChild("Core")
			if core and core:IsA("BasePart") then
				local deposit = core:FindFirstChild("Deposit")
				if deposit and deposit:IsA("ProximityPrompt") then
					deposit.Enabled = own and carrying and free > 0
				end
				local raid = core:FindFirstChild("Raid")
				if raid and raid:IsA("ProximityPrompt") then
					raid.Enabled = not own and raidable and not carrying and (counts[model.Name] or 0) > 0
				end
				local label = hatcheryLabels[model]
				if label == nil then
					label = billboard(core, 5, 180)
					hatcheryLabels[model] = label
				end
				local text = `Hatchery  {free}/{Config.get().eggs.slots} free`
				if not own then
					text = if raidable then `Enemy hatchery: raidable` else "Enemy hatchery: guarded"
				end
				local shown = label :: TextLabel
				if shown.Text ~= text then
					shown.Text = text
				end
			end
		end
	end
end

function EggController.choose(choice: string, target: number?)
	local pending = Fusion.peek(EggController.pendingHatch)
	if pending then
		Net.fireServer(Remotes.HatchChoice, { egg = pending.egg, choice = choice, target = target })
		EggController.pendingHatch:set(nil)
		EggController.hatchOpen:set(false)
	end
end

function EggController.start(_self: typeof(EggController))
	CollectionService:GetInstanceAddedSignal("Egg"):Connect(onEgg)
	for _, instance in CollectionService:GetTagged("Egg") do
		onEgg(instance)
	end

	Net.onClientEvent(Remotes.HatchReady, function(event: Remotes.HatchReadyEvent)
		EggController.pendingHatch:set(event)
		EggController.hatchOpen:set(true)
	end)
	Net.onClientEvent(Remotes.RaidAlert, function(event: Remotes.RaidAlertEvent)
		Toast.show(`Raid! {event.raider} is stealing from your {event.lane} hatchery`, "danger")
	end)
	player:GetAttributeChangedSignal("CarryingEgg"):Connect(function()
		local value = player:GetAttribute("CarryingEgg")
		EggController.carryChanged:fire(if type(value) == "string" then value else nil)
		if type(value) == "string" then
			Toast.show(`Carrying a {value} egg: take it to one of your hatcheries`, "info")
		end
	end)

	while true do
		task.wait(REFRESH_SECONDS)
		refresh()
		-- A hatch nobody answered expires on the server; drop the dialog then.
		local pending = Fusion.peek(EggController.pendingHatch)
		if pending and workspace:GetServerTimeNow() > pending.expiresAt then
			EggController.pendingHatch:set(nil)
			EggController.hatchOpen:set(false)
		end
	end
end

return EggController
