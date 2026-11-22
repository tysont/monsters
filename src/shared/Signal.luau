--!strict
-- A minimal typed signal for communication between services in the same context.
-- Handlers run synchronously, in connection order. Pure Luau, so it is usable under Lune.
--
--   local changed = Signal.new() :: Signal.Signal<string, number>
--   local disconnect = changed:connect(function(name, value) ... end)
--   changed:fire("health", 10)

export type Signal<T...> = {
	connect: (self: Signal<T...>, handler: (T...) -> ()) -> () -> (),
	fire: (self: Signal<T...>, T...) -> (),
	disconnectAll: (self: Signal<T...>) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	-- Handlers live in an ordered list; disconnecting marks an entry dead and compacts later, so a
	-- handler may disconnect itself or others while the signal is firing.
	local handlers: { { fn: (T...) -> (), alive: boolean } } = {}

	local signal = {}

	function signal.connect(_self: Signal<T...>, handler: (T...) -> ()): () -> ()
		local entry = { fn = handler, alive = true }
		table.insert(handlers, entry)
		return function()
			entry.alive = false
		end
	end

	function signal.fire(_self: Signal<T...>, ...: T...)
		local snapshot = table.clone(handlers)
		for _, entry in snapshot do
			if entry.alive then
				entry.fn(...)
			end
		end
		local live = {}
		for _, entry in handlers do
			if entry.alive then
				table.insert(live, entry)
			end
		end
		handlers = live
	end

	function signal.disconnectAll(_self: Signal<T...>)
		for _, entry in handlers do
			entry.alive = false
		end
		handlers = {}
	end

	return signal :: Signal<T...>
end

return Signal
