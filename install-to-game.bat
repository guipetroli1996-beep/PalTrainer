@echo off
setlocal

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
set "HELPER=%~dp0scripts\install-logicmod-pak.ps1"

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
  if exist "%HELPER%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -ModsFolder "%~1" -PakSource "%PAKSRC%"
  ) else (
    echo WARN: missing %HELPER% - copy TrainerCombatBP.pak to Pal\Content\Paks\LogicMods\ manually
  )
) else (
  echo WARN: shipped pak not found at %PAKSRC%
)

echo Then launch the game and check UE4SS console for [TrainerCombat] loaded
echo Prefer also: bp: ModActor cached
endlocal
