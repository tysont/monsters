--!strict
-- Team membership for players and bots. Players are assigned when they join (smaller team first,
-- friends together on ties); everyone is reshuffled at the end of each round.
--
-- Bots are team slots for now (they count towards balance); Phase 3 gives them bodies.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Signal)
local TeamAssignment = require(ReplicatedStorage.Shared.TeamAssignment)

-- How long to wait for friend checks before assigning a joiner anyway.
local FRIEND_CHECK_TIMEOUT = 3

type Member = {
	id: string,
	team: number,
	player: Player?,
}

local TeamService = {
	name = "TeamService",
	-- Fires when a player is first given a team (CharacterService spawns them).
	playerAssigned = Signal.new() :: Signal.Signal<Player, number>,
	-- Fires when any member's team changes after assignment (switch or reshuffle).
	teamChanged = Signal.new() :: Signal.Signal<string, number>,
	-- Returns the team that is losing, used to break ties for joiners. Set in Phase 11.
	behindTeam = function(): number?
		return nil
	end,
	-- Combat power of a member (1.0 = new player, about 1.5 = maxed; Appendix A). Phase 9 sets it
	-- from the active class level and active pet. Bots and unknown members count as 1.0.
	powerOf = function(_id: string): number
		return TeamAssignment.DEFAULT_POWER
	end,
}

local members: { [string]: Member } = {}
-- Friend IDs per member ID, as found when each player joined.
local friends: { [string]: { string } } = {}
local teamInstances: { Team } = {}
local nextBotId = 1
local random = Random.new()

local function randomInt(n: number): number
	return random:NextInteger(1, n)
end

local function playerId(player: Player): string
	return `player:{player.UserId}`
end

function TeamService.counts(): { number }
	local c = { 0, 0 }
	for _, member in members do
		c[member.team] += 1
	end
	return c
end

local function powers(): TeamAssignment.Powers
	local p: TeamAssignment.Powers = {}
	for id in members do
		p[id] = TeamService.powerOf(id)
	end
	return p
end

-- Headcount and strength of both teams, for balancing and Phase 11 equalisers.
function TeamService.balance(): TeamAssignment.Balance
	local teamOf: { [string]: number } = {}
	for id, member in members do
		teamOf[id] = member.team
	end
	return TeamAssignment.balance(teamOf, powers())
end

local function publish()
	local c = TeamService.counts()
	local bots = { 0, 0 }
	for _, member in members do
		if member.player == nil then
			bots[member.team] += 1
		end
	end
	for team, instance in teamInstances do
		instance:SetAttribute("Members", c[team])
		instance:SetAttribute("Bots", bots[team])
	end
	-- Flag for the Phase 11 fill logic.
	Teams:SetAttribute("Imbalance", TeamAssignment.imbalance(c))
	local balance = TeamService.balance()
	for team, instance in teamInstances do
		instance:SetAttribute("Strength", balance.strength[team])
	end
	Teams:SetAttribute("StrengthGap", balance.strengthGap)
end

local function apply(member: Member, team: number)
	member.team = team
	local player = member.player
	if player then
		player.Neutral = false
		player.Team = teamInstances[team]
	end
end

function TeamService.teamOf(player: Player): number?
	local member = members[playerId(player)]
	return member and member.team
end

function TeamService.teamInstance(team: number): Team
	return teamInstances[team]
end

function TeamService.isBot(id: string): boolean
	local member = members[id]
	return member ~= nil and member.player == nil
end

local function choose(memberFriends: { string }): number
	local onTeam = { 0, 0 }
	for _, friendId in memberFriends do
		local friend = members[friendId]
		if friend then
			onTeam[friend.team] += 1
		end
	end
	local balance = TeamService.balance()
	return TeamAssignment.chooseTeam(
		balance.counts,
		balance.strength,
		onTeam,
		TeamService.behindTeam(),
		Config.get().teamBalance.strengthTolerance,
		randomInt
	)
end

-- Which players already in the server are friends with `player`. Each check is a web call, so
-- they run in parallel and give up after FRIEND_CHECK_TIMEOUT.
local function findFriends(player: Player): { string }
	local found: { string } = {}
	local pending = 0
	for _, other in Players:GetPlayers() do
		if other ~= player and members[playerId(other)] then
			pending += 1
			task.spawn(function()
				local ok, isFriend = pcall(player.IsFriendsWithAsync, player, other.UserId)
				if ok and isFriend then
					table.insert(found, playerId(other))
				end
				pending -= 1
			end)
		end
	end
	local deadline = os.clock() + FRIEND_CHECK_TIMEOUT
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
	return found
end

local function onPlayerAdded(player: Player)
	local id = playerId(player)
	local memberFriends = findFriends(player)
	if player.Parent == nil then
		return -- left while friend checks ran
	end
	friends[id] = memberFriends
	local member: Member = { id = id, team = 1, player = player }
	members[id] = member
	apply(member, choose(memberFriends))
	publish()
	TeamService.playerAssigned:fire(player, member.team)
end

local function onPlayerRemoving(player: Player)
	local id = playerId(player)
	members[id] = nil
	friends[id] = nil
	publish()
end

-- Moves a member to a team (dev switch). Returns false if the member does not exist.
function TeamService.setTeam(id: string, team: number): boolean
	local member = members[id]
	if member == nil or team < 1 or team > 2 then
		return false
	end
	apply(member, team)
	publish()
	TeamService.teamChanged:fire(id, team)
	return true
end

-- Recomputes and republishes team strength (call when a member's power changes).
function TeamService.refresh()
	publish()
end

function TeamService.idOf(player: Player): string
	return playerId(player)
end

-- Adds a bot to the team the assignment rules pick. Returns its ID.
function TeamService.addBot(): string
	local id = `bot:{nextBotId}`
	nextBotId += 1
	local member: Member = { id = id, team = choose({}), player = nil }
	members[id] = member
	publish()
	return id
end

-- Removes every bot. Returns how many were removed.
function TeamService.clearBots(): number
	local removed = 0
	for id, member in members do
		if member.player == nil then
			members[id] = nil
			removed += 1
		end
	end
	publish()
	return removed
end

-- New balanced teams for everyone, keeping friend groups together where possible.
function TeamService.reshuffle()
	local ids: { string } = {}
	for id in members do
		table.insert(ids, id)
	end
	table.sort(ids)
	local groups = TeamAssignment.friendGroups(ids, friends)
	local result = TeamAssignment.reshuffle(groups, powers(), randomInt)
	for id, team in result do
		local member = members[id]
		local changed = member.team ~= team
		apply(member, team)
		if changed then
			TeamService.teamChanged:fire(id, team)
		end
	end
	publish()
end

function TeamService.init(_self: typeof(TeamService))
	for i, definition in Config.get().teams do
		local team = Instance.new("Team")
		team.Name = definition.name
		-- Cast: the engine types only accept literal BrickColor names.
		team.TeamColor = BrickColor.new(definition.brickColor :: any)
		team.AutoAssignable = false
		team:SetAttribute("TeamIndex", i)
		team.Parent = Teams
		teamInstances[i] = team
	end
	publish()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function TeamService.start(_self: typeof(TeamService))
	-- Players who joined before the service connected (possible in Studio).
	for _, player in Players:GetPlayers() do
		if members[playerId(player)] == nil then
			task.spawn(onPlayerAdded, player)
		end
	end
end

return TeamService
