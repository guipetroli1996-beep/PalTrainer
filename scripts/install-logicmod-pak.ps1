#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$ModsFolder,
    [Parameter(Mandatory = $true)][string]$PakSource
)

$ErrorActionPreference = "Stop"

$mods = (Resolve-Path -LiteralPath $ModsFolder).Path
$pakSrc = (Resolve-Path -LiteralPath $PakSource).Path

$p = Get-Item -LiteralPath $mods
$pal = $null
while ($null -ne $p) {
    if (Test-Path -LiteralPath (Join-Path $p.FullName "Content\Paks")) {
        $pal = $p.FullName
        break
    }
    $p = $p.Parent
}

if ($null -eq $pal) {
    Write-Host "WARN: could not find Content\Paks from Mods path - copy TrainerCombatBP.pak manually to Pal\Content\Paks\LogicMods\"
    exit 0
}

$destDir = Join-Path $pal "Content\Paks\LogicMods"
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$destPak = Join-Path $destDir "TrainerCombatBP.pak"
Copy-Item -LiteralPath $pakSrc -Destination $destPak -Force
$len = (Get-Item -LiteralPath $destPak).Length
Write-Host "Installed LogicMod pak to $destPak ($len bytes)"
