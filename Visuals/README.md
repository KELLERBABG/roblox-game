# Visuals & World Suite (Sol's RNG Inspired)

A zero-asset, 100% procedural world generator, visual VFX engine, audio system, and Design Atlas in-game interface built for Roblox RNG / Idle Aura games.

---

## 🌟 Overview

The `Visuals` package lives inside `ReplicatedStorage.Visuals` with server/client bootstrap hooks in `ServerScriptService.VisualsServer` and `StarterPlayer.StarterPlayerScripts.VisualsClient`. It is architected to run immediately on an empty Baseplate with **zero pre-existing ScreenGuis, meshes, or manual Studio setup**.

---

## 📁 Package Architecture

```
Visuals/
├── init.luau             -- Central entry point: CreateFullAuraVFX, UpdateFullAuraVFX, PlayCutscene
├── AuraCatalog.luau      -- 66 comprehensive Sol's RNG-inspired auras spanning 9 rarity tiers
├── HUD.luau              -- Design Atlas in-game interface (Pity Bar, Dock, Reveal Card, 66-Aura Codex)
├── ProceduralModels.luau  -- Seraph Wings, Crystal Crown, Gimbal Rings, Orbital Belts, Matrix Cubes
├── FloorRings.luau        -- Terrain-projected summoning seals & runes (Flame, Frost, Chronos, Celestial, etc.)
├── Beams.luau             -- Vertical light columns, dual-helix spirals, and celestial god rays
├── Shockwaves.luau        -- Expanding neon blast rings and radial particle bursts
├── Decals.luau            -- Color/Number sequence builders, particle presets, and engine texture catalogs
├── Audio.luau             -- Rapid roll ticking, fanfare reveals (Common to Singularity), sub-bass drops
├── World/
│   ├── init.luau         -- Unified world orchestrator: Build, StartClientAmbience, EnsureWorld
│   ├── Builder.luau      -- Physical floating island, altar, spire, grotto, obby, and spawn point
│   ├── Foliage.luau      -- Procedural sakura trees with falling petals, stone lanterns, crystal clusters
│   ├── Atmosphere.luau   -- Midnight cosmic sky, atmospheric haze, bloom glow, and shooting stars
│   ├── Interactive.luau  -- Alchemist's Cauldron (+0.5x Luck), Peak of Fortune (+1.0x Luck), Altar pulse
│   └── Ambience.luau     -- 3D positional audio loops (celestial drone, bubbling brew, water splashes)
├── Server/
│   └── WorldBootstrap.server.luau  -- Server-side world generator running on startup
└── Client/
    └── WorldClient.client.luau     -- Client-side environmental lighting and shooting star controller
```

---

## 🏝️ The Procedural World: "Sol's Sanctuary"

Generated 100% procedurally on startup without requiring pre-made Studio assets:
1. **The Floating Celestial Island**:
   - Polished white marble plaza with stone perimeter rims and grass lawn terraces.
   - Massive natural jagged slate rock underbelly with inverted stalactite formations.
2. **The Central Sacred Roll Altar**:
   - 3-tier elevated circular marble dais with steps.
   - 4 Olympian marble columns topped with glowing neon capitals.
   - Concentric glowing summoning ring that pulses in sync with roll reveals.
   - Hovering central neon monolith crystal.
3. **The Stargazer's Spire (Celestial Orrery)**:
   - Elevated slate cliff with grand marble staircase.
   - Giant procedural brass Armillary Sphere (Astrolabe) with concentric rotating neon planetary rings.
4. **The Mystic Grotto (Crystal Cave)**:
   - Hollow cavern framed by dark slate arches.
   - Glowing amethyst and emerald crystal geodes.
   - Alchemist's Cauldron simmering with glowing potion liquid; stepping in grants **+0.5x Luck Bonus**!
5. **The Floating Stepping Stones (Parkour Obby)**:
   - 12 drifting stone discs with neon guidance rims suspended over the void.
   - Leads to the **Peak of Fortune** platform with a golden treasure altar granting **+1.0x Luck Bonus** and victory spark bursts!
