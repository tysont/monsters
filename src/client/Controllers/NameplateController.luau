--!strict
-- World-space name plates over other players: name in team colour, level and a health bar.
-- One plate per player, created once and moved onto each new character (pooled); Roblox's
-- default name and health display is turned off for those characters.

local Players = game:GetService("Players")

local Theme = require("../UI/Theme")

local NameplateController = {
	name = "NameplateController",
}

type Plate = {
	gui: BillboardGui,
	name: TextLabel,
	fill: Frame,
	connections: { RBXScriptConnection },
}

local plates: { [Player]: Plate } = {}

local function teamColor(player: Player): Color3
	local team = player.Team
	return if team then team.TeamColor.Color else Theme.color.text
end

local function makePlate(): Plate
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nameplate"
	gui.Size = UDim2.fromOffset(160, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Size = UDim2.new(1, 0, 0, 20)
	name.BackgroundTransparency = 1
	name.FontFace = Theme.font.bold
	name.TextSize = 15
	name.TextStrokeTransparency = 0.4
	name.Parent = gui

	local bar = Instance.new("Frame")
	bar.Name = "Health"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 24)
	bar.Size = UDim2.fromOffset(90, 7)
	bar.BackgroundColor3 = Theme.color.background
	bar.BorderSizePixel = 0
	bar.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.radius.pill
	corner.Parent = bar
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Theme.color.health
	fill.BorderSizePixel = 0
	fill.Parent = bar
	local fillCorner = corner:Clone()
	fillCorner.Parent = fill

	return { gui = gui, name = name, fill = fill, connections = {} }
end

local function attach(player: Player, character: Model)
	local plate = plates[player]
	if plate == nil then
		plate = makePlate()
		plates[player] = plate
	end
	for _, c in plate.connections do
		c:Disconnect()
	end
	table.clear(plate.connections)

	local humanoid = character:WaitForChild("Humanoid", 10)
	local head = character:WaitForChild("Head", 10)
	if humanoid == nil or head == nil or not humanoid:IsA("Humanoid") or not head:IsA("BasePart") then
		return
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local function refresh()
		local level = player:GetAttribute("ClassLevel")
		local account = player:GetAttribute("AccountLevel")
		local title = player:GetAttribute("Title")
		-- Class level, then account level (and title once earned).
		plate.name.Text = `{player.DisplayName}  ·  Lv {if type(level) == "number" then level else 1}`
			.. `  ·  Acct {if type(account) == "number" then account else 1}`
			.. (if type(title) == "string" then `  ·  {title}` else "")
		local bounty = player:GetAttribute("Bounty")
		if type(bounty) == "number" then
			plate.name.Text ..= `  ·  BOUNTY {bounty}`
		end
		if player:GetAttribute("Idle") then
			plate.name.Text ..= "  ·  idle"
		end
		plate.name.TextColor3 = teamColor(player)
		local fraction = if humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
		plate.fill.Size = UDim2.fromScale(fraction, 1)
		plate.fill.BackgroundColor3 = if fraction < 0.3 then Theme.color.healthLow else Theme.color.health
	end
	table.insert(plate.connections, humanoid.HealthChanged:Connect(refresh))
	table.insert(plate.connections, player:GetPropertyChangedSignal("Team"):Connect(refresh))
	table.insert(plate.connections, player:GetAttributeChangedSignal("ClassLevel"):Connect(refresh))
	table.insert(plate.connections, player:GetAttributeChangedSignal("AccountLevel"):Connect(refresh))
	table.insert(plate.connections, player:GetAttributeChangedSignal("Title"):Connect(refresh))
	table.insert(plate.connections, player:GetAttributeChangedSignal("Bounty"):Connect(refresh))
	table.insert(plate.connections, player:GetAttributeChangedSignal("Idle"):Connect(refresh))
	refresh()

	-- Parented to our PlayerGui (not the character) so the plate survives respawns.
	plate.gui.Adornee = head
	plate.gui.Parent = (Players.LocalPlayer :: Player):FindFirstChildOfClass("PlayerGui")
end

local function track(player: Player)
	if player == Players.LocalPlayer then
		return
	end
	player.CharacterAdded:Connect(function(character)
		attach(player, character)
	end)
	if player.Character then
		task.spawn(attach, player, player.Character)
	end
end

function NameplateController.start(_self: typeof(NameplateController))
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local plate = plates[player]
		if plate then
			for _, c in plate.connections do
				c:Disconnect()
			end
			plate.gui:Destroy()
			plates[player] = nil
		end
	end)
end

return NameplateController
