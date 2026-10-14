--!strict
--[[
	AuraLadder
	==========
	The whole game's aura ladder as DATA: the 12 aura declarations and the tier
	bands that classify them. There are no functions and no branching in this
	file - if you are changing an aura's numbers, odds, palette or a tier's name
	and colour, this is the only file you need to touch.

	Two rules keep it useful:
	  * NO ROBLOX ACCESS. Colours are 0-255 integer triples and sizes are plain
	    { x, y, z } tables, so the ladder - and everything that reads it - stays
	    loadable from Lune / the Luau CLI for terminal testing.
	  * NO DERIVED DATA. `tier` and `tierColor` are deliberately absent from
	    AuraDeclaration: AuraRegistry computes them from `rarity` via TierBands,
	    which is what makes a rung's label and its odds impossible to desync.

	The ladder is one tier per rung: every declared rarity must fall in its own
	band below. AuraRegistry enforces that at load time and fails loudly.

	Consumers: AuraRegistry (index + tier policy + facade), AuraMaterializer
	(declarative config -> Roblox datatypes).
]]

export type RGB = { r: number, g: number, b: number }
export type XYZ = { x: number, y: number, z: number }

export type ShardShape = "Ball" | "Block" | "Cylinder" | "Wedge" | "CornerWedge"

--[[
	Everything a designer authors for one aura. `tier` and `tierColor` are
	deliberately absent: they are derived from `rarity`.
]]
export type AuraDeclaration = {
	-- ===== identity & odds =================================================
	id: string,
	displayName: string,
	rarity: number, -- "1 in rarity"

	-- ===== palette =========================================================
	primary: RGB,
	secondary: RGB,
	rim: RGB,

	-- ===== orbiting shard cluster ==========================================
	shardCount: number,
	shardShape: ShardShape,
	shardSize: XYZ,
	shardSpin: number, -- radians per second of per-shard self spin

	-- ===== orbit geometry (Lissajous / gyroscopic) ==========================
	orbitRadius: number,
	orbitHeight: number, -- vertical harmonic amplitude
	orbitSpeed: number, -- ring angular speed, radians per second
	tiltDegrees: number, -- ring plane tilt
	precessionSpeed: number, -- gyroscopic precession of the ring, radians/s
	harmonicFrequency: number, -- vertical harmonic frequency ratio
	harmonicRatioA: number, -- horizontal harmonic ratio
	lissajousAmplitude: number, -- orbit radius "breathing" amplitude

	-- ===== trail ==========================================================
	trailEnabled: boolean,
	trailLifetime: number,
	trailWidthStart: number,
	trailWidthEnd: number,
	trailTransparencyStart: number,
	trailLightEmission: number,

	-- ===== particle layers =================================================
	particleLayers: number, -- 2 or 3 layered emitters (the renderer clamps to 1..3)
	particleRate: number, -- particles/second for the core layer
	particleSpeedMin: number,
	particleSpeedMax: number,
	particleLifetimeMin: number,
	particleLifetimeMax: number,
	particleSizeStart: number,
	particleSizeEnd: number,
	particleTransparencyStart: number,
	particleSpread: number, -- degrees
	particleLightEmission: number,
	particleTexture: string,
	smokeTexture: string,

	-- ===== procedural light ================================================
	lightColor: RGB,
	lightRange: number,
	lightBrightness: number,

	-- ===== highlight ======================================================
	highlightFillTransparency: number,
	highlightOutlineTransparency: number,
	alwaysOnTop: boolean,

	-- ===== roll cutscene ==================================================
	cutsceneIntensity: number, -- 0..1, scales FOV punch + colour flash
	cutsceneShakeMagnitude: number, -- studs of camera shake
}

-- What the rest of the game reads: the authored fields plus derived tier data.
export type AuraConfig = AuraDeclaration & {
	tier: string,
	tierColor: RGB,
}

