--!strict
-- Starts server services and client controllers in dependency order.
--
-- A module (service or controller) is a table with a unique `name` and optional:
--   dependencies  names of modules that must be initialised before this one
--   init()        called once, in dependency order; must not yield. Set up state and
--                 connections here so other modules can rely on them.
--   start()       called after every init has finished, in dependency order, each in its own
--                 thread so one module waiting on something does not hold up the rest.
--
-- `Loader.run` is pure apart from the injected `spawn`, so the ordering is unit tested under Lune.

export type Module = {
	name: string,
	dependencies: { string }?,
	init: ((self: any) -> ())?,
	start: ((self: any) -> ())?,
}

export type Options = {
	-- Runs a function in a new thread. Defaults to task.spawn.
	spawn: ((fn: () -> ()) -> ())?,
}

local Loader = {}

-- Returns the modules sorted so every module comes after its dependencies.
-- Errors on duplicate names, unknown dependencies, and cycles.
function Loader.sort(modules: { Module }): { Module }
	local byName: { [string]: Module } = {}
	for _, module in modules do
		assert(type(module.name) == "string" and module.name ~= "", "every module needs a name")
		assert(byName[module.name] == nil, `duplicate module name {module.name}`)
		byName[module.name] = module
	end

	local sorted: { Module } = {}
	local state: { [string]: "visiting" | "done" } = {}

	local function visit(module: Module, path: { string })
		local s = state[module.name]
		if s == "done" then
			return
		end
		if s == "visiting" then
			table.insert(path, module.name)
			error(`dependency cycle: {table.concat(path, " -> ")}`, 0)
		end
		state[module.name] = "visiting"
		table.insert(path, module.name)
		local dependencies: { string } = module.dependencies or {}
		for _, depName in dependencies do
			local dep = byName[depName]
			if dep == nil then
				error(`{module.name} depends on unknown module {depName}`, 0)
			end
			visit(dep, path)
		end
		table.remove(path)
		state[module.name] = "done"
		table.insert(sorted, module)
	end

	-- Visit in name order so start-up order does not depend on how modules were found.
	local names: { string } = {}
	for name in byName do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		visit(byName[name], {})
	end
	return sorted
end

-- Initialises then starts the modules. Returns them in the order they were started.
function Loader.run(modules: { Module }, options: Options?): { Module }
	local spawn: (fn: () -> ()) -> () = if options and options.spawn
		then options.spawn
		else function(fn: () -> ())
			task.spawn(fn)
		end
	local sorted = Loader.sort(modules)
	for _, module in sorted do
		local init = module.init
		if init then
			-- Cast: strict mode types pcall of a function returning nothing as returning one value.
			local ok, err = pcall(init :: any, module)
			if not ok then
				error(`{module.name}.init failed: {err}`, 0)
			end
		end
	end
	for _, module in sorted do
		local start = module.start
		if start then
			spawn(function()
				start(module)
			end)
		end
	end
	return sorted
end

-- Requires every ModuleScript directly inside `container` and runs them.
function Loader.runContainer(container: Instance): { Module }
	local modules: { Module } = {}
	for _, child in container:GetChildren() do
		if child:IsA("ModuleScript") then
			local module = (require :: any)(child)
			assert(type(module) == "table", `{child:GetFullName()} must return a table`)
			if module.name == nil then
				module.name = child.Name
			end
			table.insert(modules, module :: Module)
		end
	end
	return Loader.run(modules)
end

return Loader
