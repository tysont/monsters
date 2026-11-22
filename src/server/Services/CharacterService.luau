--!strict
-- Spawning, respawning and movement for player characters.
--
--   Characters do not auto-load; a player spawns once TeamService has given them a team, at their
--   team's SpawnLocation (which grants a ForceField for spawn protection).
--   After death a player waits Round.respawnDelay before respawning. Clients read the
--   `RespawnAt` player attribute (server time) to show the countdown.
--   Movement speed is owned here: frozen (round Ending) means 0, otherwise the walk speed times
--   any dev speed multiplier. Phase 3's stat function will feed in here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(ReplicatedStorage.Shared.Config)
local MapLayout = require(ReplicatedStorage.Shared.Config.MapLayout)
local Round = require(ReplicatedStorage.Shared.Round)

local TeamService = require("./TeamService")

local CharacterService = {
	name = "CharacterService",
	dependencies = { "TeamService" },
	-- Seconds the current round has been Active, for respawn scaling. Set by RoundService.
	activeSeconds = function(): number
		return 0
	end,
}

local frozen = false
local speedMultipliers: { [Player]: number } = {}
-- Incremented on every spawn so a pending respawn from an earlier death does nothing.
local spawnTokens: { [Player]: number } = {}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function CharacterService.applyMovement(player: Player)
	local humanoid = humanoidOf(player)
	if humanoid == nil then
		return
	end
	if frozen then
		humanoid.WalkSpeed = 0
		humanoid.JumpHeight = 0
	else
		humanoid.WalkSpeed = MapLayout.walkSpeed * (speedMultipliers[player] or 1)
		humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
	end
end

-- Freezes or unfreezes every player (round Ending freezes input).
function CharacterService.setFrozen(value: boolean)
	frozen = value
	for _, player in Players:GetPlayers() do
		CharacterService.applyMovement(player)
	end
end

function CharacterService.isFrozen(): boolean
	return frozen
end

-- Dev tool: walk speed multiplier for one player (1 = normal).
function CharacterService.setSpeedMultiplier(player: Player, multiplier: number)
	if multiplier == 1 then
		speedMultipliers[player] = nil
	else
		speedMultipliers[player] = multiplier
	end
	CharacterService.applyMovement(player)
end

local scheduleRespawn: (player: Player, character: Model) -> ()

-- Spawns (or respawns) a player at their team base now, cancelling any pending respawn.
function CharacterService.spawn(player: Player)
	if player.Parent == nil or TeamService.teamOf(player) == nil then
		return
	end
	spawnTokens[player] = (spawnTokens[player] or 0) + 1
	player:SetAttribute("RespawnAt", nil)
	player:LoadCharacterAsync()
	local character = player.Character
	if character then
		CharacterService.applyMovement(player)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Died:Connect(function()
				scheduleRespawn(player, character)
			end)
		end
	end
end

scheduleRespawn = function(player: Player, character: Model)
	local token = spawnTokens[player]
	local delay = Round.respawnDelay(Config.get().respawn, CharacterService.activeSeconds())
	player:SetAttribute("RespawnAt", serverNow() + delay)
	task.delay(delay, function()
		-- Skip if the player left, already respawned, or was respawned by a round reset.
		if player.Parent ~= nil and spawnTokens[player] == token and player.Character == character then
			CharacterService.spawn(player)
		end
	end)
end

-- Respawns every player at their (possibly new) base, e.g. after a reshuffle.
function CharacterService.respawnAll()
	for _, player in Players:GetPlayers() do
		task.spawn(CharacterService.spawn, player)
	end
end

-- Spawns any player who has a team but no character (late joiners, failed loads).
function CharacterService.spawnMissing()
	for _, player in Players:GetPlayers() do
		local humanoid = humanoidOf(player)
		if humanoid == nil and player:GetAttribute("RespawnAt") == nil then
			task.spawn(CharacterService.spawn, player)
		end
	end
end

function CharacterService.init(_self: typeof(CharacterService))
	Players.CharacterAutoLoads = false

	TeamService.playerAssigned:connect(function(player: Player)
		CharacterService.spawn(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		speedMultipliers[player] = nil
		spawnTokens[player] = nil
	end)
end

return CharacterService
