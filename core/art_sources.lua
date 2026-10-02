-- Read-only source-sheet metadata mirrors ROAG's declared art-pack contract.
-- The Studio deliberately consumes this as data instead of loading/executing
-- the game's Lua module, so browsing assets never runs game code.
local Sources = {}

Sources.roles = {
  { "player", "Player", "Core" }, { "target", "Target", "Core" }, { "ammo", "Ammo", "Core" }, { "torch", "Torch", "Core" }, { "door", "Exit door", "Core" }, { "bullet", "Bullet", "Core" }, { "bomb", "Bomb", "Core" }, { "flare", "Flare", "Core" },
  { "wall_left", "Wall left face", "Terrain" }, { "wall_right", "Wall right face", "Terrain" }, { "wall_up", "Wall up face", "Terrain" }, { "wall_down", "Wall down face", "Terrain" },
  { "wolf", "Wolf", "Enemies" }, { "bomber", "Bomber", "Enemies" }, { "necromancer", "Necromancer", "Enemies" }, { "cultist", "Cultist", "Enemies" }, { "ripper", "Ripper", "Enemies" }, { "skirmisher", "Skirmisher", "Enemies" }, { "conductor", "Conductor", "Enemies" }, { "bulwark", "Bulwark", "Enemies" }, { "reclaimer", "Reclaimer", "Enemies" },
  { "gunner_elite", "Redundant gunner", "Elites" }, { "shock_bruiser", "Shock bruiser", "Elites" }, { "volatile_heavy", "Volatile heavy", "Elites" },
  { "arc_cutter", "Arc cutter", "Reactor" }, { "maintenance_heavy", "Maintenance heavy", "Reactor" }, { "reactor_suppressor", "Reactor suppressor", "Reactor" }, { "arc_warden", "Arc warden", "Reactor" }, { "boss", "Boss", "Boss" },
}

Sources.sheets = {
  ["art_pack.roag_kenney_1bit"] = {
    { id = "main", label = "ROAG 1-BIT", path = "assets/kenney/Tilesheet/colored-transparent_packed.png", tile_width = 16, tile_height = 16, columns = 49, rows = 22 },
  },
  ["art_pack.loveable_rogue"] = {
    { id = "main", label = "LOVEABLE ROGUE", path = "assets/art_packs/loveable_rogue.png", tile_width = 16, tile_height = 16, columns = 64, rows = 64 },
  },
  ["art_pack.dawnlike"] = {
    { id = "player", label = "PLAYER", path = "assets/art_packs/dawnlike/Characters/Player0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 15 },
    { id = "humanoids", label = "HUMANOIDS", path = "assets/art_packs/dawnlike/Characters/Humanoid0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 27 },
    { id = "undead", label = "UNDEAD", path = "assets/art_packs/dawnlike/Characters/Undead0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 10 },
    { id = "quadrupeds", label = "QUADRUPEDS", path = "assets/art_packs/dawnlike/Characters/Quadraped0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 12 },
    { id = "reptiles", label = "REPTILES", path = "assets/art_packs/dawnlike/Characters/Reptile0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 15 },
    { id = "pests", label = "PESTS", path = "assets/art_packs/dawnlike/Characters/Pest0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 11 },
    { id = "elementals", label = "ELEMENTALS", path = "assets/art_packs/dawnlike/Characters/Elemental0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 11 },
    { id = "traps", label = "TRAPS", path = "assets/art_packs/dawnlike/Objects/Trap0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 5 },
    { id = "doors", label = "DOORS", path = "assets/art_packs/dawnlike/Objects/Door0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 6 },
    { id = "effects", label = "EFFECTS", path = "assets/art_packs/dawnlike/Objects/Effect0.png", tile_width = 16, tile_height = 16, columns = 8, rows = 26 },
    { id = "ammo", label = "AMMO", path = "assets/art_packs/dawnlike/Items/Ammo.png", tile_width = 16, tile_height = 16, columns = 8, rows = 6 },
    { id = "lights", label = "LIGHTS", path = "assets/art_packs/dawnlike/Items/Light.png", tile_width = 16, tile_height = 16, columns = 8, rows = 1 },
    { id = "rocks", label = "ROCKS", path = "assets/art_packs/dawnlike/Items/Rock.png", tile_width = 16, tile_height = 16, columns = 8, rows = 2 },
    { id = "floor", label = "FLOOR", path = "assets/art_packs/dawnlike/Objects/Floor.png", tile_width = 16, tile_height = 16, columns = 21, rows = 39 },
    { id = "walls", label = "WALLS", path = "assets/art_packs/dawnlike/Objects/Wall.png", tile_width = 16, tile_height = 16, columns = 20, rows = 51 },
  },
  ["art_pack.kenney_micro_roguelike"] = {
    { id = "main", label = "MICRO ROGUELIKE", path = "assets/art_packs/kenney_micro_roguelike/Tilemap/colored_tilemap_packed.png", tile_width = 8, tile_height = 8, columns = 16, rows = 10 },
  },
  ["art_pack.kenney_roguelike_indoors"] = {
    { id = "main", label = "INDOORS", path = "assets/art_packs/kenney_roguelike_indoors/Tilesheets/roguelikeIndoor_transparent.png", tile_width = 16, tile_height = 16, spacing = 1, columns = 27, rows = 18 },
  },
  ["art_pack.kenney_roguelike_modern_city"] = {
    { id = "main", label = "MODERN CITY", path = "assets/art_packs/kenney_roguelike_modern_city/Tilemap/tilemap_packed.png", tile_width = 16, tile_height = 16, columns = 37, rows = 28 },
  },
  ["art_pack.kenney_roguelike_caves_dungeons"] = {
    { id = "main", label = "CAVES & DUNGEONS", path = "assets/art_packs/kenney_roguelike_caves_dungeons/Spritesheet/roguelikeDungeon_transparent.png", tile_width = 16, tile_height = 16, spacing = 1, columns = 29, rows = 18 },
  },
  ["art_pack.kenney_roguelike_rpg_pack"] = {
    { id = "main", label = "RPG PACK", path = "assets/art_packs/kenney_roguelike_rpg_pack/Spritesheet/roguelikeSheet_transparent.png", tile_width = 16, tile_height = 16, columns = 57, rows = 31 },
  },
  ["art_pack.kenney_roguelike_characters"] = {
    { id = "main", label = "CHARACTERS", path = "assets/art_packs/kenney_roguelike_characters/Spritesheet/roguelikeChar_transparent.png", tile_width = 16, tile_height = 16, columns = 54, rows = 12 },
  },
}

function Sources.for_pack(pack)
  return pack and Sources.sheets[pack.id] or {}
end

return Sources
