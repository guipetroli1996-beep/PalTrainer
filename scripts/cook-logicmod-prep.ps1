#Requires -Version 5.1
<#
.SYNOPSIS
  Sync TrainerCombatBP recipes into PMK and (optionally) run Editor Python scaffold.

.NOTES
  UE 5.1 on this machine: D:\Programas\UE_5.1
  PMK: D:\PalworldModdingKit
  Prior pakchunk7 was ~3KB (empty). After Package, chunk 7 must be much larger.
#>
param(
    [string]$UeRoot = "D:\Programas\UE_5.1",
    [string]$KitRoot = "D:\PalworldModdingKit",
    [switch]$RunEditorPython,
    [switch]$SkipSync
)

$ErrorActionPreference = "Stop"
$projRoot = Split-Path $PSScriptRoot -Parent
$src = Join-Path $projRoot "LogicMod\TrainerCombatBP"
$dst = Join-Path $KitRoot "Content\Mods\TrainerCombatBP"
$editor = Join-Path $UeRoot "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$uproject = Join-Path $KitRoot "Pal.uproject"
$py = Join-Path $dst "Editor\CreateTrainerCombatLogicMod.py"

Write-Host "=== TrainerCombat LogicMod cook prep ===" -ForegroundColor Cyan
Write-Host "UE:  $UeRoot"
Write-Host "PMK: $KitRoot"

if (-not (Test-Path $editor)) {
    Write-Host "ERROR: UnrealEditor-Cmd not found at $editor" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $uproject)) {
    Write-Host "ERROR: missing $uproject" -ForegroundColor Red
    exit 1
}

if (-not $SkipSync) {
    New-Item -ItemType Directory -Force -Path (Join-Path $dst "Editor") | Out-Null
    Copy-Item (Join-Path $src "BLUEPRINT_BUILD.md") (Join-Path $dst "BLUEPRINT_BUILD.md") -Force
    Copy-Item (Join-Path $src "COOK_STATUS.md") (Join-Path $dst "COOK_STATUS.md") -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $src "Editor\CreateTrainerCombatLogicMod.py") $py -Force
    Write-Host "[OK] Synced docs + Editor Python -> $dst" -ForegroundColor Green
}

$chunk7Candidates = @(
    (Join-Path $KitRoot "Packaged\Windows\Pal\Content\Paks\pakchunk7-Windows.pak"),
    (Join-Path $KitRoot "Saved\StagedBuilds\Windows\Pal\Content\Paks\pakchunk7-Windows.pak")
)
foreach ($c in $chunk7Candidates) {
    if (Test-Path $c) {
        $len = (Get-Item $c).Length
        $color = if ($len -lt 10000) { "Yellow" } else { "Green" }
        Write-Host ("Current {0} = {1} bytes" -f $c, $len) -ForegroundColor $color
        if ($len -lt 10000) {
            Write-Host "  WARNING: chunk 7 looks empty/stub. Re-Package after PrimaryAssetLabel fix." -ForegroundColor Yellow
        }
    }
}

if ($RunEditorPython) {
    Write-Host "Launching UnrealEditor-Cmd to run scaffold Python (can take several minutes)..." -ForegroundColor Cyan
    $args = @(
        $uproject,
        "-ExecutePythonScript=`"$py`"",
        "-unattended",
        "-nop4",
        "-nosplash"
    )
    & $editor @args
    Write-Host "Editor Python exit code: $LASTEXITCODE"
}

Write-Host ""
Write-Host "Next (manual in Editor):" -ForegroundColor Cyan
Write-Host "  1. Open $uproject with UE 5.1"
Write-Host "  2. If needed: File → Execute Python Script → Editor\CreateTrainerCombatLogicMod.py"
Write-Host "  3. Open ModActor — add AimSkillHud properties + Show/Hide/SetSlot (BLUEPRINT_BUILD.md)"
Write-Host "  4. Open WBP_AimSkillHud — confirm 3 text slots Slot0Text/Slot1Text/Slot2Text"
Write-Host "  5. Open TrainerCombatBP PrimaryAssetLabel: Chunk=7, Always Cook, Label Assets in My Directory"
Write-Host "  6. Platforms → Windows → Package Project → Packaged\"
Write-Host "  7. powershell -File scripts\deploy-logicmod.ps1"
Write-Host "  8. Confirm pak size >> 3KB, then quit+relaunch Palworld"
Write-Host ""
Write-Host "Aim HUD Lua already writes AimSkill* properties / calls ShowAimSkillHud when aiming."
