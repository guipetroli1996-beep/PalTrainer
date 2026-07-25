@echo off
setlocal

REM Copy TrainerCombat into your Palworld UE4SS Mods folder.
REM Usage:
REM   install-to-game.bat "D:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\Mods"
REM This machine (UE4SS under ue4ss\):
REM   install-to-game.bat "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods"

if "%~1"=="" (
  echo Usage: install-to-game.bat ^<path-to-Palworld-Mods-folder^>
  echo Example: install-to-game.bat "C:\Steam\steamapps\common\Palworld\Pal\Binaries\Win64\Mods"
  exit /b 1
)

set "SRC=%~dp0TrainerCombat"
set "DST=%~1\TrainerCombat"

if not exist "%SRC%\Scripts\main.lua" (
  echo ERROR: source mod not found at %SRC%
  exit /b 1
)

if not exist "%~1" (
  echo ERROR: Mods folder not found: %~1
  exit /b 1
)

xcopy "%SRC%" "%DST%\" /E /I /Y >nul
echo Installed to %DST%
echo Make sure Mods\mods.txt contains: TrainerCombat : 1
echo Then launch the game and check UE4SS console for [TrainerCombat] loaded
endlocal
