--!strict
-- Minimal test harness with no engine or Lune dependencies, so specs can run under Lune
-- (`make test`) and, later, inside Studio for engine-dependent code.
--
-- A spec module returns `function(t: TestKit.Context)` and registers cases with `t.test`.

export type Expect = {
	equal: (actual: any, expected: any) -> (),
	deepEqual: (actual: any, expected: any) -> (),
	near: (actual: number, expected: number, tolerance: number?) -> (),
	truthy: (value: any) -> (),
	falsy: (value: any) -> (),
	-- Asserts fn raises. If `contains` is given, the message must include it. Returns the message.
	throws: (fn: () -> (), contains: string?) -> string,
}

export type Context = {
	test: (name: string, fn: () -> ()) -> (),
	expect: Expect,
}

export type Spec = (t: Context) -> ()

export type Result = {
	passed: number,
	failed: number,
	failures: { string },
}

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local expect: Expect = {
	equal = function(actual: any, expected: any)
		if actual ~= expected then
			error(`expected {show(expected)}, got {show(actual)}`, 2)
		end
	end,
	deepEqual = function(actual: any, expected: any)
		if not deepEqual(actual, expected) then
			error("tables are not deeply equal", 2)
		end
	end,
	near = function(actual: number, expected: number, tolerance: number?)
		local tol = tolerance or 1e-6
		if type(actual) ~= "number" or math.abs(actual - expected) > tol then
			error(`expected {show(actual)} to be within {tol} of {expected}`, 2)
		end
	end,
	truthy = function(value: any)
		if not value then
			error(`expected truthy, got {show(value)}`, 2)
		end
	end,
	falsy = function(value: any)
		if value then
			error(`expected falsy, got {show(value)}`, 2)
		end
	end,
	throws = function(fn: () -> (), contains: string?): string
		local ok, err = pcall(fn :: any)
		if ok then
			error("expected the function to throw, but it returned normally", 2)
		end
		local message = tostring(err)
		if contains ~= nil and not string.find(message, contains, 1, true) then
			error(`expected error containing {show(contains)}, got {show(message)}`, 2)
		end
		return message
	end,
}

local TestKit = {}

-- Runs one spec. `report` receives a line per case.
function TestKit.run(specName: string, spec: Spec, report: (line: string) -> ()): Result
	local result: Result = { passed = 0, failed = 0, failures = {} }
	local context: Context = {
		expect = expect,
		test = function(name: string, fn: () -> ())
			local ok, err = pcall(fn :: any)
			if ok then
				result.passed += 1
				report(`  PASS  {name}`)
			else
				result.failed += 1
				local line = `{specName} > {name}: {err}`
				table.insert(result.failures, line)
				report(`  FAIL  {name}\n        {err}`)
			end
		end,
	}
	local ok, err = pcall(spec :: any, context)
	if not ok then
		result.failed += 1
		local line = `{specName}: error while defining cases: {err}`
		table.insert(result.failures, line)
		report(`  FAIL  {line}`)
	end
	return result
end

return TestKit
