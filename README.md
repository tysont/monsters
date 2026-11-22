# Monster Lane Wars

A Roblox lane-war game. Scripts live in `src/` and sync into Studio with [Rojo](https://rojo.space).
The plan is in [`docs/MONSTERS_IMPLEMENTATION_PLAN.md`](docs/MONSTERS_IMPLEMENTATION_PLAN.md).

## Setup (new machine)

1. Install [Rokit](https://github.com/rojo-rbx/rokit) and GNU make
   (Windows: `winget install ezwinports.make`; macOS: included with the Xcode command line tools).
2. `make setup` installs the pinned tools, Wally packages and Roblox type definitions.
3. `rojo plugin install` installs the Rojo plugin into Roblox Studio.
4. Open the game in Roblox Studio and enable the MCP server in the Assistant settings
   (for Claude Code).

## Daily loop

```
make serve
```

Then in Studio: **Plugins → Rojo → Connect**. Changes to files in `src/` appear in Studio
immediately. (On the main dev machine a scheduled task already runs `rojo serve` at logon.)

Before committing:

```
make check     # format check, lint, strict type check, unit tests
make fix       # auto-format
```

Other targets: `make test FILTER=Guard`, `make build` (writes `monsters.rbxl`), `make packages`.

## In-game debug overlay

Press **F2** (or tap the overlay) to expand or collapse it. It shows client and server frame
times, network, memory and instance counts. Everyone sees it in Studio; on live servers only the
experience owner and user IDs listed in `Config.debug.overlayUserIds` do.
