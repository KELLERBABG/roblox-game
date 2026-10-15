--!strict
--[[
	BiomeConfig
	===========
	The time-gated biome events as DATA: how long one lasts, how much it boosts,
	which rungs it favours, and the palette the HUD tints it with. There are no
	functions and no branching in this file - if you are retuning an event, this is
	the only file you need to touch.

	Same two rules as AuraLadder, for the same reasons:
	  * NO ROBLOX ACCESS. Colours are 0-255 integer triples, so this file - and
	    everything that reads it - stays loadable from Lune for terminal testing.
	  * NO DERIVED DATA. A biome names its rungs by AURA ID and nothing else. The
	    display names, tiers and odds a player sees are resolved from the ladder at
	    load (BiomeMath), so an event can never advertise an aura the game does not
	    have, and renaming an aura cannot leave stale copy here.

	ONE MULTIPLIER FOR ALL THREE EVENTS, on purpose: "the event triples its rungs"
	is the rule. A per-event multiplier would be three balance knobs dressed up as
	one, and the harness could no longer assert the rule in one sentence.

	WHY THESE SETS (the reading, not an assumption - see the report for the two
	links that are colour-mapped rather than conceptual):

	  Starfall     solar / storm / cosmic / regal - the late-game event. Its
	               cheapest boosted rung is 1 in 1500, so it pays the players who
	               already reach the mid rungs, and it owns the game's ceiling.
	  Blood Moon   fire at the floor, the violet dark, and coral ascension. This
	               is the early event: its themed rungs include the pool's most
	               common aura, so a new player SEES the event happen.
	  Void Eclipse cold, crackling and time-distorted - the early-mid event
	               (1 in 8 through 1 in 500).

	Every rung belongs to exactly one event, and BiomeMath refuses to load a config
	where that is not true.
]]

export type RGB = { r: number, g: number, b: number }

export type BiomeDefinition = {
	id: string,
	displayName: string,
	-- One line the HUD can show verbatim, so the panel never invents its own copy
	-- for an event - the same rule the shop follows for perk descriptions.
	blurb: string,
	accent: RGB,
	-- Themed rungs, by aura id. Membership only: order and labels come from the
	-- ladder, so reordering this list changes nothing a player can see.
	auraIds: { string },
}

export type BiomeConstants = {
	cycleSeconds: number,
	multiplier: number,
	startIndex: number,
}

local CONSTANTS: BiomeConstants = {
	-- Five minutes per event, cycling through BIOMES in order, forever. The server
	-- runs this from its own start clock, so every player in the server sees the
	-- same event at the same moment.
	cycleSeconds = 300,

	-- Every themed rung's WEIGHT is multiplied by this (not its probability: the
	-- pool normalises afterwards, which is what keeps a 3x weight a 3x weight).
	multiplier = 3,

	-- The cycle opens on the first entry below.
	startIndex = 1,
}

local BIOMES: { BiomeDefinition } = {
	{
		id = "Starfall",
		displayName = "STARFALL",
		blurb = "The sky is coming down - solar, storm and cosmic rungs are favoured.",
		accent = { r = 255, g = 214, b = 140 },
		auraIds = { "Sunflare", "AstralTempest", "Nebula", "CelestialSingularity", "Sovereign" },
	},
	{
		id = "BloodMoon",
		displayName = "BLOOD MOON",
		blurb = "A crimson moon - fire, the violet dark and coral ascension are favoured.",
		accent = { r = 255, g = 96, b = 96 },
		auraIds = { "Ember", "Voidwalker", "Transcendence" },
	},
	{
		id = "VoidEclipse",
		displayName = "VOID ECLIPSE",
		blurb = "The light goes out - cold, crackling and distorted time are favoured.",
		accent = { r = 168, g = 132, b = 255 },
		auraIds = { "Frostbite", "Static", "Bloom", "Chronos" },
	},
}

local BiomeConfig = {}

BiomeConfig.Constants = CONSTANTS
BiomeConfig.Biomes = BIOMES

return BiomeConfig
