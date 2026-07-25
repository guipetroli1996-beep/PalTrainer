@echo off
setlocal EnableExtensions

REM Copy TrainerCombat Lua mod + shipped LogicMod pak into Palworld.
REM Usage:
REM   install-to-game.bat "D:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\Mods"
REM Nested UE4SS layout:
REM   install-to-game.bat "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods"

if "%~1"=="" (
  echo Usage: install-to-game.bat ^<path-to-Palworld-Mods-folder^>
  echo Example: install-to-game.bat "C:\Steam\steamapps\common\Palworld\Pal\Binaries\Win64\Mods"
  exit /b 1
)

set "SRC=%~dp0TrainerCombat"
set "DST=%~1\TrainerCombat"
set "PAKSRC=%~dp0LogicMod\TrainerCombatBP\dist\TrainerCombatBP.pak"

if not exist "%SRC%\Scripts\main.lua" (
  echo ERROR: source mod not found at %SRC%
  exit /b 1
)

if not exist "%~1" (
  echo ERROR: Mods folder not found: %~1
  exit /b 1
)

xcopy "%SRC%" "%DST%\" /E /I /Y >nul
echo Installed Lua mod to %DST%
echo Make sure Mods\mods.txt contains: TrainerCombat : 1

if exist "%PAKSRC%" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$mods = (Resolve-Path -LiteralPath '%~1').Path;" ^
    "$pakSrc = (Resolve-Path -LiteralPath '%PAKSRC%').Path;" ^
    "$p = Get-Item -LiteralPath $mods;" ^
    "$pal = $null;" ^
    "while ($p -ne $null) {" ^
    "  if (Test-Path -LiteralPath (Join-Path $p.FullName 'Content\Paks')) { $pal = $p.FullName; break }" ^
    "  $p = $p.Parent" ^
    "};" ^
    "if ($null -eq $pal) { Write-Host 'WARN: could not find Content\Paks from Mods path — copy TrainerCombatBP.pak manually to Pal\Content\Paks\LogicMods\'; exit 0 };" ^
    "$destDir = Join-Path $pal 'Content\Paks\LogicMods';" ^
    "New-Item -ItemType Directory -Force -Path $destDir | Out-Null;" ^
    "$destPak = Join-Path $destDir 'TrainerCombatBP.pak';" ^
    "Copy-Item -LiteralPath $pakSrc -Destination $destPak -Force;" ^
    "Write-Host ('Installed LogicMod pak to ' + $destPak + ' (' + (Get-Item $destPak).Length + ' bytes)')"
) else (
  echo WARN: shipped pak not found at %PAKSRC%
)

echo Then launch the game and check UE4SS console for [TrainerCombat] loaded
echo Prefer also: bp: ModActor cached
endlocal
