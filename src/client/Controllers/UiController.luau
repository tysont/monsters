--!strict
-- Mounts the Fusion UI (HUD, settings, dev gallery, toasts) and keeps HudState current from
-- replicated attributes and the combat controller. Values are only set when they change, at
-- 20 Hz (10 Hz for the minimap), so idle frames do no UI work and nothing is created per frame.
--
--   P            settings
--   /gallery     component gallery (dev only)

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Teams = game:GetService("Teams")
local TextChatService = game:GetService("TextChatService")

local Config = require(ReplicatedStorage.Shared.Config)
local Camps = require(ReplicatedStorage.Shared.Combat.Camps)
local DebugAccess = require(ReplicatedStorage.Shared.DebugAccess)
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Map = require(ReplicatedStorage.Shared.Map)
local MonsterBrain = require(ReplicatedStorage.Shared.Combat.MonsterBrain)
local Net = require(ReplicatedStorage.Shared.Net)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)

local CombatController = require("./CombatController")
local EggController = require("./EggController")
local NpcRenderController = require("./NpcRenderController")
local StructureController = require("./StructureController")
local Feedback = require("../Feedback")
local Gallery = require("../UI/Screens/Gallery")
local HatchDialog = require("../UI/Screens/HatchDialog")
local PetsScreen = require("../UI/Screens/PetsScreen")
local Hud = require("../UI/Screens/Hud")
local Layout = require("../UI/Layout")
local Minimap = require("../UI/Screens/Minimap")
local RoundSummary = require("../UI/Screens/RoundSummary")
local SettingsScreen = require("../UI/Screens/SettingsScreen")
local Toast = require("../UI/Components/Toast")
local UiState = require("../UI/UiState")

local REFRESH_HZ = 20
local KILL_FEED_LINES = 5
local KILL_FEED_SECONDS = 6
-- Enemy egg carriers appear on the minimap within this range of any teammate.
local CARRIER_SIGHT = 150

local UiController = {
	name = "UiController",
	dependencies = { "CombatController", "EggController", "NpcRenderController", "StructureController" },
	-- Average milliseconds per frame spent updating HUD state (shown in the debug overlay).
	averageCostMs = 0,
}

local player = Players.LocalPlayer :: Player
local scope = UiState.scope
local nextKillLine = 1

local state: Hud.HudState = {
	health = scope:Value(0),
	maxHealth = scope:Value(100),
	level = scope:Value(1),
	xp = scope:Value(0),
	xpNext = scope:Value(100),
	levelUp = scope:Value(""),
	roundText = scope:Value(""),
	banner = scope:Value(""),
	team1 = scope:Value({ name = "Blue", members = 0, kills = 0, strength = 0 }),
	team2 = scope:Value({ name = "Red", members = 0, kills = 0, strength = 0 }),
	myTeam = scope:Value(0),
	attackCooldown = scope:Value(0),
	dodgeCooldown = scope:Value(0),
	killFeed = scope:Value({} :: { Hud.KillLine }),
	dead = scope:Value(false),
	respawnIn = scope:Value(0),
	killedBy = scope:Value(""),
	dots = scope:Value({} :: { Minimap.Dot }),
	waves = scope:Value({} :: { Minimap.Wave }),
	structures = scope:Value({} :: { Minimap.StructureInfo }),
	camps = scope:Value({} :: { Minimap.CampInfo }),
	alerts = scope:Value({ false, false }),
	boss = scope:Value(nil :: Hud.BossInfo?),
	carrying = scope:Value(""),
}

local settingsOpen = scope:Value(false)
local galleryOpen = scope:Value(false)
local summaryOpen = scope:Value(false)
local summary = scope:Value(nil :: Remotes.RoundSummary?)
local hatchSecondsLeft = scope:Value(0)
local petsOpen = scope:Value(false)
local pets = scope:Value({} :: { PetsScreen.PetInfo })
local petSlots = scope:Value(1)
local levelUpText = state.levelUp

local function teamByIndex(index: number): Team?
	for _, team in Teams:GetTeams() do
		if team:GetAttribute("TeamIndex") == index then
			return team
		end
	end
	return nil
end

local function attribute(instance: Instance, name: string, default: number): number
	local v = instance:GetAttribute(name)
	return if type(v) == "number" then v else default
end

