--!strict
-- Contract tests for Shared.Loader: modules start after their dependencies, every init runs
-- before any start, and bad dependency graphs fail loudly.

local Loader = require("../../src/shared/Loader")
local TestKit = require("../TestKit")

-- Runs spawned functions immediately, so tests do not need a scheduler.
local function spawnNow(fn: () -> ())
	fn()
end

local function names(modules: { Loader.Module }): { string }
	local out = {}
	for _, m in modules do
		table.insert(out, m.name)
	end
	return out
end

local function indexOf(list: { string }, value: string): number
	return table.find(list, value) or error(`{value} not in list`)
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- Each module comes after everything it depends on.
	t.test("sorts dependencies first", function()
		local order = names(Loader.sort({
			{ name = "Round", dependencies = { "Teams", "Data" } },
			{ name = "Teams", dependencies = { "Data" } },
			{ name = "Data" },
		}))
		expect.truthy(indexOf(order, "Data") < indexOf(order, "Teams"))
		expect.truthy(indexOf(order, "Teams") < indexOf(order, "Round"))
	end)

	-- Order does not depend on the order modules were given in.
	t.test("order is deterministic", function()
		local a = names(Loader.sort({ { name = "B" }, { name = "A" }, { name = "C" } }))
		local b = names(Loader.sort({ { name = "C" }, { name = "A" }, { name = "B" } }))
		expect.deepEqual(a, b)
	end)

	-- A cycle is an error that names the modules involved.
	t.test("rejects dependency cycles", function()
		expect.throws(function()
			Loader.sort({
				{ name = "A", dependencies = { "B" } },
				{ name = "B", dependencies = { "A" } },
			})
		end, "cycle")
	end)

	-- Depending on a module that does not exist is an error.
	t.test("rejects unknown dependencies", function()
		expect.throws(function()
			Loader.sort({ { name = "A", dependencies = { "Missing" } } })
		end, "Missing")
	end)

	-- Two modules with the same name is an error.
	t.test("rejects duplicate names", function()
		expect.throws(function()
			Loader.sort({ { name = "A" }, { name = "A" } })
		end, "duplicate")
	end)

	-- All init calls happen before any start call, each in dependency order.
	t.test("runs every init before any start", function()
		local log: { string } = {}
		local function module(name: string, deps: { string }?): Loader.Module
			return {
				name = name,
				dependencies = deps,
				init = function()
					table.insert(log, `init {name}`)
				end,
				start = function()
					table.insert(log, `start {name}`)
				end,
			}
		end
		Loader.run({ module("B", { "A" }), module("A") }, { spawn = spawnNow })
		expect.deepEqual(log, { "init A", "init B", "start A", "start B" })
	end)

	-- init and start receive the module as self.
	t.test("passes the module as self", function()
		local seen: any = nil
		local m: Loader.Module = {
			name = "A",
			init = function(self: any)
				seen = self
			end,
		}
		Loader.run({ m }, { spawn = spawnNow })
		expect.equal(seen, m)
	end)

	-- A failing init stops start-up and names the module.
	t.test("init failure names the module", function()
		expect.throws(function()
			Loader.run({
				{
					name = "Broken",
					init = function()
						error("boom")
					end,
				},
			}, { spawn = spawnNow })
		end, "Broken.init failed")
	end)
end
