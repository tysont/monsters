--!strict
-- Placeholder round HUD (replaced by the Phase 4 HUD): round phase and timer, team sizes, the
-- round result, the respawn countdown, and the server shutdown message. Reads only replicated
-- attributes, so it is correct for late joiners.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local Round = require(ReplicatedStorage.Shared.Round)

local REFRESH_SECONDS = 0.1

local RoundHudController = {
	name = "RoundHudController",
}

local function label(parent: Instance, name: string, position: UDim2, size: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.AnchorPoint = Vector2.new(0.5, 0)
	text.Position = position
	text.Size = UDim2.new(0.8, 0, 0, size + 8)
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.4
	text.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	text.TextSize = size
	text.Text = ""
	text.Parent = parent
	return text
end

local function teamByIndex(index: number): Team?
	for _, team in Teams:GetTeams() do
		if team:GetAttribute("TeamIndex") == index then
			return team
		end
	end
	return nil
end

local function teamName(index: number?): string
	local team = if index then teamByIndex(index) else nil
	return if team then team.Name else "?"
end

function RoundHudController.start(_self: typeof(RoundHudController))
	local player = Players.LocalPlayer :: Player
	local gui = Instance.new("ScreenGui")
	gui.Name = "RoundHud"
	gui.ResetOnSpawn = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets

	local status = label(gui, "Status", UDim2.new(0.5, 0, 0, 6), 20)
	local teamsLine = label(gui, "Teams", UDim2.new(0.5, 0, 0, 34), 14)
	local banner = label(gui, "Banner", UDim2.fromScale(0.5, 0.25), 44)
	local respawn = label(gui, "Respawn", UDim2.fromScale(0.5, 0.45), 28)
	local shutdown = label(gui, "Shutdown", UDim2.fromScale(0.5, 0.6), 22)
	shutdown.TextColor3 = Color3.fromRGB(255, 220, 120)
	gui.Parent = player:WaitForChild("PlayerGui")

	local a = Round.Attributes
	while true do
		local now = workspace:GetServerTimeNow()
		local phase = ReplicatedStorage:GetAttribute(a.phase) :: string?
		local round = ReplicatedStorage:GetAttribute(a.round) :: number?
		local endsAt = ReplicatedStorage:GetAttribute(a.phaseEndsAt) :: number?
		local activeSince = ReplicatedStorage:GetAttribute(a.activeSince) :: number?
		local winner = ReplicatedStorage:GetAttribute(a.winner) :: number?

		if phase == nil then
			status.Text = "Waiting for server..."
		elseif phase == "Active" and activeSince then
			status.Text = `Round {round} · {Round.formatClock(now - activeSince)}`
		elseif endsAt then
			status.Text = `Round {round} · {phase} {Round.formatClock(endsAt - now)}`
		else
			status.Text = `Round {round} · {phase}`
		end

		banner.Text = if phase == "Ending"
			then `{teamName(winner)} wins!`
			elseif phase == "Intermission" then "New teams"
			else ""

		local myTeam = player.Team
		local parts = {}
		for index = 1, 2 do
			local team = teamByIndex(index)
			if team then
				local members = team:GetAttribute("Members") or 0
				local bots = team:GetAttribute("Bots") or 0
				local suffix = if bots > 0 then ` ({bots} bots)` else ""
				local marker = if team == myTeam then "> " else ""
				local strength = (team:GetAttribute("Strength") :: number?) or 0
				table.insert(parts, `{marker}{team.Name} {members}{suffix} · str {string.format("%.1f", strength)}`)
			end
		end
		teamsLine.Text = table.concat(parts, "   vs   ")

		local respawnAt = player:GetAttribute("RespawnAt") :: number?
		respawn.Text = if respawnAt and respawnAt > now then `Respawning in {math.ceil(respawnAt - now)}` else ""

		local message = ReplicatedStorage:GetAttribute("ShuttingDown") :: string?
		shutdown.Text = message or ""

		task.wait(REFRESH_SECONDS)
	end
end

return RoundHudController
