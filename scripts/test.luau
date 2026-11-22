--!nocheck
-- Runs every tests/**/*.spec.luau under Lune. Exits non-zero if any case fails.
-- Usage: lune run scripts/test [filter]   (filter matches part of the spec path)

local fs = require("@lune/fs")
local process = require("@lune/process")

local TestKit = require("../tests/TestKit")

local filter = process.args[1]

local function collect(dir, out)
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			collect(path, out)
		elseif string.sub(entry, -10) == ".spec.luau" then
			if filter == nil or string.find(path, filter, 1, true) then
				table.insert(out, path)
			end
		end
	end
	return out
end

local specs = collect("tests", {})
local passed, failed = 0, 0
local failures = {}

for _, path in specs do
	print(path)
	-- Paths are relative to this file, which lives in scripts/.
	local spec = require(`../{string.sub(path, 1, -6)}`)
	local result = TestKit.run(path, spec, print)
	passed += result.passed
	failed += result.failed
	for _, line in result.failures do
		table.insert(failures, line)
	end
end

print()
if #specs == 0 then
	print("No spec files found.")
	process.exit(1)
end
for _, line in failures do
	print(`FAIL {line}`)
end
print(`{passed} passed, {failed} failed, {#specs} spec files`)
process.exit(if failed > 0 then 1 else 0)
