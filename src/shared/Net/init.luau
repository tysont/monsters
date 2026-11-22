--!strict
-- Typed remotes. Every remote in the game is defined once in `Shared.Remotes` and used through
-- this module, never through RemoteEvent instances directly.
--
--   Client to server: each payload is rate limited per player, then validated with the remote's
--   Check before the handler runs. Bad or excess calls are dropped and reported as violations.
--   Server to client: payloads are trusted; in dev they are also validated on the client.
--
-- Every remote carries exactly one payload value (use a table for several fields, nil for none).
-- Unreliable remotes may drop or reorder messages. The engine drops unreliable payloads over
-- 1000 bytes; keep each one under 900 bytes for headroom (chunk larger data across messages).

local Config = require("./Config")
local Guard = require("@self/Guard")
local RateLimiter = require("@self/RateLimiter")

export type Check<T> = Guard.Check<T>

export type ClientToServer<T> = {
	kind: "ClientToServer",
	name: string,
	reliable: boolean,
	check: Check<T>,
	rateLimit: Config.RateLimit?,
}

export type ServerToClient<T> = {
	kind: "ServerToClient",
	name: string,
	reliable: boolean,
	check: Check<T>,
}

type AnyRemote = ClientToServer<any> | ServerToClient<any>

-- Called for every rejected client call. Replaced by the anti-cheat system in Phase 14.
export type ViolationHandler = (player: Player, remoteName: string, reason: string) -> ()

local FOLDER_NAME = "Remotes"
local WAIT_WARNING_SECONDS = 10

local Net = {}

-- Definitions -------------------------------------------------------------------------------

function Net.clientToServer<T>(options: {
	check: Check<T>,
	reliable: boolean?,
	rateLimit: Config.RateLimit?,
}): ClientToServer<T>
	return {
		kind = "ClientToServer",
		name = "",
		reliable = options.reliable ~= false,
		check = options.check,
		rateLimit = options.rateLimit,
	}
end

function Net.serverToClient<T>(options: { check: Check<T>, reliable: boolean? }): ServerToClient<T>
	return {
		kind = "ServerToClient",
		name = "",
		reliable = options.reliable ~= false,
		check = options.check,
	}
end

-- Names each remote after its key and freezes the table. Use once, in Shared.Remotes.
function Net.define<T>(remotes: T): T
	for name, remote in remotes :: any do
		assert(type(name) == "string", "remote keys must be strings")
		assert(remote.name == "", `remote {name} is already defined elsewhere`)
		remote.name = name
		table.freeze(remote)
	end
	table.freeze(remotes :: any)
	return remotes
end

-- Instances ---------------------------------------------------------------------------------

-- RemoteEvent and UnreliableRemoteEvent share the same API, but the engine type definitions only
-- declare it on each concrete class, so both are typed as RemoteEvent here.
type Remote = RemoteEvent

local instances: { [string]: Remote } = {}

local function isServer(): boolean
	return game:GetService("RunService"):IsServer()
end

-- Creates the RemoteEvent instances for every definition. The server calls this once at
-- start-up, before any service runs.
function Net.createRemotes(remotes: { [string]: AnyRemote })
	assert(isServer(), "Net.createRemotes is server-only")
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for name, remote in remotes do
		local instance: Remote = if remote.reliable
			then Instance.new("RemoteEvent")
			else (Instance.new("UnreliableRemoteEvent") :: any) :: Remote
		instance.Name = name
		instance.Parent = folder
		instances[name] = instance
	end
	folder.Parent = game:GetService("ReplicatedStorage")
end