local function updateTeam(value: Fusion.Value<Hud.TeamInfo>, index: number)
	local team = teamByIndex(index)
	if team == nil then
		return
	end
	local current = Fusion.peek(value)
	local nextInfo = {
		name = team.Name,
		members = attribute(team, "Members", 0),
		kills = attribute(team, "Kills", 0),
		strength = attribute(team, "Strength", 0),
	}
	if
		current.name ~= nextInfo.name
		or current.members ~= nextInfo.members
		or current.kills ~= nextInfo.kills
		or current.strength ~= nextInfo.strength
	then
		value:set(nextInfo)
	end
end

local function updateRound(now: number)
	local a = Round.Attributes
	local phase = ReplicatedStorage:GetAttribute(a.phase) :: string?
	local round = ReplicatedStorage:GetAttribute(a.round) :: number?
	local endsAt = ReplicatedStorage:GetAttribute(a.phaseEndsAt) :: number?
	local activeSince = ReplicatedStorage:GetAttribute(a.activeSince) :: number?
	local winner = ReplicatedStorage:GetAttribute(a.winner) :: number?

	local text
	if phase == nil then
		text = "Waiting..."
	elseif phase == "Active" and activeSince then
		text = `Round {round}  ·  {Round.formatClock(now - activeSince)}`
	elseif endsAt then
		text = `{phase}  {Round.formatClock(endsAt - now)}`
	else
		text = `Round {round}`
	end
	state.roundText:set(text)

	local banner = ""
	if phase == "Ending" then
		local team = if winner then teamByIndex(winner) else nil
		banner = `{if team then team.Name else "?"} wins!`
	elseif phase == "Intermission" then
		banner = "New teams"
	end
	local shutdown = ReplicatedStorage:GetAttribute("ShuttingDown")
	if type(shutdown) == "string" then
		banner = shutdown
	end
	state.banner:set(banner)
end