export type TierBand = {
	maxRarity: number,
	tier: string,
	color: RGB,
}

local TEX_SPARKLE: string = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_SMOKE: string = "rbxasset://textures/particles/smoke_main.dds"

local TIER_BANDS: { TierBand } = {
	{ maxRarity = 2, tier = "Common", color = { r = 176, g = 186, b = 200 } },
	{ maxRarity = 8, tier = "Uncommon", color = { r = 124, g = 222, b = 140 } },
	{ maxRarity = 15, tier = "Fabled", color = { r = 118, g = 224, b = 214 } },
	{ maxRarity = 50, tier = "Rare", color = { r = 104, g = 160, b = 255 } },
	{ maxRarity = 150, tier = "Arcane", color = { r = 150, g = 132, b = 255 } },
	{ maxRarity = 500, tier = "Epic", color = { r = 186, g = 124, b = 255 } },
	{ maxRarity = 1500, tier = "Ethereal", color = { r = 244, g = 140, b = 255 } },
	{ maxRarity = 5000, tier = "Legendary", color = { r = 255, g = 178, b = 72 } },
	{ maxRarity = 25000, tier = "Exalted", color = { r = 255, g = 132, b = 96 } },
	{ maxRarity = 100000, tier = "Mythic", color = { r = 255, g = 236, b = 160 } },
	{ maxRarity = 400000, tier = "Ascendant", color = { r = 255, g = 138, b = 196 } },
	{ maxRarity = 1000000, tier = "Sovereign", color = { r = 236, g = 246, b = 255 } },
}

