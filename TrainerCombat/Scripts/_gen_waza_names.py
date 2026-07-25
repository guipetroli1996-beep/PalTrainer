import re
from pathlib import Path

src = Path(r"D:\PalworldModdingKit\Source\Pal\Public\EPalWazaID.h")
dest = Path(r"D:\Palworld - trainer combat project\TrainerCombat\Scripts\waza_names.lua")
text = src.read_text(encoding="utf-8")
m = re.search(r"enum class EPalWazaID[^{]*\{(.*?)\n\};", text, re.S)
if not m:
    raise SystemExit("enum not found")
names = []
for line in m.group(1).splitlines():
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    mm = re.match(r"([A-Za-z0-9_]+)\s*(?:=\s*(\d+))?\s*,?\s*$", line)
    if not mm:
        continue
    name = mm.group(1)
    if name == "MAX":
        break
    names.append(name)

lines = [
    "-- Auto-generated from EPalWazaID.h — do not edit by hand.",
    "-- Enum index = numeric EPalWazaID value.",
    "local WAZA_NAMES = {",
]
for i, n in enumerate(names):
    lines.append(f'    [{i}] = "{n}",')
lines.append("}")
lines.append("return WAZA_NAMES")
lines.append("")
dest.write_text("\n".join(lines), encoding="utf-8", newline="\n")
print(f"wrote {len(names)} names -> {dest}")
for key in ("Unique_Deer_PushupHorn", "SeedMachinegun", "FireBlast", "MudShot", "None"):
    print(f"  {key} = {names.index(key)}")
