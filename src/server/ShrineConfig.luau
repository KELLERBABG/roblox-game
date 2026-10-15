--!strict
--[[
	ShrineConfig
	============
	The Luck Shrine as DATA: where its region is, what shape it is, and what
	standing inside it is worth. No functions and no branching - moving the shrine
	or retuning it is one edit here.

	Same two rules as AuraLadder and BiomeConfig, for the same reasons:
	  * NO ROBLOX ACCESS. The origin and size are plain numbers and the accent is a
	    0-255 triple, so this file - and everything that reads it - stays loadable
	    from Lune and executable in the terminal harness.
	  * NO GEOMETRY. This file says where the ZONE is, never what it looks like.
	    The Visuals workstream owns Models and the world layer, and it builds to
	    these numbers; nothing here spawns a part, a light or a decal.

	THE REGION CONVENTION (this is the whole geometry contract):

	  * `origin` is a point on the FLOOR. The zone sits ON origin and grows UP, so
	    origin.y is the walkable surface the region is measured from.
	  * cylinder axis vertical: disc centre = origin, radius = size.x / 2, spanning
	    y from origin.y to origin.y + size.y. size.x and size.z are the diameter.
	  * box: size.x / size.z are full extents centred on origin.x / origin.z, and
	    size.y is the height above origin.y.
	  * sphere: radius = size.x / 2, centre = origin + (0, size.y / 2, 0).
	  * THE BOUNDARY BELONGS TO THE ZONE: standing exactly on the rim counts as
	    inside. ShrineMath compares with `<=`, and the harness pins that at the
	    exact edge - "on the line" has to have one answer, and this is it.

	WHERE IT IS: the south-west quadrant of the sanctuary plaza (this repo's world
	layer reads -z as north and +x as east). The plaza floor spans 172x172 with its
	surface at y = 0, and the other three quadrants already hold the Stargazer's
	Spire deck, the Astral Waterfall and the Mystic Grotto. The only geometry within
	25 studs of this origin is `Lawn_SW` - a flat 58x58 slab centred (-48, 0.3, 48)
	whose walkable top is y = 0.6, inside this zone's 0 .. 26 span - so a pedestal
	fits here without moving or clipping anything. The measurement and the resulting
	contract live in ARCHITECTURE.md ("The Luck Shrine and the Top Rollers board");
	this file stays the numbers.
]]

export type Vec3 = { x: number, y: number, z: number }

export type Region = {
	name: string,
	-- "cylinder" | "box" | "sphere" - see the convention above.
	shape: string,
	origin: Vec3,
	size: Vec3,
	-- True: the rim counts as inside (the shipped rule, and what ShrineMath does).
	boundaryInclusive: boolean,
}

export type ShrineConstants = {
	--[[
		WHAT BEING INSIDE IS WORTH, as a RATE rather than a discount: while inside,
		a player rolls 1.15 times as often - the mission's "+15% Roll Speed", read
		literally. The cooldown is therefore DIVIDED by it (1.2s -> 1.043s), which is
		+15% rolls per second; a cooldown of "minus 15%" would have been a different,
		larger bonus (+17.6% speed) wearing the same word.

		Kept as one named factor rather than as a percentage so the arithmetic lives
		in ShrineMath.ComposeCooldown and nowhere else, and so retuning the shrine is
		this one number. A value below 1 would mean a zone that slows you down; the
		composer treats anything unreadable or below 1 as "no bonus" rather than as
		a penalty, because a damaged factor must never make a roll worse.
	]]
	rollSpeedMultiplier: number,
	-- How often the server re-reads every character's position, for the HUD readout
	-- and the player attributes. A display cadence, NOT the roll's source of truth:
	-- the roll path re-reads the character itself (see RNGService.cooldownFor), so
	-- a player who teleports is honoured on the very next roll rather than up to one
	-- sample later.
	sampleIntervalSeconds: number,
	-- The floor under the composed cooldown, whatever the factors do. 0.15s is the
	-- invoke rate limit the client already lives under, and it is what makes a free
	-- roll unreachable even if a future perk multiplies the cooldown down.
	minimumCooldownSeconds: number,
}

export type ShrineDisplay = {
	displayName: string,
	blurb: string,
	accent: { r: number, g: number, b: number },
}

local CONSTANTS: ShrineConstants = {
	rollSpeedMultiplier = 1.15,
	sampleIntervalSeconds = 0.5,
	minimumCooldownSeconds = 0.15,
}

local REGION: Region = {
	name = "LuckShrine",
	shape = "cylinder",
	origin = { x = -46, y = 0, z = 46 },
	size = { x = 30, y = 26, z = 30 },
	boundaryInclusive = true,
}

local DISPLAY: ShrineDisplay = {
	displayName = "LUCK SHRINE",
	-- The percentage is derived from `rollSpeedMultiplier` by ShrineMath (see
	-- BonusPercent), so this copy cannot drift from the mechanic.
	blurb = "Stand inside to roll 15% faster.",
	accent = { r = 255, g = 214, b = 140 },
}

local ShrineConfig = {}

ShrineConfig.Region = REGION
ShrineConfig.Constants = CONSTANTS
ShrineConfig.Display = DISPLAY

return ShrineConfig
