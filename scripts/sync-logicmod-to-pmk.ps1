#Requires -Version 5.1
$src = Join-Path $PSScriptRoot "..\LogicMod\TrainerCombatBP"
$dst = "D:\PalworldModdingKit\Content\Mods\TrainerCombatBP"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item (Join-Path $src "BLUEPRINT_BUILD.md") (Join-Path $dst "BLUEPRINT_BUILD.md") -Force
$editorDst = Join-Path $dst "Editor"
New-Item -ItemType Directory -Force -Path $editorDst | Out-Null
Copy-Item (Join-Path $src "Editor\CreateTrainerCombatLogicMod.py") (Join-Path $editorDst "CreateTrainerCombatLogicMod.py") -Force
Write-Host "Synced LogicMod docs/scripts -> $dst"
