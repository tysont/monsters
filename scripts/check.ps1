# Format-check and type-check all Luau code.
# Usage: powershell -File scripts/check.ps1 [-Fix]
param([switch]$Fix)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Roblox API type definitions for luau-lsp (downloaded once, cached in .cache/)
$cache = Join-Path $root ".cache"
$defs = Join-Path $cache "globalTypes.d.luau"
if (-not (Test-Path $defs)) {
	New-Item -ItemType Directory -Force $cache | Out-Null
	Write-Host "Downloading Roblox type definitions..."
	Invoke-WebRequest -UseBasicParsing -OutFile $defs `
		"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
}

$failed = $false

if ($Fix) {
	stylua src
} else {
	stylua --check src
	if ($LASTEXITCODE -ne 0) { $failed = $true; Write-Host "Formatting issues (run with -Fix)." }
}

rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --definitions=$defs --no-strict-dm-types src
if ($LASTEXITCODE -ne 0) { $failed = $true }

if ($failed) { exit 1 }
Write-Host "All checks passed."
