# Monsters

A Roblox game. Scripts live in `src/` and sync into Studio with [Rojo](https://rojo.space).

## Setup (new machine)

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder.
2. `rojo plugin install` installs the Rojo plugin into Roblox Studio.
3. Open the game in Roblox Studio and enable the MCP server in the Assistant settings
   (for Claude Code).

## Daily loop

```
rojo serve
```

Then in Studio: **Plugins → Rojo → Connect**. Changes to files in `src/` appear in Studio
immediately.

Check code before committing:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1
```