6. **Bioluminescent Sakura Grove & Flora**:
   - Procedural cherry blossom trees with falling petal particle emitters.
   - Ancient stone lanterns with warm glowing flames along walkways.
   - Luminous crystal clusters around altar borders.
7. **Cosmic Atmosphere & Dynamic Lighting**:
   - Midnight deep-space lighting with purple/blue nebula haze.
   - High-contrast bloom and color correction.
   - Automated shooting star streaks darting across the sky.

---

## 💎 The 66 Auras (9 Rarity Tiers)

| Tier | Rarity Range | Count | Examples | Special Visuals |
| :--- | :--- | :---: | :--- | :--- |
| **Common** | 1 in 2 – 1 in 8 | 6 | Ember, Cinder, Breeze, Pebble, Dewdrop, Frostbite | Subtle orbiting shards, gentle sparks |
| **Uncommon** | 1 in 12 – 1 in 45 | 8 | Blossom, Flare, Quake, Torrent, Topaz, Amethyst, Gilded | Dual-layer particles, flame/water wisps |
| **Rare** | 1 in 50 – 1 in 250 | 8 | Voidwalker, Poison, Ruby, Emerald, Sapphire, Wind, Lightning, Bounded | Void rifts, pentagram runes, neon trails |
| **Epic** | 1 in 300 – 1 in 950 | 8 | Chronos, Rage, Undead, Aquatic, Glacier, Starlight, Eclipse, Magnetic | Rotating gear seals, crystal crowns, orbital belts |
| **Legendary** | 1 in 1,000 – 1 in 9,500 | 8 | Astral Tempest, Solar, Lunar, Hades, Poseidon, Zeus, Glitch, Kyawthuite | Light pillars, matrix cubes, camera shake |
| **Mythic** | 1 in 10,000 – 1 in 95,000 | 8 | Twilight, Celestial, Starscourge, Virtual, Matrix, Nautilus, Permafrost, Flushed | Double-helix beams, sacred halos, choir fanfares |
| **Cosmic** | 1 in 100,000 – 1 in 950,000 | 8 | Celestial Singularity, Arcane, Chromatic, Gargantua, Gravitational, Bloodlust, Subzero, Corrosive | Gyroscopic gimbal rings, cosmic nebula seals, screen tint |
| **Transcendent** | 1 in 1M – 1 in 9.5M | 6 | Archangel, Abyssal Hunter, Symphony, Overture, Ruins, Sovereign | 12 Seraph wings, celestial god rays, time-stop flash |
| **Singularity** | 1 in 15M – 1 in 100M | 4 | Genesis, Oblivion, Apex Singularity, Omniscience | Gravitational collapse, universe-tear audio, omni-glow |

---

## 🎨 Design Atlas In-Game Interface (`Visuals.HUD`)

Crafted using the **Design Atlas** cinematic product & HUD archetype:
1. **Glassmorphic Top Pity & Luck Multiplier Bar**:
   - High-contrast progression rail with glowing soft-pity indicator.
   - Real-time roll count, active luck multiplier chip (`1.00x`), and discovery counter (`X/66`).
2. **Interactive Bottom Action Dock**:
   - `ROLL` action button with tactile spring bounce and cooldown gauge.
   - `AUTO ROLL` toggle with pulsating emerald indicator.
   - `FAST 2x` simulated pass toggle with amber glow.
   - `LOW VFX` toggle to pause background particles for AFK farming.
   - `COLLECTION` button toggling the 66-Aura Codex modal.
3. **Cinematic Center Reveal Card**:
   - Spring pop scale animation (`0.72 -> 1.08 -> 1.0`).
   - Glowing tier badge with wide uppercase tracking.
   - Giant typography for aura name with tier-colored primary stroke.
   - Subtitle / lore text and "1 IN N" odds badge.
4. **66-Aura Collection Codex (Bento-Grid)**:
   - Full scrollable modal organizing all 66 auras in ascending order of rarity.
   - Locked auras appear as sleek dark silhouettes with mystery status.
   - Unlocked auras display full color accents, ownership count (`OWNED x5`), and one-click `EQUIP` button.
5. **Global Pull Announcement Banner**:
   - Slides down from top with back-easing spring tween on any 1,000+ rarity pull.
