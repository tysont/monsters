# Local build and check targets. Every recipe is a single plain command so it works the same
# from PowerShell, cmd, Git Bash and macOS. Anything more involved lives in a Lune script.
#
#   make setup      install tools and packages (fresh clone)
#   make check      everything that must pass before a commit: format, lint, types, tests
#   make fix        auto-format
#   make test       unit tests only (make test FILTER=Guard to run a subset)
#   make build      build a place file to monsters.rbxl (git-ignored)
#   make serve      run Rojo in the foreground (normally the "Rojo - monsters" task does this)

.PHONY: setup packages check fmt-check fix lint typecheck test build serve sourcemap

DEFS := .cache/globalTypes.d.luau
LUAU_DIRS := src tests scripts

setup:
	rokit install --no-trust-check
	wally install
	rojo sourcemap default.project.json --output sourcemap.json
	lune run scripts/package-types
	lune run scripts/fetch-types

# Wally packages, plus type re-exports so luau-lsp sees package types (scripts/package-types.luau).
packages:
	wally install
	rojo sourcemap default.project.json --output sourcemap.json
	lune run scripts/package-types

check: fmt-check lint typecheck test

fmt-check:
	stylua --check $(LUAU_DIRS)

fix:
	stylua $(LUAU_DIRS)

lint:
	selene $(LUAU_DIRS)

sourcemap:
	rojo sourcemap default.project.json --output sourcemap.json

$(DEFS):
	lune run scripts/fetch-types

typecheck: sourcemap $(DEFS)
	luau-lsp analyze --sourcemap=sourcemap.json --definitions=$(DEFS) --no-strict-dm-types --ignore=Packages/** --ignore=ServerPackages/** src tests

test:
	lune run scripts/test $(FILTER)

build:
	rojo build default.project.json --output monsters.rbxl

serve:
	rojo serve
