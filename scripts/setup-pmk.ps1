#Requires -Version 5.1
<#
.SYNOPSIS
  Check / finish Palworld Modding Kit setup for TrainerCombatBP.
#>
param(
    [string]$KitRoot = "D:\PalworldModdingKit"
)

$ErrorActionPreference = "Continue"
Write-Host "=== TrainerCombat PMK setup check ===" -ForegroundColor Cyan
Write-Host "Kit: $KitRoot"

$ok = $true

function Check([string]$Name, [bool]$Pass, [string]$Hint) {
    if ($Pass) {
        Write-Host "[OK] $Name" -ForegroundColor Green
    } else {
        Write-Host "[MISSING] $Name — $Hint" -ForegroundColor Yellow
        $script:ok = $false
    }
}

Check "Git LFS" ((Get-Command git-lfs -ErrorAction SilentlyContinue) -ne $null) "git lfs install"
Check "PMK Pal.uproject" (Test-Path (Join-Path $KitRoot "Pal.uproject")) "git clone https://github.com/localcc/PalworldModdingKit $KitRoot"
Check ".NET 6 runtime" ((@(dotnet --list-runtimes 2>$null | Select-String "Microsoft.NETCore.App 6\.")).Count -gt 0) "Install .NET 6 Desktop/Runtime"
Check "VS 2022" (Test-Path "C:\Program Files\Microsoft Visual Studio\2022") "Install VS 2022 with C++ + MSVC v143 14.38"
$ue51 = @(
    "D:\Programas\UE_5.1",
    "C:\Program Files\Epic Games\UE_5.1",
    "D:\UE_5.1",
    "E:\UE_5.1"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
Check "Unreal Engine 5.1" ($null -ne $ue51) "Install UE 5.1 via Epic Games Launcher (this PC: D:\Programas\UE_5.1)"
if ($null -ne $ue51) {
    Write-Host "      Using: $ue51" -ForegroundColor DarkGray
}
Check "Wwise plugin in PMK" (Test-Path (Join-Path $KitRoot "Plugins\Wwise\Wwise.uplugin")) "Integrate Wwise 2021.1.11 offline files into Plugins\Wwise (pwmodding.wiki)"

$modsDir = Join-Path $KitRoot "Content\Mods\TrainerCombatBP"
if (-not (Test-Path $modsDir)) {
    New-Item -ItemType Directory -Force -Path $modsDir | Out-Null
}
$srcBuild = Join-Path $PSScriptRoot "..\LogicMod\TrainerCombatBP\BLUEPRINT_BUILD.md"
if (Test-Path $srcBuild) {
    Copy-Item $srcBuild (Join-Path $modsDir "BLUEPRINT_BUILD.md") -Force
    Write-Host "[OK] Synced BLUEPRINT_BUILD.md into PMK Content\Mods\TrainerCombatBP" -ForegroundColor Green
}

Write-Host ""
if ($ok) {
    Write-Host "Prereqs look present. Open Pal.uproject, run Editor Python scaffold, wire graphs, package chunk 7." -ForegroundColor Green
} else {
    Write-Host "Finish MISSING items, then re-run this script. Kit repo is at $KitRoot." -ForegroundColor Yellow
    Write-Host "Docs: https://pwmodding.wiki/docs/developers/palworld-modding-kit/prerequisites"
}
exit $(if ($ok) { 0 } else { 2 })