-- Returns the instance for a remote. On the client this may yield until it replicates.
local function getInstance(remote: AnyRemote): Remote
	local cached = instances[remote.name]
	if cached then
		return cached
	end
	assert(not isServer(), `remote {remote.name} was not created; is it in Shared.Remotes?`)

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_WARNING_SECONDS)
		or ReplicatedStorage:WaitForChild(FOLDER_NAME)
	local instance = folder:WaitForChild(remote.name, WAIT_WARNING_SECONDS)
	if instance == nil then
		warn(`[Net] still waiting for remote {remote.name}`)
		instance = folder:WaitForChild(remote.name)
	end
	local event = (instance :: any) :: Remote
	instances[remote.name] = event
	return event
end

-- Violations --------------------------------------------------------------------------------

local logLimiter = RateLimiter.new(0.2, 3) :: RateLimiter.RateLimiter<Player>

local function defaultViolationHandler(player: Player, remoteName: string, reason: string)
	if Config.get().net.logViolations and logLimiter:allow(player) then
		warn(`[Net] dropped {remoteName} from {player.Name} ({player.UserId}): {reason}`)
	end
end

local violationHandler: ViolationHandler = defaultViolationHandler

function Net.setViolationHandler(handler: ViolationHandler)
	violationHandler = handler
end

-- Server API --------------------------------------------------------------------------------

local limiters: { RateLimiter.RateLimiter<Player> } = {}
local playerRemovingConnected = false

local function trackLimiter(limiter: RateLimiter.RateLimiter<Player>)
	table.insert(limiters, limiter)
	if not playerRemovingConnected then
		playerRemovingConnected = true
		game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
			for _, l in limiters do
				l:forget(player)
			end
			logLimiter:forget(player)
		end)
	end
end

local handled: { [string]: true } = {}

-- Handles calls from clients. Each remote has exactly one server handler.
function Net.onServerEvent<T>(remote: ClientToServer<T>, handler: (player: Player, payload: T) -> ())
	assert(isServer(), "Net.onServerEvent is server-only")
	assert(not handled[remote.name], `remote {remote.name} already has a server handler`)
	handled[remote.name] = true

	local limit = remote.rateLimit or Config.get().net.defaultRateLimit
	local limiter = RateLimiter.new(limit.rate, limit.burst) :: RateLimiter.RateLimiter<Player>
	trackLimiter(limiter)

	getInstance(remote).OnServerEvent:Connect(function(player: Player, ...: unknown)
		if not limiter:allow(player) then
			violationHandler(player, remote.name, "rate limit exceeded")
			return
		end
		if select("#", ...) > 1 then
			violationHandler(player, remote.name, "more than one argument")
			return
		end
		local payload, reason = remote.check((...))
		if reason ~= nil then
			violationHandler(player, remote.name, reason)
			return
		end
		handler(player, payload :: T)
	end)
end

function Net.fireClient<T>(remote: ServerToClient<T>, player: Player, payload: T)
	getInstance(remote):FireClient(player, payload)
end

function Net.fireClients<T>(remote: ServerToClient<T>, players: { Player }, payload: T)
	local instance = getInstance(remote)
	for _, player in players do
		instance:FireClient(player, payload)
	end
end

function Net.fireAllClients<T>(remote: ServerToClient<T>, payload: T)
	getInstance(remote):FireAllClients(payload)
end

-- Client API --------------------------------------------------------------------------------

-- May yield until the remote replicates, so call from a controller's start(), not init().
function Net.fireServer<T>(remote: ClientToServer<T>, payload: T)
	getInstance(remote):FireServer(payload)
end

-- May yield until the remote replicates, so call from a controller's start(), not init().
function Net.onClientEvent<T>(remote: ServerToClient<T>, handler: (payload: T) -> ())
	assert(not isServer(), "Net.onClientEvent is client-only")
	local validate = Config.get().net.validateServerPayloads
	getInstance(remote).OnClientEvent:Connect(function(payload: unknown)
		if validate then
			local _, reason = remote.check(payload)
			if reason ~= nil then
				warn(`[Net] server sent an invalid {remote.name} payload: {reason}`)
				return
			end
		end
		handler(payload :: T)
	end)
end

return Net
