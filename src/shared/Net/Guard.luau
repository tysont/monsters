--!strict
-- Payload validators for remotes. A Check<T> takes an untrusted value and returns either
-- `(value, nil)` when it is a valid T, or `(nil, reason)` when it is not. Success is decided by
-- the reason being nil, so checks for optional values can succeed with a nil value.
--
-- Everything a client sends must pass a Check before game code sees it. Checks reject NaN and
-- infinity, oversized strings and arrays, and unexpected table keys.
--
-- Pure Luau, except `vector3` which needs the engine's Vector3 type.

export type Check<T> = (value: unknown) -> (T?, string?)

local Guard = {}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

export type NumberOptions = {
	min: number?,
	max: number?,
	integer: boolean?,
}

function Guard.number(options: NumberOptions?): Check<number>
	local min = options and options.min
	local max = options and options.max
	local integer = options ~= nil and options.integer == true
	return function(value: unknown): (number?, string?)
		if type(value) ~= "number" then
			return nil, `expected number, got {typeof(value)}`
		end
		if not isFinite(value) then
			return nil, "expected a finite number"
		end
		if integer and value % 1 ~= 0 then
			return nil, "expected an integer"
		end
		if min ~= nil and value < min then
			return nil, `expected >= {min}, got {value}`
		end
		if max ~= nil and value > max then
			return nil, `expected <= {max}, got {value}`
		end
		return value, nil
	end
end

function Guard.string(maxLength: number): Check<string>
	return function(value: unknown): (string?, string?)
		if type(value) ~= "string" then
			return nil, `expected string, got {typeof(value)}`
		end
		if #value > maxLength then
			return nil, `string longer than {maxLength}`
		end
		return value, nil
	end
end

Guard.boolean = function(value: unknown): (boolean?, string?)
	if type(value) ~= "boolean" then
		return nil, `expected boolean, got {typeof(value)}`
	end
	return value, nil
end :: Check<boolean>

-- Accepts nothing (for remotes with no payload).
Guard.none = function(value: unknown): (nil, string?)
	if value ~= nil then
		return nil, `expected no payload, got {typeof(value)}`
	end
	return nil, nil
end :: Check<nil>

-- Accepts one of a fixed set of strings, e.g. Guard.oneOf({ "top", "middle", "bottom" }).
function Guard.oneOf(options: { string }): Check<string>
	local allowed: { [string]: true } = {}
	for _, option in options do
		allowed[option] = true
	end
	return function(value: unknown): (string?, string?)
		if type(value) ~= "string" or not allowed[value] then
			return nil, "not an allowed value"
		end
		return value, nil
	end
end

function Guard.vector3(): Check<Vector3>
	return function(value: unknown): (Vector3?, string?)
		if typeof(value) ~= "Vector3" then
			return nil, `expected Vector3, got {typeof(value)}`
		end
		local v = value :: Vector3
		if not (isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)) then
			return nil, "expected a finite Vector3"
		end
		return v, nil
	end
end

function Guard.buffer(maxLength: number): Check<buffer>
	return function(value: unknown): (buffer?, string?)
		if type(value) ~= "buffer" then
			return nil, `expected buffer, got {typeof(value)}`
		end
		if buffer.len(value) > maxLength then
			return nil, `buffer longer than {maxLength}`
		end
		return value, nil
	end
end

function Guard.optional<T>(check: Check<T>): Check<T?>
	return function(value: unknown): (T?, string?)
		if value == nil then
			return nil, nil
		end
		return check(value)
	end
end

-- An array (keys 1..n with no gaps) of at most maxLength items, each passing `check`.
function Guard.array<T>(check: Check<T>, maxLength: number): Check<{ T }>
	return function(value: unknown): ({ T }?, string?)
		if type(value) ~= "table" then
			return nil, `expected array, got {typeof(value)}`
		end
		local t = value :: { [unknown]: unknown }
		local count = 0
		for _ in t do
			count += 1
			if count > maxLength then
				return nil, `array longer than {maxLength}`
			end
		end
		local result: { T } = table.create(count)
		for i = 1, count do
			local item, reason = check(t[i])
			if reason ~= nil then
				return nil, `[{i}]: {reason}`
			end
			result[i] = item :: T
		end
		return result, nil
	end
end

-- A table with exactly the given string keys (missing keys are allowed only if their check
-- accepts nil). Luau cannot derive the result type from the shape, so annotate the result:
--
--   local checkMove: Guard.Check<MovePayload> = Guard.struct({ target = Guard.vector3() })
--
-- The result is a fresh table containing only the checked fields.
function Guard.struct(shape: { [string]: Check<any> }): Check<any>
	return function(value: unknown): (any, string?)
		if type(value) ~= "table" then
			return nil, `expected table, got {typeof(value)}`
		end
		local t = value :: { [unknown]: unknown }
		for key in t do
			if type(key) ~= "string" or shape[key] == nil then
				return nil, `unexpected key {tostring(key)}`
			end
		end
		local result: { [string]: any } = {}
		for key, check in shape do
			local field, reason = check(t[key])
			if reason ~= nil then
				return nil, `{key}: {reason}`
			end
			result[key] = field
		end
		return result, nil
	end
end

-- Accepts anything. Only for server-to-client payloads, which are trusted.
Guard.trusted = function(value: unknown): (any, string?)
	return value, nil
end :: Check<any>

return Guard
