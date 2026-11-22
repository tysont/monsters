# Monsters (Roblox game)

## How this project works

- **Code lives in `src/` as `.luau` files.** This repo is the source of truth for all scripts.
- **Rojo** (`rojo serve`) syncs `src/` into the open Roblox Studio place live. The Studio
  plugin must be connected (Plugins tab → Rojo → Connect).
- **Roblox Studio MCP** (`Roblox_Studio` server) is for things that need Studio itself:
  playtesting, console output, screenshots, inspecting the Explorer tree, inserting assets,
  building/editing parts, models, terrain and UI.
- Non-script content (maps, models, UI layouts, terrain) lives in the cloud place in Studio,
  not in this repo.

## Rules

- **Edit scripts only by editing files in `src/`.** Never change script source through MCP
  (`multi_edit`, setting `.Source` via `execute_luau`, etc.). Rojo overwrites Studio-side
  script edits, so they would be lost.
- MCP `execute_luau` is fine for reading state, building/placing instances, and debugging.
- Before Roblox-specific work, check `list_roblox_skills` / `get_roblox_skill` for current API
  guidance.
- After editing code, run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1`
  (StyLua format check + luau-lsp strict type check). Use `-Fix` to auto-format. Fix all errors
  before handing off.
- Use `--!strict` at the top of every file and type function signatures.
- Do not commit or push unless asked.

## File → Studio mapping (see `default.project.json`)

| Folder        | Studio location                                   |
|---------------|---------------------------------------------------|
| `src/server`  | `ServerScriptService.Server`                      |
| `src/client`  | `StarterPlayer.StarterPlayerScripts.Client`       |
| `src/shared`  | `ReplicatedStorage.Shared`                        |

Naming: `Foo.server.luau` → Script, `Foo.client.luau` → LocalScript, `Foo.luau` → ModuleScript.
A folder with `init.luau` becomes a ModuleScript whose children are the folder's other files.

## Tooling

Tools are pinned in `rokit.toml` (Rojo, StyLua, luau-lsp). Run `rokit install` on a new machine.
