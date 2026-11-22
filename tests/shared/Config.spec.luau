--!strict
-- Contract tests for Shared.Config, Shared.Config.Environment and Shared.DebugAccess.

local Config = require("../../src/shared/Config")
local DebugAccess = require("../../src/shared/DebugAccess")
local Environment = require("../../src/shared/Config/Environment")
local TestKit = require("../TestKit")

return function(t: TestKit.Context)
	local expect = t.expect

	-- Every environment resolves and records which one it is.
	t.test("resolves every environment", function()
		expect.equal(Config.resolve("dev").environment, "dev")
		expect.equal(Config.resolve("test").environment, "test")
		expect.equal(Config.resolve("production").environment, "production")
	end)

	-- Resolved config is frozen all the way down so systems cannot change shared values.
	t.test("resolved config is deeply frozen", function()
		local config = Config.resolve("dev")
		expect.truthy(table.isfrozen(config))
		expect.truthy(table.isfrozen(config.net))
		expect.truthy(table.isfrozen(config.net.defaultRateLimit))
		expect.throws(function()
			(config.net :: any).logViolations = false
		end)
	end)

	-- Each resolve builds a fresh table, so one environment's overrides never leak into another.
	t.test("environments do not share tables", function()
		local dev = Config.resolve("dev")
		local production = Config.resolve("production")
		expect.truthy(dev.debug ~= production.debug)
		expect.truthy(dev.debug.overlayExpandedByDefault)
		expect.falsy(production.debug.overlayExpandedByDefault)
	end)

	-- Production does not pay for validating trusted server payloads.
	t.test("production skips server payload validation", function()
		expect.truthy(Config.resolve("dev").net.validateServerPayloads)
		expect.falsy(Config.resolve("production").net.validateServerPayloads)
	end)

	-- Only the three known environment names parse.
	t.test("Environment.parse accepts only known names", function()
		expect.equal(Environment.parse("production"), "production")
		expect.equal(Environment.parse("staging"), nil)
		expect.equal(Environment.parse(nil), nil)
		expect.equal(Environment.parse(1), nil)
	end)

	-- Outside production everyone sees the debug overlay.
	t.test("DebugAccess allows everyone outside production", function()
		expect.truthy(DebugAccess.isAllowed(Config.resolve("dev"), 123, nil))
		expect.truthy(DebugAccess.isAllowed(Config.resolve("test"), 123, nil))
	end)

	-- In production only the owner (and listed users) see it.
	t.test("DebugAccess limits production to the owner", function()
		local production = Config.resolve("production")
		expect.truthy(DebugAccess.isAllowed(production, 42, 42))
		expect.falsy(DebugAccess.isAllowed(production, 7, 42))
		expect.falsy(DebugAccess.isAllowed(production, 7, nil))
	end)
end
