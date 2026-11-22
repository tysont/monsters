--!strict
-- Every remote in the game, in one place. Add a remote here, then use it through Shared.Net.
-- The key becomes the remote's instance name.

local Guard = require("./Net/Guard")
local Net = require("./Net")

export type ServerStats = {
	-- Average and worst heartbeat interval over the sample window, in milliseconds.
	frameMs: number,
	frameMaxMs: number,
	-- Engine-reported time spent in the heartbeat step, in milliseconds.
	heartbeatMs: number,
	sendKBps: number,
	receiveKBps: number,
	memoryMb: number,
	instances: number,
	players: number,
}

return Net.define({
	-- Client tells the server whether its debug overlay is expanded, so stats go only where shown.
	DebugOverlayExpanded = Net.clientToServer({
		check = Guard.boolean,
		rateLimit = { rate = 2, burst = 5 },
	}),

	-- Dev tool: multiplies the sender's walk speed (1 = normal). Ignored for players without
	-- dev access.
	DevSetSpeedMultiplier = Net.clientToServer({
		check = Guard.number({ min = 1, max = 8 }),
		rateLimit = { rate = 2, burst = 5 },
	}),

	-- Dev tool: a reply to a dev chat command, shown as a system message in chat.
	DevMessage = Net.serverToClient({
		check = Guard.string(500),
	}),

	-- Server performance numbers for the debug overlay, sent about once a second.
	DebugServerStats = Net.serverToClient({
		check = Guard.struct({
			frameMs = Guard.number(),
			frameMaxMs = Guard.number(),
			heartbeatMs = Guard.number(),
			sendKBps = Guard.number(),
			receiveKBps = Guard.number(),
			memoryMb = Guard.number(),
			instances = Guard.number({ integer = true }),
			players = Guard.number({ integer = true }),
		}) :: Guard.Check<ServerStats>,
		reliable = false,
	}),
})
