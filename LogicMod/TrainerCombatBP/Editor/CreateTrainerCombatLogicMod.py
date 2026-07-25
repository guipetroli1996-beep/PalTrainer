"""
Unreal Editor Python — scaffold / refresh TrainerCombatBP LogicMod assets.

Run inside Pal.uproject (UE 5.1 at D:\\Programas\\UE_5.1):
  File → Execute Python Script → this file
  OR:
  UnrealEditor-Cmd.exe Pal.uproject -ExecutePythonScript="<this file>" -unattended

Creates / refreshes:
  /Game/Mods/TrainerCombatBP/ModActor
  /Game/Mods/TrainerCombatBP/TrainerCombatBP (PrimaryAssetLabel chunk 7)
  /Game/Mods/TrainerCombatBP/WBP_AimSkillHud

Then wire graphs per BLUEPRINT_BUILD.md and Package Windows → deploy chunk 7.
"""

import unreal

MOD_PATH = "/Game/Mods/TrainerCombatBP"
CHUNK_ID = 7


def ensure_folder(path: str) -> None:
    if not unreal.EditorAssetLibrary.does_directory_exist(path):
        unreal.EditorAssetLibrary.make_directory(path)
        unreal.log("Created folder " + path)


def create_mod_actor():
    asset_name = "ModActor"
    asset_path = MOD_PATH + "/" + asset_name
    if unreal.EditorAssetLibrary.does_asset_exist(asset_path):
        unreal.log("ModActor already exists: " + asset_path)
        return unreal.EditorAssetLibrary.load_asset(asset_path)

    factory = unreal.BlueprintFactory()
    factory.set_editor_property("parent_class", unreal.Actor)
    asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
    bp = asset_tools.create_asset(asset_name, MOD_PATH, unreal.Blueprint, factory)
    if bp is None:
        unreal.log_error("Failed to create ModActor blueprint")
        return None
    unreal.EditorAssetLibrary.save_asset(asset_path)
    unreal.log("Created " + asset_path)
    return bp


def create_aim_skill_hud_widget():
    asset_name = "WBP_AimSkillHud"
    asset_path = MOD_PATH + "/" + asset_name
    if unreal.EditorAssetLibrary.does_asset_exist(asset_path):
        unreal.log("WBP_AimSkillHud already exists: " + asset_path)
        return unreal.EditorAssetLibrary.load_asset(asset_path)

    factory = unreal.WidgetBlueprintFactory()
    asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
    wbp = None
    try:
        wbp = asset_tools.create_asset(
            asset_name,
            MOD_PATH,
            unreal.WidgetBlueprint,
            factory,
        )
    except Exception as exc:
        unreal.log_error("WBP_AimSkillHud create failed: %s" % exc)
        return None

    if wbp is None:
        unreal.log_error("Could not create WBP_AimSkillHud")
        return None

    # Best-effort: root canvas + three text lines (manual polish still OK).
    try:
        widget_tree = wbp.widget_tree
        if widget_tree is not None:
            root = widget_tree.root_widget
            if root is None:
                canvas = widget_tree.construct_widget(unreal.CanvasPanel, "RootCanvas")
                widget_tree.root_widget = canvas
                root = canvas
            vbox = widget_tree.construct_widget(unreal.VerticalBox, "SlotList")
            if isinstance(root, unreal.CanvasPanel):
                slot = root.add_child_to_canvas(vbox)
                try:
                    slot.set_anchors(unreal.Anchors(minimum=(0.5, 0.88), maximum=(0.5, 0.88)))
                    slot.set_alignment(unreal.Vector2D(0.5, 0.5))
                    slot.set_auto_size(True)
                except Exception:
                    pass
            for i in range(3):
                txt = widget_tree.construct_widget(unreal.TextBlock, "Slot%dText" % i)
                try:
                    txt.set_text(unreal.Text("[%d] —" % (i + 1)))
                except Exception:
                    pass
                if isinstance(vbox, unreal.VerticalBox):
                    vbox.add_child_to_vertical_box(txt)
    except Exception as exc:
        unreal.log("WBP layout scaffold partial: %s (open and finish in UMG designer)" % exc)

    unreal.EditorAssetLibrary.save_asset(asset_path)
    unreal.log("Created/saved " + asset_path)
    return wbp


