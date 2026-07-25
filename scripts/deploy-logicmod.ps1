#Requires -Version 5.1
<#
.SYNOPSIS
  Copy cooked TrainerCombatBP chunk into Palworld LogicMods.
#>
param(
    [string]$KitRoot = "D:\PalworldModdingKit",
    [string]$ChunkId = "7",
    [string]$GamePaks = "E:\SteamLibrary\steamapps\common\Palworld\Pal\Content\Paks",
    [string]$CookedPak = ""
)

$ErrorActionPreference = "Stop"
$destDir = Join-Path $GamePaks "LogicMods"
$destPak = Join-Path $destDir "TrainerCombatBP.pak"

if (-not $CookedPak) {
    $candidates = @(
        (Join-Path $KitRoot "Windows\Pal\Content\Paks\pakchunk${ChunkId}-Windows.pak"),
        (Join-Path $KitRoot "Saved\StagedBuilds\Windows\Pal\Content\Paks\pakchunk${ChunkId}-Windows.pak")
    )
    $CookedPak = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $CookedPak -or -not (Test-Path $CookedPak)) {
    Write-Host "ERROR: Cooked pak not found for chunk $ChunkId." -ForegroundColor Red
    Write-Host "Package the project in Unreal (Platforms → Windows → Package Project),"
    Write-Host "then re-run, or pass -CookedPak path\to\pakchunk${ChunkId}-Windows.pak"
    exit 1
}

$len = (Get-Item -LiteralPath $CookedPak).Length
# Cooked BPs compress small; empty stubs were ~3KB with no ModActor.
# Require ModActor presence via size floor of 5KB (was 10KB — blocked valid ~6.7KB packs).
if ($len -lt 5000) {
    Write-Host "ERROR: $CookedPak is only $len bytes — chunk $ChunkId looks empty." -ForegroundColor Red
    Write-Host "Fix PrimaryAssetLabel (Chunk $ChunkId, Priority 100, Always Cook, Explicit Assets),"
    Write-Host "ensure ModActor + WBP_AimSkillHud are under Content/Mods/TrainerCombatBP, then Package again."
    Write-Host "UE 5.1 on this PC: D:\Programas\UE_5.1"
    exit 2
}

New-Item -ItemType Directory -Force -Path $destDir | Out-Null
Copy-Item -LiteralPath $CookedPak -Destination $destPak -Force
Write-Host "Deployed ($len bytes):" -ForegroundColor Green
Write-Host "  $CookedPak"
Write-Host "  -> $destPak"
Write-Host "Launch Palworld and confirm UE4SS loads TrainerCombatBP + Lua bp: ModActor cached"
