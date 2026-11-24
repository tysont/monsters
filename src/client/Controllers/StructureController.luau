--!strict
-- Guardian and Titan state on the client, from the attributes MonsterService sets on
-- ReplicatedStorage.Structures: each structure key holds its health fraction (0 = destroyed) and
-- T1_alert / T2_alert say a Titan is under attack. Draws ruins where structures fell and toasts
-- when one is destroyed. The HUD and minimap read `snapshot()`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Map = require(ReplicatedStorage.Shared.Map)
local Round = require(ReplicatedStorage.Shared.Round)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Structures = require(ReplicatedStorage.Shared.Combat.Structures)

local Toast = require("../UI/Components/Toast")

export type Info = {
	structure: Structures.Structure,
	-- 0 to 1; 0 when destroyed.
	health: number,
	dead: boolean,
	-- Cannot be damaged yet (lane gating).
	locked: boolean,
}

export type Snapshot = {
	list: { Info },
	byKey: { [string]: Info },
	alert: { boolean },
}

local StructureController = {
	name = "StructureController",
	-- Fires with the new snapshot whenever any structure value changes.
	changed = Signal.new() :: Signal.Signal<Snapshot>,
}

local structures = Structures.list(Map.get())
local ruins: { [string]: BasePart? } = {}
local current: Snapshot = { list = {}, byKey = {}, alert = { false, false } }
local folder: Instance? = nil
local ruinsFolder: Folder
-- Toasts only for changes after the first read (not for structures already dead on join).
local ready = false

local function teamName(team: number): string
	local t = Config.get().teams[team]
	return if t then t.name else `Team {team}`
end

local function ruin(s: Structures.Structure, show: boolean)
	local existing = ruins[s.key]
	if show and existing == nil then
		local def = Config.get().monsters[s.kind]
		local radius = if def then def.radius else 5
		local p = Instance.new("Part")
		p.Name = s.key
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.Slate
		p.Color = Color3.fromRGB(80, 76, 72)
		p.Size = Vector3.new(radius * 2.2, 1.6, radius * 2)
		p.CFrame = CFrame.new(s.position.x, 0.6, s.position.z) * CFrame.Angles(0, math.rad(17), math.rad(4))
		p.Parent = ruinsFolder
		ruins[s.key] = p
	elseif not show and existing then
		existing:Destroy()
		ruins[s.key] = nil
	end
end

local function refresh()
	local source = folder
	if source == nil then
		return
	end
	local dead: { [string]: boolean } = {}
	local health: { [string]: number } = {}
	for _, s in structures do
		local v = source:GetAttribute(s.key)
		local h = if type(v) == "number" then v else 1
		health[s.key] = h
		dead[s.key] = h <= 0
	end
	local active = ReplicatedStorage:GetAttribute(Round.Attributes.phase) == "Active"
	local list: { Info } = {}
	local byKey: { [string]: Info } = {}
	for _, s in structures do
		local wasDead = current.byKey[s.key] and current.byKey[s.key].dead
		local info: Info = {
			structure = s,
			health = health[s.key],
			dead = dead[s.key],
			locked = not dead[s.key] and (not active or not Structures.vulnerable(s.kind, s.team, s.lane, dead)),
		}
		table.insert(list, info)
		byKey[s.key] = info
		ruin(s, info.dead)
		if ready and info.dead and not wasDead then
			local def = Config.get().monsters[s.kind]
			local what = if def then def.name else s.kind
			local where = if s.lane then ` ({s.lane})` else ""
			Toast.show(`{teamName(s.team)} {what}{where} destroyed!`, if s.kind == "titan" then "danger" else "warning")
		end
	end
	current = {
		list = list,
		byKey = byKey,
		alert = { source:GetAttribute("T1_alert") == true, source:GetAttribute("T2_alert") == true },
	}
	ready = true
	StructureController.changed:fire(current)
end

function StructureController.snapshot(): Snapshot
	return current
end

function StructureController.start(_self: typeof(StructureController))
	local f = Instance.new("Folder")
	f.Name = "Ruins"
	f.Parent = workspace
	ruinsFolder = f
	local source = ReplicatedStorage:WaitForChild("Structures", 30)
	if source == nil then
		warn("[Structures] ReplicatedStorage.Structures never appeared")
		return
	end
	folder = source
	-- Coalesce bursts of attribute changes into one refresh per frame.
	local pending = false
	local function schedule()
		if not pending then
			pending = true
			task.defer(function()
				pending = false
				refresh()
			end)
		end
	end
	source.AttributeChanged:Connect(schedule)
	-- Everything is locked outside the Active phase.
	ReplicatedStorage:GetAttributeChangedSignal(Round.Attributes.phase):Connect(schedule)
	refresh()
end

return StructureController
