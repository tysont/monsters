--!nocheck
-- Downloads the Roblox API type definitions used by luau-lsp into .cache/.
-- Usage: lune run scripts/fetch-types [--force]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")

local URL = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
local DIR = ".cache"
local FILE = `{DIR}/globalTypes.d.luau`

if fs.isFile(FILE) and process.args[1] ~= "--force" then
	return
end

print(`Downloading Roblox type definitions to {FILE}`)
local response = net.request(URL)
if not response.ok then
	print(`Download failed: {response.statusCode} {response.statusMessage}`)
	process.exit(1)
end
if not fs.isDir(DIR) then
	fs.writeDir(DIR)
end
fs.writeFile(FILE, response.body)