local AURAS: { AuraDeclaration } = {
	{
		id = "Ember",
		displayName = "Ember",
		rarity = 2,

		primary = { r = 255, g = 122, b = 42 },
		secondary = { r = 128, g = 42, b = 12 },
		rim = { r = 255, g = 88, b = 0 },

		shardCount = 3,
		shardShape = "Block",
		shardSize = { x = 0.34, y = 0.34, z = 0.34 },
		shardSpin = 1.6,

		orbitRadius = 2.6,
		orbitHeight = 0.55,
		orbitSpeed = 1.4,
		tiltDegrees = 18,
		precessionSpeed = 0.35,
		harmonicFrequency = 3,
		harmonicRatioA = 1,
		lissajousAmplitude = 0.18,

		trailEnabled = true,
		trailLifetime = 0.35,
		trailWidthStart = 0.9,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.25,
		trailLightEmission = 0.8,

		particleLayers = 2,
		particleRate = 10,
		particleSpeedMin = 1.2,
		particleSpeedMax = 2.6,
		particleLifetimeMin = 0.45,
		particleLifetimeMax = 0.9,
		particleSizeStart = 0.32,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.25,
		particleSpread = 25,
		particleLightEmission = 0.6,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 255, g = 120, b = 40 },
		lightRange = 8,
		lightBrightness = 1.1,

		highlightFillTransparency = 0.85,
		highlightOutlineTransparency = 0.55,
		alwaysOnTop = false,

		cutsceneIntensity = 0.08,
		cutsceneShakeMagnitude = 0.05,
	},

	{
		id = "Frostbite",
		displayName = "Frostbite",
		rarity = 8,

		primary = { r = 150, g = 225, b = 255 },
		secondary = { r = 48, g = 110, b = 190 },
		rim = { r = 196, g = 244, b = 255 },

		shardCount = 5,
		shardShape = "Ball",
		shardSize = { x = 0.42, y = 0.42, z = 0.42 },
		shardSpin = 1.1,

		orbitRadius = 3.0,
		orbitHeight = 0.7,
		orbitSpeed = 1.7,
		tiltDegrees = 24,
		precessionSpeed = 0.45,
		harmonicFrequency = 4,
		harmonicRatioA = 1,
		lissajousAmplitude = 0.2,

		trailEnabled = true,
		trailLifetime = 0.32,
		trailWidthStart = 0.85,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.2,
		trailLightEmission = 0.85,

		particleLayers = 2,
		particleRate = 16,
		particleSpeedMin = 1.4,
		particleSpeedMax = 3.0,
		particleLifetimeMin = 0.5,
		particleLifetimeMax = 1.0,
		particleSizeStart = 0.4,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.2,
		particleSpread = 30,
		particleLightEmission = 0.8,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 140, g = 215, b = 255 },
		lightRange = 10,
		lightBrightness = 1.5,

		highlightFillTransparency = 0.78,
		highlightOutlineTransparency = 0.4,
		alwaysOnTop = false,

		cutsceneIntensity = 0.16,
		cutsceneShakeMagnitude = 0.08,
	},

	{
		id = "Static",
		displayName = "Static",
		rarity = 15,

		primary = { r = 168, g = 238, b = 255 },
		secondary = { r = 56, g = 120, b = 180 },
		rim = { r = 222, g = 250, b = 255 },

		shardCount = 6,
		shardShape = "Block",
		shardSize = { x = 0.3, y = 0.3, z = 0.9 },
		shardSpin = 2.0,

		orbitRadius = 3.05,
		orbitHeight = 0.6,
		orbitSpeed = 1.8,
		tiltDegrees = 20,
		precessionSpeed = 0.5,
		harmonicFrequency = 4,
		harmonicRatioA = 1,
		lissajousAmplitude = 0.2,

		trailEnabled = true,
		trailLifetime = 0.3,
		trailWidthStart = 0.4,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.18,
		trailLightEmission = 0.9,

		particleLayers = 2,
		particleRate = 21,
		particleSpeedMin = 1.5,
		particleSpeedMax = 3.2,
		particleLifetimeMin = 0.5,
		particleLifetimeMax = 1.05,
		particleSizeStart = 0.42,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.18,
		particleSpread = 32,
		particleLightEmission = 0.85,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 150, g = 220, b = 255 },
		lightRange = 11,
		lightBrightness = 1.7,

		highlightFillTransparency = 0.74,
		highlightOutlineTransparency = 0.35,
		alwaysOnTop = false,

		cutsceneIntensity = 0.2,
		cutsceneShakeMagnitude = 0.1,
	},

	{
		id = "Voidwalker",
		displayName = "Voidwalker",
		rarity = 50,

		primary = { r = 128, g = 52, b = 214 },
		secondary = { r = 26, g = 4, b = 46 },
		rim = { r = 178, g = 88, b = 255 },

		shardCount = 8,
		shardShape = "Wedge",
		shardSize = { x = 0.72, y = 0.55, z = 0.72 },
		shardSpin = 2.2,

		orbitRadius = 3.4,
		orbitHeight = 0.95,
		orbitSpeed = 2.0,
		tiltDegrees = 32,
		precessionSpeed = 0.62,
		harmonicFrequency = 5,
		harmonicRatioA = 1,
		lissajousAmplitude = 0.26,

		trailEnabled = true,
		trailLifetime = 0.4,
		trailWidthStart = 1.0,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.15,
		trailLightEmission = 1,

		particleLayers = 2,
		particleRate = 26,
		particleSpeedMin = 1.8,
		particleSpeedMax = 3.6,
		particleLifetimeMin = 0.6,
		particleLifetimeMax = 1.2,
		particleSizeStart = 0.5,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.15,
		particleSpread = 35,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 130, g = 60, b = 220 },
		lightRange = 13,
		lightBrightness = 2.0,

		highlightFillTransparency = 0.7,
		highlightOutlineTransparency = 0.25,
		alwaysOnTop = false,

		cutsceneIntensity = 0.32,
		cutsceneShakeMagnitude = 0.14,
	},

	{
		id = "Bloom",
		displayName = "Bloom",
		rarity = 150,

		primary = { r = 138, g = 255, b = 178 },
		secondary = { r = 122, g = 62, b = 190 },
		rim = { r = 208, g = 255, b = 222 },

		shardCount = 9,
		shardShape = "Ball",
		shardSize = { x = 0.38, y = 0.38, z = 0.38 },
		shardSpin = 1.9,

		orbitRadius = 3.6,
		orbitHeight = 0.78,
		orbitSpeed = 2.12,
		tiltDegrees = 27,
		precessionSpeed = 0.55,
		harmonicFrequency = 4,
		harmonicRatioA = 1,
		lissajousAmplitude = 0.23,

		trailEnabled = true,
		trailLifetime = 0.36,
		trailWidthStart = 0.5,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.13,
		trailLightEmission = 1,

		particleLayers = 2,
		particleRate = 31,
		particleSpeedMin = 1.9,
		particleSpeedMax = 3.9,
		particleLifetimeMin = 0.65,
		particleLifetimeMax = 1.3,
		particleSizeStart = 0.52,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.13,
		particleSpread = 38,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 135, g = 240, b = 175 },
		lightRange = 14,
		lightBrightness = 2.2,

		highlightFillTransparency = 0.67,
		highlightOutlineTransparency = 0.22,
		alwaysOnTop = false,

		cutsceneIntensity = 0.4,
		cutsceneShakeMagnitude = 0.17,
	},

	{
		id = "Chronos",
		displayName = "Chronos",
		rarity = 500,

		primary = { r = 255, g = 206, b = 92 },
		secondary = { r = 54, g = 214, b = 196 },
		rim = { r = 255, g = 238, b = 158 },

		shardCount = 10,
		shardShape = "Cylinder",
		shardSize = { x = 0.26, y = 0.26, z = 0.95 },
		shardSpin = 2.8,

		orbitRadius = 3.9,
		orbitHeight = 1.1,
		orbitSpeed = 2.3,
		tiltDegrees = 40,
		precessionSpeed = 0.8,
		harmonicFrequency = 6,
		harmonicRatioA = 2,
		lissajousAmplitude = 0.3,

		trailEnabled = true,
		trailLifetime = 0.45,
		trailWidthStart = 1.05,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.12,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 38,
		particleSpeedMin = 2.0,
		particleSpeedMax = 4.2,
		particleLifetimeMin = 0.7,
		particleLifetimeMax = 1.4,
		particleSizeStart = 0.55,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.12,
		particleSpread = 45,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 255, g = 214, b = 110 },
		lightRange = 16,
		lightBrightness = 2.5,

		highlightFillTransparency = 0.62,
		highlightOutlineTransparency = 0.18,
		alwaysOnTop = false,

		cutsceneIntensity = 0.52,
		cutsceneShakeMagnitude = 0.22,
	},

	{
		id = "Sunflare",
		displayName = "Sunflare",
		rarity = 1500,

		primary = { r = 255, g = 168, b = 60 },
		secondary = { r = 255, g = 246, b = 206 },
		rim = { r = 255, g = 214, b = 140 },

		shardCount = 12,
		shardShape = "Cylinder",
		shardSize = { x = 0.2, y = 0.2, z = 1.1 },
		shardSpin = 3.1,

		orbitRadius = 4.0,
		orbitHeight = 1.05,
		orbitSpeed = 2.45,
		tiltDegrees = 37,
		precessionSpeed = 0.72,
		harmonicFrequency = 6,
		harmonicRatioA = 2,
		lissajousAmplitude = 0.29,

		trailEnabled = true,
		trailLifetime = 0.5,
		trailWidthStart = 0.3,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.1,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 44,
		particleSpeedMin = 2.1,
		particleSpeedMax = 4.4,
		particleLifetimeMin = 0.75,
		particleLifetimeMax = 1.5,
		particleSizeStart = 0.58,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.11,
		particleSpread = 47,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 255, g = 190, b = 90 },
		lightRange = 17,
		lightBrightness = 2.7,

		highlightFillTransparency = 0.6,
		highlightOutlineTransparency = 0.15,
		alwaysOnTop = false,

		cutsceneIntensity = 0.62,
		cutsceneShakeMagnitude = 0.26,
	},

	{
		id = "AstralTempest",
		displayName = "Astral Tempest",
		rarity = 5000,

		primary = { r = 86, g = 164, b = 255 },
		secondary = { r = 238, g = 248, b = 255 },
		rim = { r = 150, g = 206, b = 255 },

		shardCount = 14,
		shardShape = "Block",
		shardSize = { x = 0.44, y = 0.44, z = 0.44 },
		shardSpin = 3.4,

		orbitRadius = 4.5,
		orbitHeight = 1.35,
		orbitSpeed = 2.7,
		tiltDegrees = 48,
		precessionSpeed = 1.0,
		harmonicFrequency = 7,
		harmonicRatioA = 2,
		lissajousAmplitude = 0.36,

		trailEnabled = true,
		trailLifetime = 0.5,
		trailWidthStart = 1.15,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.1,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 52,
		particleSpeedMin = 2.2,
		particleSpeedMax = 5.0,
		particleLifetimeMin = 0.8,
		particleLifetimeMax = 1.6,
		particleSizeStart = 0.62,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.1,
		particleSpread = 50,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 110, g = 180, b = 255 },
		lightRange = 20,
		lightBrightness = 3.1,

		highlightFillTransparency = 0.55,
		highlightOutlineTransparency = 0.12,
		alwaysOnTop = false,

		cutsceneIntensity = 0.75,
		cutsceneShakeMagnitude = 0.32,
	},

	{
		id = "Nebula",
		displayName = "Nebula",
		rarity = 25000,

		primary = { r = 176, g = 116, b = 255 },
		secondary = { r = 58, g = 220, b = 255 },
		rim = { r = 226, g = 196, b = 255 },

		shardCount = 16,
		shardShape = "CornerWedge",
		shardSize = { x = 0.5, y = 0.5, z = 0.5 },
		shardSpin = 3.9,

		orbitRadius = 4.6,
		orbitHeight = 1.42,
		orbitSpeed = 2.9,
		tiltDegrees = 50,
		precessionSpeed = 1.05,
		harmonicFrequency = 7,
		harmonicRatioA = 2,
		lissajousAmplitude = 0.38,

		trailEnabled = true,
		trailLifetime = 0.55,
		trailWidthStart = 0.55,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.08,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 58,
		particleSpeedMin = 2.4,
		particleSpeedMax = 5.2,
		particleLifetimeMin = 0.9,
		particleLifetimeMax = 1.8,
		particleSizeStart = 0.66,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.08,
		particleSpread = 52,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 170, g = 140, b = 255 },
		lightRange = 22,
		lightBrightness = 3.4,

		highlightFillTransparency = 0.5,
		highlightOutlineTransparency = 0.1,
		alwaysOnTop = true,

		cutsceneIntensity = 0.86,
		cutsceneShakeMagnitude = 0.38,
	},

	{
		id = "CelestialSingularity",
		displayName = "Celestial Singularity",
		rarity = 100000,

		primary = { r = 255, g = 242, b = 196 },
		secondary = { r = 176, g = 126, b = 255 },
		rim = { r = 255, g = 255, b = 232 },

		shardCount = 20,
		shardShape = "CornerWedge",
		shardSize = { x = 0.6, y = 0.6, z = 0.6 },
		shardSpin = 4.2,

		orbitRadius = 5.2,
		orbitHeight = 1.6,
		orbitSpeed = 3.1,
		tiltDegrees = 56,
		precessionSpeed = 1.25,
		harmonicFrequency = 8,
		harmonicRatioA = 3,
		lissajousAmplitude = 0.44,

		trailEnabled = true,
		trailLifetime = 0.6,
		trailWidthStart = 1.35,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.06,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 70,
		particleSpeedMin = 2.6,
		particleSpeedMax = 6.0,
		particleLifetimeMin = 1.0,
		particleLifetimeMax = 2.0,
		particleSizeStart = 0.7,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.06,
		particleSpread = 60,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 255, g = 246, b = 210 },
		lightRange = 26,
		lightBrightness = 4.0,

		highlightFillTransparency = 0.42,
		highlightOutlineTransparency = 0.04,
		alwaysOnTop = true,

		cutsceneIntensity = 1.0,
		cutsceneShakeMagnitude = 0.45,
	},

	{
		id = "Transcendence",
		displayName = "Transcendence",
		rarity = 400000,

		primary = { r = 255, g = 214, b = 236 },
		secondary = { r = 255, g = 170, b = 120 },
		rim = { r = 255, g = 246, b = 255 },

		shardCount = 22,
		shardShape = "Block",
		shardSize = { x = 0.46, y = 0.46, z = 0.46 },
		shardSpin = 4.5,

		orbitRadius = 5.5,
		orbitHeight = 1.55,
		orbitSpeed = 3.25,
		tiltDegrees = 54,
		precessionSpeed = 1.18,
		harmonicFrequency = 8,
		harmonicRatioA = 3,
		lissajousAmplitude = 0.42,

		trailEnabled = true,
		trailLifetime = 0.58,
		trailWidthStart = 0.5,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.05,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 72,
		particleSpeedMin = 2.6,
		particleSpeedMax = 6.2,
		particleLifetimeMin = 1.0,
		particleLifetimeMax = 2.0,
		particleSizeStart = 0.72,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.05,
		particleSpread = 63,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 255, g = 200, b = 220 },
		lightRange = 29,
		lightBrightness = 4.2,

		highlightFillTransparency = 0.4,
		highlightOutlineTransparency = 0.03,
		alwaysOnTop = true,

		cutsceneIntensity = 1.0,
		cutsceneShakeMagnitude = 0.48,
	},

	{
		id = "Sovereign",
		displayName = "Sovereign",
		rarity = 1000000,

		primary = { r = 255, g = 250, b = 226 },
		secondary = { r = 255, g = 206, b = 120 },
		rim = { r = 255, g = 255, b = 246 },

		shardCount = 26,
		shardShape = "CornerWedge",
		shardSize = { x = 0.56, y = 0.56, z = 0.56 },
		shardSpin = 5.0,

		orbitRadius = 5.6,
		orbitHeight = 1.75,
		orbitSpeed = 3.3,
		tiltDegrees = 60,
		precessionSpeed = 1.35,
		harmonicFrequency = 9,
		harmonicRatioA = 3,
		lissajousAmplitude = 0.46,

		trailEnabled = true,
		trailLifetime = 0.62,
		trailWidthStart = 0.62,
		trailWidthEnd = 0,
		trailTransparencyStart = 0.03,
		trailLightEmission = 1,

		particleLayers = 3,
		particleRate = 88,
		particleSpeedMin = 2.8,
		particleSpeedMax = 6.6,
		particleLifetimeMin = 1.1,
		particleLifetimeMax = 2.0,
		particleSizeStart = 0.78,
		particleSizeEnd = 0,
		particleTransparencyStart = 0.03,
		particleSpread = 66,
		particleLightEmission = 1,
		particleTexture = TEX_SPARKLE,
		smokeTexture = TEX_SMOKE,

		lightColor = { r = 255, g = 246, b = 214 },
		lightRange = 32,
		lightBrightness = 4.4,

		highlightFillTransparency = 0.37,
		highlightOutlineTransparency = 0.03,
		alwaysOnTop = true,

		cutsceneIntensity = 1.0,
		cutsceneShakeMagnitude = 0.5,
	},
}

local AuraLadder = {}

AuraLadder.Auras = AURAS
AuraLadder.TierBands = TIER_BANDS

return AuraLadder