local function updatePlayer(now: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local alive = humanoid ~= nil and humanoid.Health > 0
	if humanoid then
		state.health:set(math.max(0, humanoid.Health))
		state.maxHealth:set(humanoid.MaxHealth)
	end
	state.dead:set(not alive)
	if alive then
		state.killedBy:set("")
	end
	local respawnAt = player:GetAttribute("RespawnAt")
	state.respawnIn:set(if type(respawnAt) == "number" then respawnAt - now else 0)
	state.level:set(attribute(player, "ClassLevel", 1))
	state.xp:set(attribute(player, "ClassXp", 0))
	state.xpNext:set(attribute(player, "ClassXpNext", 100))
	petSlots:set(attribute(player, "PetSlots", 1))
	local carrying = player:GetAttribute("CarryingEgg")
	state.carrying:set(if type(carrying) == "string" then carrying else "")
	local pending = Fusion.peek(EggController.pendingHatch)
	hatchSecondsLeft:set(if pending then math.max(0, math.ceil(pending.expiresAt - now)) else 0)
	local team = player.Team
	state.myTeam:set(if team then attribute(team, "TeamIndex", 0) else 0)
	state.attackCooldown:set(CombatController.cooldown("attack"))
	state.dodgeCooldown:set(CombatController.cooldown("dodge"))
end

local function updateDots()
	local dots: { Minimap.Dot } = {}
	local myTeam = player.Team
	local friendly: { Vector3 } = {}
	local enemyCarriers: { { id: number, position: Vector3 } } = {}
	for _, other in Players:GetPlayers() do
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local carrying = other:GetAttribute("CarryingEgg") ~= nil
			if other.Team == myTeam then
				table.insert(friendly, root.Position)
				table.insert(dots, {
					id = other.UserId,
					x = root.Position.X,
					z = root.Position.Z,
					me = other == player,
					carrier = carrying,
				})
			elseif carrying then
				table.insert(enemyCarriers, { id = other.UserId, position = root.Position })
			end
		end
	end
	-- Enemy egg carriers show while someone on your team is near enough to see them.
	for _, enemy in enemyCarriers do
		for _, p in friendly do
			if (p - enemy.position).Magnitude <= CARRIER_SIGHT then
				table.insert(dots, {
					id = enemy.id,
					x = enemy.position.X,
					z = enemy.position.Z,
					me = false,
					carrier = true,
					enemy = true,
				})
				break
			end
		end
	end
	-- Only push a new list when a dot moved visibly or the set changed; otherwise the minimap
	-- does no work this tick.
	local previous = Fusion.peek(state.dots)
	local changed = #previous ~= #dots
	if not changed then
		for i, dot in dots do
			local old = previous[i]
			if
				old.id ~= dot.id
				or old.carrier ~= dot.carrier
				or math.abs(old.x - dot.x) > 0.5
				or math.abs(old.z - dot.z) > 0.5
			then
				changed = true
				break
			end
		end
	end
	if changed then
		state.dots:set(dots)
	end
end

local function onStructures(snapshot: StructureController.Snapshot)
	local list: { Minimap.StructureInfo } = {}
	for _, info in snapshot.list do
		local s = info.structure
		table.insert(list, {
			key = s.key,
			kind = s.kind :: string,
			team = s.team,
			lane = s.lane :: string?,
			x = s.position.x,
			z = s.position.z,
			health = info.health,
			dead = info.dead,
			locked = info.locked,
		})
	end
	state.structures:set(list)
	state.alerts:set(snapshot.alert)
end

local campList = Camps.list(Map.get(), Config.get().camps)

-- Camp states from ReplicatedStorage.Camps (0 = alive, else respawn time); pushed only when a
-- camp changes or its countdown ticks over a second.
local function updateCamps(now: number)
	local source = ReplicatedStorage:FindFirstChild("Camps")
	if source == nil then
		return
	end
	local list: { Minimap.CampInfo } = {}
	local previous = Fusion.peek(state.camps)
	local changed = #previous ~= #campList
	for i, camp in campList do
		local v = source:GetAttribute(camp.key)
		local respawnAt = if type(v) == "number" then v else 0
		local info: Minimap.CampInfo = {
			x = camp.position.x,
			z = camp.position.z,
			tier = camp.tier,
			alive = respawnAt <= 0,
			respawnIn = if respawnAt > 0 then math.ceil(respawnAt - now) else 0,
		}
		local old = previous[i]
		if old == nil or old.alive ~= info.alive or old.respawnIn ~= info.respawnIn then
			changed = true
		end
		table.insert(list, info)
	end
	if changed then
		state.camps:set(list)
	end
end

-- Large monsters (guardians, Titans, gym monsters) get the boss bar within this range.
local BOSS_RANGE = 60

local function updateBoss()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local monster = if root and root:IsA("BasePart")
		then NpcRenderController.monsterNear(root.Position, BOSS_RANGE)
		else nil
	if monster == nil then
		if Fusion.peek(state.boss) ~= nil then
			state.boss:set(nil)
		end
		return
	end
	local def = monster.definition
	local teamDef = monster.team and Config.get().teams[monster.team]
	local key: StructureController.Info? = nil
	for _, info in StructureController.snapshot().list do
		local s = info.structure
		local dx, dz = s.position.x - monster.position.X, s.position.z - monster.position.Z
		if s.kind == monster.kind and dx * dx + dz * dz < 4 then
			key = info
		end
	end
	local nextBoss: Hud.BossInfo = {
		name = if teamDef then `{teamDef.name} {def.name}` else def.name,
		-- Round to whole percent so small changes do not rebuild the bar.
		health = math.floor(monster.health * 100 + 0.5) / 100,
		stagger = math.floor(monster.stagger * 50 + 0.5) / 50,
		staggered = monster.staggered,
		phase = MonsterBrain.phaseFor(def, monster.health),
		phases = #def.phases + 1,
		locked = key ~= nil and (key :: StructureController.Info).locked,
		hostile = monster.team ~= Fusion.peek(state.myTeam),
	}
	local current = Fusion.peek(state.boss)
	if
		current == nil
		or current.name ~= nextBoss.name
		or current.health ~= nextBoss.health
		or current.stagger ~= nextBoss.stagger
		or current.staggered ~= nextBoss.staggered
		or current.phase ~= nextBoss.phase
		or current.locked ~= nextBoss.locked
		or current.hostile ~= nextBoss.hostile
	then
		state.boss:set(nextBoss)
	end
end

local function onKill(event: Remotes.KillEvent)
	local me = player.UserId
	local text = `{CombatController.nameOf(event.killer)}  ⚔  {CombatController.nameOf(event.victim)}`
	if #event.assists > 0 then
		text ..= `  (+{#event.assists})`
	end
	local mine = event.killer == me or event.victim == me or table.find(event.assists, me) ~= nil
	local line: Hud.KillLine = { id = nextKillLine, text = text, mine = mine }
	nextKillLine += 1
	local lines = table.clone(Fusion.peek(state.killFeed))
	table.insert(lines, line)
	while #lines > KILL_FEED_LINES do
		table.remove(lines, 1)
	end
	state.killFeed:set(lines)
	task.delay(KILL_FEED_SECONDS, function()
		local current = table.clone(Fusion.peek(state.killFeed))
		local index = table.find(current, line)
		if index then
			table.remove(current, index)
			state.killFeed:set(current)
		end
	end)

	if event.victim == me then
		state.killedBy:set(CombatController.nameOf(event.killer))
	elseif event.killer == me then
		Toast.show(`You defeated {CombatController.nameOf(event.victim)}`, "success")
	end
end

function UiController.start(_self: typeof(UiController))
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
	Layout.watch()

	local playerGui = player:WaitForChild("PlayerGui")
	Layout.screen(
		scope,
		"Hud",
		10,
		playerGui,
		Hud(scope, state, {
			attack = CombatController.attack,
			dodge = CombatController.dodge,
			openPets = function()
				petsOpen:set(true)
			end,
			openSettings = function()
				settingsOpen:set(true)
			end,
		})
	)
	local overlay = Layout.screen(scope, "Menus", 50, playerGui, {
		SettingsScreen(scope, settingsOpen),
		RoundSummary(scope, summaryOpen, summary),
		PetsScreen(scope, {
			open = petsOpen,
			pets = pets,
			slots = petSlots,
			setActive = function(id: number)
				Net.fireServer(Remotes.SetActivePet, id)
			end,
		}),
		HatchDialog(scope, {
			open = EggController.hatchOpen,
			pending = EggController.pendingHatch,
			secondsLeft = hatchSecondsLeft,
			pets = pets,
			slots = petSlots,
			choose = EggController.choose,
		}),
	})
	Net.onClientEvent(Remotes.RoundSummary, function(s: Remotes.RoundSummary)
		summary:set(s)
		summaryOpen:set(true)
	end)
	StructureController.changed:connect(onStructures)
	onStructures(StructureController.snapshot())
	Toast.mount(scope, overlay:FindFirstChild("Root") :: Instance)
	if DebugAccess.canView(player) then
		Layout.screen(scope, "Gallery", 60, playerGui, { Gallery(scope, galleryOpen) })
		task.spawn(function()
			local command = TextChatService:WaitForChild("Devgallery", 15)
			if command and command:IsA("TextChatCommand") then
				command.Triggered:Connect(function()
					galleryOpen:set(not Fusion.peek(galleryOpen))
				end)
			end
		end)
	end

	-- Pets: the stable list arrives as JSON in the "Pets" attribute.
	local function readPets()
		local raw = player:GetAttribute("Pets")
		if type(raw) ~= "string" then
			return
		end
		local ok, list = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(list) == "table" then
			pets:set(list :: any)
		end
	end
	player:GetAttributeChangedSignal("Pets"):Connect(readPets)
	readPets()
	ContextActionService:BindAction("OpenPets", function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			petsOpen:set(not Fusion.peek(petsOpen))
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.K)

	-- Level-up moment: a banner, a toast and a flash of the character.
	Net.onClientEvent(Remotes.LevelUp, function(event: Remotes.LevelUpEvent)
		Toast.show(
			`Level up! {string.upper(string.sub(event.class, 1, 1))}{string.sub(event.class, 2)} level {event.level}`,
			"success"
		)
		levelUpText:set(`LEVEL {event.level}`)
		Feedback.flash(player.Character)
		Feedback.playSound(Config.get().combat.sounds.hit, nil, 0.8)
		task.delay(2.5, function()
			if Fusion.peek(levelUpText) == `LEVEL {event.level}` then
				levelUpText:set("")
			end
		end)
	end)

	ContextActionService:BindAction("OpenSettings", function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			settingsOpen:set(not Fusion.peek(settingsOpen))
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.P)

	CombatController.killed:connect(onKill)
	Net.onClientEvent(Remotes.WaveSummary, function(infos: { Remotes.WaveInfo })
		state.waves:set(infos)
	end)

	-- Refresh loop with cost measurement.
	local frames = 0
	local window = 0
	local cost = 0
	RunService.RenderStepped:Connect(function(dt: number)
		frames += 1
		window += dt
		if window >= 1 then
			UiController.averageCostMs = cost / frames * 1000
			frames, window, cost = 0, 0, 0
		end
	end)
	local tick = 0
	while true do
		local started = os.clock()
		local now = workspace:GetServerTimeNow()
		updateRound(now)
		updatePlayer(now)
		updateTeam(state.team1, 1)
		updateTeam(state.team2, 2)
		tick += 1
		if tick % 2 == 0 then
			updateDots()
		end
		updateBoss()
		if tick % 10 == 0 then
			updateCamps(now)
		end
		-- The summary closes by itself when the next round starts.
		if Fusion.peek(summaryOpen) and ReplicatedStorage:GetAttribute(Round.Attributes.phase) == "Starting" then
			summaryOpen:set(false)
		end
		cost += os.clock() - started
		task.wait(1 / REFRESH_HZ)
	end
end

return UiController
