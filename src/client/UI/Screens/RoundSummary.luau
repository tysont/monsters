--!strict
-- Round summary v1: shown when a round ends. The winner (victory or defeat for you), how long the
-- round lasted, your stats, team totals and the round's MVP. Closes with Backspace, B or the close
-- button, and by itself when the next round starts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Round = require(ReplicatedStorage.Shared.Round)

local Modal = require("../Components/Modal")
local Text = require("../Components/Text")
local Theme = require("../Theme")
local UiState = require("../UiState")

local Children = Fusion.Children

local function teamName(team: number): string
	local t = Config.get().teams[team]
	return if t then t.name else `Team {team}`
end

local EMPTY: Remotes.RoundSummary = {
	round = 0,
	winner = 0,
	duration = 0,
	myTeam = 0,
	kills = 0,
	deaths = 0,
	assists = 0,
	damage = 0,
	structureDamage = 0,
	minions = 0,
	structuresDestroyed = 0,
	teamKills = { 0, 0 },
	teamStructures = { 0, 0 },
	mvp = "",
}

local function stat(scope: UiState.Scope, label: string, value: Fusion.UsedAs<string>, order: number): Frame
	return scope:New("Frame")({
		Name = label,
		LayoutOrder = order,
		Size = UDim2.fromOffset(130, 62),
		BackgroundColor3 = Theme.color.surfaceRaised,
		[Children] = {
			scope:New("UICorner")({ CornerRadius = Theme.radius.sm }),
			Text(scope, {
				text = value,
				position = UDim2.fromOffset(0, 6),
				size = UDim2.new(1, 0, 0, 32),
				textSize = Theme.text.heading,
				font = Theme.font.heavy,
				alignX = Enum.TextXAlignment.Center,
			}),
			Text(scope, {
				text = label,
				position = UDim2.fromOffset(0, 38),
				size = UDim2.new(1, 0, 0, 18),
				textSize = Theme.text.caption,
				color = Theme.color.textMuted,
				alignX = Enum.TextXAlignment.Center,
			}),
		},
	}) :: Frame
end

local function RoundSummary(
	scope: UiState.Scope,
	open: Fusion.Value<boolean>,
	summary: Fusion.Value<Remotes.RoundSummary?>
): Frame
	local function value(get: (Remotes.RoundSummary) -> string): Fusion.Computed<string>
		return scope:Computed(function(use)
			return get(use(summary) or EMPTY)
		end)
	end
	local title = value(function(s: Remotes.RoundSummary): string
		if s.winner == 0 then
			return "Round over"
		end
		local result = if s.myTeam == s.winner then "Victory!" else "Defeat"
		return `{result}  {teamName(s.winner)} wins`
	end)

	local stats: { Fusion.Child } = {
		scope:New("UIGridLayout")({
			CellSize = UDim2.fromOffset(130, 62),
			CellPadding = UDim2.fromOffset(Theme.space.sm, Theme.space.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	local fields: { { label: string, get: (Remotes.RoundSummary) -> string } } = {
		{
			label = "Kills",
			get = function(s)
				return tostring(s.kills)
			end,
		},
		{
			label = "Deaths",
			get = function(s)
				return tostring(s.deaths)
			end,
		},
		{
			label = "Assists",
			get = function(s)
				return tostring(s.assists)
			end,
		},
		{
			label = "Damage",
			get = function(s)
				return tostring(s.damage)
			end,
		},
		{
			label = "Structure damage",
			get = function(s)
				return tostring(s.structureDamage)
			end,
		},
		{
			label = "Minions",
			get = function(s)
				return tostring(s.minions)
			end,
		},
		{
			label = "Structures",
			get = function(s)
				return tostring(s.structuresDestroyed)
			end,
		},
	}
	for i, f in fields do
		table.insert(stats, stat(scope, f.label, value(f.get), i))
	end

	return Modal(scope, {
		name = "RoundSummary",
		title = title,
		open = open,
		size = UDim2.fromOffset(620, 420),
		children = {
			Text(scope, {
				text = value(function(s: Remotes.RoundSummary): string
					return `Round {s.round}  ·  {Round.formatClock(s.duration)}`
				end),
				size = UDim2.new(1, 0, 0, 22),
				textSize = Theme.text.body,
				color = Theme.color.textMuted,
			}),
			scope:New("Frame")({
				Name = "Stats",
				Position = UDim2.fromOffset(0, 32),
				Size = UDim2.new(1, 0, 0, 140),
				BackgroundTransparency = 1,
				[Children] = stats,
			}),
			Text(scope, {
				text = value(function(s: Remotes.RoundSummary): string
					return `{teamName(1)}: {s.teamKills[1] or 0} kills, {s.teamStructures[1] or 0} structures destroyed`
						.. `\n{teamName(2)}: {s.teamKills[2] or 0} kills, {s.teamStructures[2] or 0} structures destroyed`
				end),
				position = UDim2.fromOffset(0, 186),
				size = UDim2.new(1, 0, 0, 44),
				textSize = Theme.text.body,
				wrapped = true,
			}),
			Text(scope, {
				text = value(function(s: Remotes.RoundSummary): string
					return if s.mvp ~= "" then `MVP: {s.mvp}` else ""
				end),
				position = UDim2.fromOffset(0, 238),
				size = UDim2.new(1, 0, 0, 26),
				textSize = Theme.text.title,
				font = Theme.font.bold,
				color = Theme.color.warning,
			}),
		},
	})
end

return RoundSummary
