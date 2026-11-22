--!strict
-- Contract tests for Shared.Signal.

local Signal = require("../../src/shared/Signal")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect

	-- Handlers receive the fired arguments, in connection order.
	t.test("fires handlers in order with arguments", function()
		local s = Signal.new() :: Signal.Signal<string, number>
		local log = {}
		s:connect(function(a, b)
			table.insert(log, `1:{a}{b}`)
		end)
		s:connect(function(a, b)
			table.insert(log, `2:{a}{b}`)
		end)
		s:fire("x", 1)
		expect.deepEqual(log, { "1:x1", "2:x1" })
	end)

	-- A disconnected handler no longer runs.
	t.test("disconnect stops a handler", function()
		local s = Signal.new() :: Signal.Signal<()>
		local count = 0
		local disconnect = s:connect(function()
			count += 1
		end)
		s:fire()
		disconnect()
		s:fire()
		expect.equal(count, 1)
	end)

	-- A handler may disconnect itself while the signal is firing.
	t.test("handlers can disconnect during fire", function()
		local s = Signal.new() :: Signal.Signal<()>
		local count = 0
		local disconnect: () -> () = function() end
		disconnect = s:connect(function()
			count += 1
			disconnect()
		end)
		s:fire()
		s:fire()
		expect.equal(count, 1)
	end)

	-- disconnectAll removes every handler.
	t.test("disconnectAll removes all handlers", function()
		local s = Signal.new() :: Signal.Signal<()>
		local count = 0
		s:connect(function()
			count += 1
		end)
		s:disconnectAll()
		s:fire()
		expect.equal(count, 0)
	end)
end
