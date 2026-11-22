--!strict
-- Contract tests for Shared.Net.Guard: every check returns (value, nil) for valid input and
-- (nil, reason) for invalid input, and must reject anything a hostile client could send.

local Guard = require("../../src/shared/Net/Guard")
local TestKit = require("../TestKit")

-- True when `check` accepts `value`.
local function accepts(check: Guard.Check<any>, value: any): boolean
	local _, reason = check(value)
	return reason == nil
end

return function(t: TestKit.Context)
	local expect = t.expect

	-- A plain finite number is accepted and returned unchanged.
	t.test("number accepts finite numbers", function()
		local value, reason = Guard.number()(3.5)
		expect.equal(value, 3.5)
		expect.equal(reason, nil)
	end)

	-- NaN and both infinities would poison maths on the server.
	t.test("number rejects NaN and infinity", function()
		local check = Guard.number()
		expect.falsy(accepts(check, 0 / 0))
		expect.falsy(accepts(check, math.huge))
		expect.falsy(accepts(check, -math.huge))
	end)

	-- Numeric strings are not numbers.
	t.test("number rejects non-number types", function()
		local check = Guard.number()
		expect.falsy(accepts(check, "5"))
		expect.falsy(accepts(check, nil))
		expect.falsy(accepts(check, {}))
	end)

	-- min and max are inclusive bounds.
	t.test("number enforces inclusive min and max", function()
		local check = Guard.number({ min = 0, max = 10 })
		expect.truthy(accepts(check, 0))
		expect.truthy(accepts(check, 10))
		expect.falsy(accepts(check, -0.01))
		expect.falsy(accepts(check, 10.01))
	end)

	-- integer rejects fractional values.
	t.test("number with integer rejects fractions", function()
		local check = Guard.number({ integer = true })
		expect.truthy(accepts(check, 4))
		expect.falsy(accepts(check, 4.5))
	end)

	-- Strings up to the limit pass; longer ones fail.
	t.test("string enforces max length", function()
		local check = Guard.string(3)
		expect.truthy(accepts(check, ""))
		expect.truthy(accepts(check, "abc"))
		expect.falsy(accepts(check, "abcd"))
		expect.falsy(accepts(check, 5))
	end)

	-- boolean accepts only true and false.
	t.test("boolean accepts only booleans", function()
		expect.truthy(accepts(Guard.boolean, true))
		expect.truthy(accepts(Guard.boolean, false))
		expect.falsy(accepts(Guard.boolean, nil))
		expect.falsy(accepts(Guard.boolean, 1))
	end)

	-- none accepts only an absent payload.
	t.test("none accepts only nil", function()
		expect.truthy(accepts(Guard.none, nil))
		expect.falsy(accepts(Guard.none, false))
		expect.falsy(accepts(Guard.none, 0))
	end)

	-- oneOf accepts only listed strings.
	t.test("oneOf accepts only listed values", function()
		local check = Guard.oneOf({ "top", "middle", "bottom" })
		expect.truthy(accepts(check, "middle"))
		expect.falsy(accepts(check, "jungle"))
		expect.falsy(accepts(check, 1))
	end)

	-- optional succeeds on nil and otherwise defers to the inner check.
	t.test("optional allows nil and validates present values", function()
		local check = Guard.optional(Guard.number())
		local value, reason = check(nil)
		expect.equal(value, nil)
		expect.equal(reason, nil)
		expect.truthy(accepts(check, 2))
		expect.falsy(accepts(check, "2"))
	end)

	-- Arrays are checked item by item and returned as a fresh table.
	t.test("array validates every item", function()
		local check = Guard.array(Guard.number(), 5)
		local value = check({ 1, 2, 3 })
		expect.deepEqual(value, { 1, 2, 3 })
		expect.falsy(accepts(check, { 1, "x" :: any, 3 }))
	end)

	-- Too many items is rejected, so clients cannot send huge tables.
	t.test("array rejects more than maxLength items", function()
		local check = Guard.array(Guard.number(), 2)
		expect.truthy(accepts(check, { 1, 2 }))
		expect.falsy(accepts(check, { 1, 2, 3 }))
	end)

	-- Holes and non-integer keys mean the value is not a plain array.
	t.test("array rejects tables that are not plain arrays", function()
		local check = Guard.array(Guard.number(), 5)
		expect.falsy(accepts(check, { 1, nil :: any, 3 }))
		expect.falsy(accepts(check, { a = 1 }))
	end)

	-- An empty array is valid.
	t.test("array accepts an empty table", function()
		expect.deepEqual(Guard.array(Guard.number(), 5)({}), {})
	end)

	-- A struct with exactly the expected fields passes and is copied.
	t.test("struct accepts matching tables", function()
		local check = Guard.struct({ lane = Guard.oneOf({ "top" }), amount = Guard.number() })
		local input = { lane = "top", amount = 2 }
		local value = check(input)
		expect.deepEqual(value, input)
		expect.truthy(value ~= input)
	end)

	-- Extra keys are rejected so clients cannot smuggle fields through.
	t.test("struct rejects unexpected keys", function()
		local check = Guard.struct({ amount = Guard.number() })
		expect.falsy(accepts(check, { amount = 1, admin = true }))
		expect.falsy(accepts(check, { amount = 1, [1] = 5 }))
	end)

	-- Missing required fields are rejected; missing optional fields are fine.
	t.test("struct enforces required and optional fields", function()
		local check = Guard.struct({ amount = Guard.number(), note = Guard.optional(Guard.string(10)) })
		expect.truthy(accepts(check, { amount = 1 }))
		expect.falsy(accepts(check, { note = "hi" }))
	end)

	-- The reason names the failing field.
	t.test("struct reason names the bad field", function()
		local check = Guard.struct({ amount = Guard.number() })
		local _, reason = check({ amount = "lots" })
		expect.truthy(reason ~= nil and string.find(reason, "amount", 1, true) ~= nil)
	end)

	-- Non-table values are rejected.
	t.test("struct rejects non-tables", function()
		expect.falsy(accepts(Guard.struct({}), "table"))
		expect.falsy(accepts(Guard.struct({}), nil))
	end)

	-- Buffers over the size limit are rejected.
	t.test("buffer enforces max length", function()
		local check = Guard.buffer(4)
		expect.truthy(accepts(check, buffer.create(4)))
		expect.falsy(accepts(check, buffer.create(5)))
		expect.falsy(accepts(check, "abcd"))
	end)
end