def ensure_primary_asset_label():
    asset_name = "TrainerCombatBP"
    asset_path = MOD_PATH + "/" + asset_name
    label = None
    if unreal.EditorAssetLibrary.does_asset_exist(asset_path):
        label = unreal.EditorAssetLibrary.load_asset(asset_path)
        unreal.log("PrimaryAssetLabel exists: " + asset_path)
    else:
        factory = unreal.DataAssetFactory()
        try:
            factory.set_editor_property("data_asset_class", unreal.PrimaryAssetLabel)
        except Exception:
            pass
        asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
        label = asset_tools.create_asset(
            asset_name,
            MOD_PATH,
            unreal.PrimaryAssetLabel,
            factory,
        )
        if label is None:
            unreal.log_error("Could not create PrimaryAssetLabel")
            return None
        unreal.log("Created PrimaryAssetLabel at " + asset_path)

    # Critical: empty chunk-7 packs happen when these are wrong.
    try:
        label.set_editor_property("chunk_id", CHUNK_ID)
    except Exception:
        unreal.log_error("Set Chunk ID = %s manually" % CHUNK_ID)
    try:
        label.set_editor_property(
            "cook_rule",
            unreal.PrimaryAssetCookRule.ALWAYS_COOK,
        )
    except Exception:
        unreal.log("Set Cook Rule = Always Cook manually")
    try:
        label.set_editor_property("label_assets_in_my_directory", True)
    except Exception:
        unreal.log("Enable Label Assets in My Directory manually")

    # Beat default Priority=-1 so assets are not left in chunk 0.
    try:
        rules = label.get_editor_property("rules")
        rules.chunk_id = CHUNK_ID
        rules.priority = 100
        try:
            rules.cook_rule = unreal.PrimaryAssetCookRule.ALWAYS_COOK
        except Exception:
            pass
        try:
            rules.apply_recursively = True
        except Exception:
            pass
        label.set_editor_property("rules", rules)
        unreal.log("PrimaryAssetLabel rules: chunk=%s priority=100 AlwaysCook" % CHUNK_ID)
    except Exception as exc:
        unreal.log("Could not set Rules (%s) — set Priority=100 and ChunkId=7 in Details" % exc)

    # Explicitly include ModActor + WBP so chunk 7 is not empty.
    try:
        explicit = []
        for name in ("ModActor", "WBP_AimSkillHud"):
            p = MOD_PATH + "/" + name
            if unreal.EditorAssetLibrary.does_asset_exist(p):
                soft = unreal.SoftObjectPath(p + "." + name)
                explicit.append(soft)
                # Also try without .Name suffix
                explicit.append(unreal.SoftObjectPath(p))
        # Deduplicate by path string
        seen = set()
        unique = []
        for s in explicit:
            key = str(s)
            if key not in seen:
                seen.add(key)
                unique.append(s)
        if unique:
            label.set_editor_property("explicit_assets", unique)
            unreal.log("PrimaryAssetLabel explicit_assets count=%d" % len(unique))
    except Exception as exc:
        unreal.log("Could not set explicit_assets (%s) — add ModActor + WBP_AimSkillHud manually" % exc)

    unreal.EditorAssetLibrary.save_asset(asset_path)
    unreal.log(
        "PrimaryAssetLabel chunk_id=%s saved. Re-Package Windows so pakchunk%d is >> 10KB."
        % (CHUNK_ID, CHUNK_ID)
    )
    return label


def main():
    ensure_folder("/Game/Mods")
    ensure_folder(MOD_PATH)
    create_mod_actor()
    create_aim_skill_hud_widget()
    ensure_primary_asset_label()
    unreal.log(
        "TrainerCombatBP scaffold done. Wire AimSkillHud Show/Hide/SetSlot on ModActor "
        "(BLUEPRINT_BUILD.md), then Platforms → Windows → Package Project."
    )


if __name__ == "__main__":
    main()
