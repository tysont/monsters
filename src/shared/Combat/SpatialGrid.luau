--!strict
-- A uniform grid over the ground plane that indexes IDs by position, for target finding and
-- area hits without physics queries. Pure, unit tested under Lune.
--
-- Each ID lives in exactly one cell. `update` moves it when it crosses a cell boundary (cheap
-- when it does not). `query` visits every ID in the cells overlapping a circle; callers still
-- check exact distances.

export type Grid = {
	cellSize: number,
	-- Cell key -> list of IDs in that cell.
	cells: { [number]: { number } },
	-- ID -> its cell key and index in that cell's list.
	cellOf: { [number]: number },
	indexOf: { [number]: number },
	count: number,
}

local SpatialGrid = {}

-- Cell coordinates are packed into one number key; supports +/- 32767 cells per axis.
local OFFSET = 32768
local SPAN = 65536

local function key(cx: number, cz: number): number
	return (cx + OFFSET) * SPAN + (cz + OFFSET)
end

function SpatialGrid.new(cellSize: number): Grid
	assert(cellSize > 0, "cell size must be positive")
	return { cellSize = cellSize, cells = {}, cellOf = {}, indexOf = {}, count = 0 }
end

function SpatialGrid.cellKey(grid: Grid, x: number, z: number): number
	return key(math.floor(x / grid.cellSize), math.floor(z / grid.cellSize))
end

local function removeFromCell(grid: Grid, id: number)
	local k = grid.cellOf[id]
	local list = grid.cells[k]
	local index = grid.indexOf[id]
	local last = list[#list]
	-- Swap-remove keeps removal O(1).
	list[index] = last
	grid.indexOf[last] = index
	list[#list] = nil
	if #list == 0 then
		grid.cells[k] = nil
	end
end

local function addToCell(grid: Grid, id: number, k: number)
	local list = grid.cells[k]
	if list == nil then
		list = {}
		grid.cells[k] = list
	end
	table.insert(list, id)
	grid.cellOf[id] = k
	grid.indexOf[id] = #list
end

-- Adds or moves `id` to the cell containing (x, z).
function SpatialGrid.update(grid: Grid, id: number, x: number, z: number)
	local k = SpatialGrid.cellKey(grid, x, z)
	local current = grid.cellOf[id]
	if current == k then
		return
	end
	if current ~= nil then
		removeFromCell(grid, id)
	else
		grid.count += 1
	end
	addToCell(grid, id, k)
end

function SpatialGrid.remove(grid: Grid, id: number)
	if grid.cellOf[id] == nil then
		return
	end
	removeFromCell(grid, id)
	grid.cellOf[id] = nil
	grid.indexOf[id] = nil
	grid.count -= 1
end

function SpatialGrid.has(grid: Grid, id: number): boolean
	return grid.cellOf[id] ~= nil
end

-- Calls `visit(id)` for every ID in cells overlapping the circle at (x, z) with `radius`.
-- IDs outside the circle may be visited; check exact distances in `visit`.
function SpatialGrid.query(grid: Grid, x: number, z: number, radius: number, visit: (id: number) -> ())
	local size = grid.cellSize
	local minX, maxX = math.floor((x - radius) / size), math.floor((x + radius) / size)
	local minZ, maxZ = math.floor((z - radius) / size), math.floor((z + radius) / size)
	local cells = grid.cells
	for cx = minX, maxX do
		for cz = minZ, maxZ do
			local list = cells[key(cx, cz)]
			if list then
				for i = #list, 1, -1 do
					visit(list[i])
				end
			end
		end
	end
end

-- IDs in the cells overlapping the circle (convenience for tests and cold paths).
function SpatialGrid.collect(grid: Grid, x: number, z: number, radius: number): { number }
	local out: { number } = {}
	SpatialGrid.query(grid, x, z, radius, function(id)
		table.insert(out, id)
	end)
	return out
end

return SpatialGrid
