--!strict
--[[
	ShrineMath
	==========
	The pure half of the Luck Shrine: is a position inside the region, what does
	being inside do to the cooldown, and how do those two compose with the factors
	that already existed.

	NO ROBLOX, NO CLOCK OF ITS OWN. Every function takes its inputs as arguments -
	a point, a clock reading - so the whole thing is executable in the terminal
	harness and cannot quietly depend on when the module loaded or on a live
	character.

	WHY THE COMPOSITION LIVES HERE, of all places: the roll cooldown used to be
	`BASE * (fastRoll and perk or 1)` inline in RNGService. The shrine is a third
	source, and the one thing that must not happen is a second place deciding a
	cooldown. So the product moved into ONE pure function, `ComposeCooldown`, and
	RNGService's `cooldownFor` now only gathers the two factors (the pass
	entitlement and this player's zone state) and calls it. That is the single
	place the number is decided, and the harness executes it.

	THE ZONE TEST IS AN ARGUMENT, NEVER A CLAIM. `Contains` is handed a position by
	the SERVER (a character's own part). Nothing here reads a client, and no
	function in this module takes a player - which is the structural reason a
	client cannot talk itself into the bonus.
]]

--[[
	Sibling loading, the same dual-runtime pattern AuraRegistry, RollMath and
	BiomeMath use: Roblox resolves instances, Lune resolves a relative path.
	Written out rather than `require("./ShrineConfig")`, because a string require
	is not a thing in Roblox and the module would simply fail to load there.
]]
local function loadSibling(name: string): any
	local scriptGlobal: any = script
	if scriptGlobal ~= nil then
		local parent: any = scriptGlobal.Parent
		if parent ~= nil then
			local module: any = parent:FindFirstChild(name)
			if module ~= nil then
				return require(module)
			end
		end
	end

	local ok, module = pcall(require, "./" .. name)
	if ok and module ~= nil then
		return module
	end

	error(string.format("[ShrineMath] could not load sibling module %q", name), 2)
end

local ShrineConfig: any = loadSibling("ShrineConfig")

export type Vec3 = { x: number, y: number, z: number }

export type Region = {
	name: string,
	shape: string,
	origin: Vec3,
	size: Vec3,
	boundaryInclusive: boolean,
}

-- A position as the server reads it off a character. Roblox's Vector3 exposes
-- X/Y/Z; a plain table (the harness, a stub) may use either case, and `nil` means
-- "no character to read" - which is OUTSIDE, never inside. Fail closed: a stalled
-- or unavailable read must not pay a bonus.
export type Position = {
	X: number?, Y: number?, Z: number?,
	x: number?, y: number?, z: number?,
}

export type Sample = {
	inside: boolean,
	-- The clock reading the sample was taken at, or nil when there was nothing to
	-- read. Kept so a caller can show "in zone for N seconds" without a second read.
	at: number?,
}

-- The shape RNGService hands over: the pass entitlement already resolved to a
-- multiplier, plus this player's zone state.
--
-- THE TWO FACTORS ARE NOT THE SAME KIND OF NUMBER, and the field names say so.
-- `passMultiplier` scales the COOLDOWN (0.6 = 40% shorter waiting). The shrine
-- scales the RATE (1.15 = 15% more rolls per second), so it divides. Mixing those
-- up silently would be a different bonus; naming them apart is what stops it.
export type CooldownInputs = {
	base: number,
	-- 1 when no cooldown pass applies. The perk owns the number; this module only
	-- composes it.
	passMultiplier: number,
	inShrine: boolean,
	-- The floor. A product that would fall below it is clamped, so no combination
	-- of factors can reach a free roll.
	minimum: number,
}

local CONSTANTS = ShrineConfig.Constants
local REGION: Region = ShrineConfig.Region

local ShrineMath = {}

ShrineMath.Constants = CONSTANTS
ShrineMath.Region = REGION
ShrineMath.Display = ShrineConfig.Display

-- How much MORE OFTEN a player in the zone rolls: 1.15 = +15% roll speed. This
-- is a rate, and ComposeCooldown divides by it.
function ShrineMath.SpeedMultiplier(): number
	return CONSTANTS.rollSpeedMultiplier
end

-- The same mechanic stated as a cooldown factor (0.8696... = the cooldown while
-- inside is 87% of what it was outside). Derived, never authored, so the payload
-- and the HUD can quote either form and they cannot disagree.
function ShrineMath.CooldownMultiplier(): number
	local speed = CONSTANTS.rollSpeedMultiplier
	if type(speed) ~= "number" or speed ~= speed or speed <= 0 then
		return 1
	end
	return 1 / speed
end

-- The bonus as a percentage for the HUD, derived so the copy cannot drift from
-- the mechanic (+15% printed exactly because a rate of 1.15 is really applied).
function ShrineMath.BonusPercent(): number
	return math.floor((CONSTANTS.rollSpeedMultiplier - 1) * 100 + 0.5)
end

function ShrineMath.MinimumCooldown(): number
	return CONSTANTS.minimumCooldownSeconds
end

function ShrineMath.SampleInterval(): number
	return CONSTANTS.sampleIntervalSeconds
end

-- A number that can be used as a coordinate: finite, and not NaN. Anything else
-- (nil, a string, an infinity) is unreadable, which makes the sample OUTSIDE.
local function coordinate(value: any): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	local magnitude = math.abs(value)
	if magnitude == math.huge then
		return nil
	end
	return value
end

-- Roblox's Vector3 spells its components X/Y/Z; a plain table may use either.
local function axisOf(position: any, upper: string, lower: string): number?
	if type(position) ~= "table" then
		return nil
	end
	local value = coordinate(position[upper])
	if value ~= nil then
		return value
	end
	return coordinate(position[lower])
end

-- Every reader below goes through these two, because a config with a missing
-- `origin` or `size` must degrade to a zone at the world origin - not throw on a
-- line of arithmetic in the middle of a roll. The type says both are present;
-- the file is data, and data gets checked.
local function originOf(region: Region): Vec3
	local origin: any = region.origin
	if type(origin) ~= "table" then
		return { x = 0, y = 0, z = 0 }
	end
	return {
		x = coordinate(origin.x) or 0,
		y = coordinate(origin.y) or 0,
		z = coordinate(origin.z) or 0,
	}
end

local function sizeOf(region: Region): Vec3
	local size: any = region.size
	if type(size) ~= "table" then
		return { x = 0, y = 0, z = 0 }
	end
	return {
		x = coordinate(size.x) or 0,
		y = coordinate(size.y) or 0,
		z = coordinate(size.z) or 0,
	}
end

local function radiusOf(region: Region): number
	local size = sizeOf(region)
	return math.max(math.abs(size.x), math.abs(size.z)) / 2
end

local function heightOf(region: Region): number
	return math.abs(sizeOf(region).y)
end

--[[
	Contains(region, position)

	Whether a point is inside the region, with the boundary INCLUDED (see the
	convention in ShrineConfig): a player standing exactly on the rim counts as
	inside. `nil`, a malformed table or a non-finite coordinate is outside, so a
	failed read can never grant the bonus.

	Unknown shapes fall back to the cylinder test rather than throwing: a typo in
	the config must not take the roll path down for the whole server.
]]
function ShrineMath.Contains(region: Region, position: any): boolean
	if type(region) ~= "table" or type(position) ~= "table" then
		return false
	end

	local x = axisOf(position, "X", "x")
	local y = axisOf(position, "Y", "y")
	local z = axisOf(position, "Z", "z")
	if x == nil or y == nil or z == nil then
		return false
	end

	local origin = originOf(region)
	local shape = region.shape

	-- Every shape sits on origin.y and grows up, so the vertical test is shared.
	local height = heightOf(region)
	if shape ~= "sphere" then
		if y < origin.y or y > origin.y + height then
			return false
		end
	end

	if shape == "box" then
		local size = sizeOf(region)
		return math.abs(x - origin.x) <= math.abs(size.x) / 2
			and math.abs(z - origin.z) <= math.abs(size.z) / 2
	end

	if shape == "sphere" then
		local radius = radiusOf(region)
		local centreY = origin.y + height / 2
		local dx = x - origin.x
		local dy = y - centreY
		local dz = z - origin.z
		-- Compared squared: no sqrt, and the boundary stays inclusive.
		return (dx * dx + dy * dy + dz * dz) <= radius * radius
	end

	-- cylinder (and the safe default for anything unrecognised)
	local radius = radiusOf(region)
	local dx = x - origin.x
	local dz = z - origin.z
	return (dx * dx + dz * dz) <= radius * radius
end

--[[
	Sample(region, position, clock)

	One reading of the world: inside or not, and when it was taken. `position` is
	nil when the server has no character to read, and that is OUTSIDE - the shrine
	never pays for a read that did not happen.
]]
function ShrineMath.Sample(region: Region, position: any, clock: number?): Sample
	return { inside = ShrineMath.Contains(region, position), at = coordinate(clock) }
end

-- Convenience for the shipped region, so callers do not repeat it.
function ShrineMath.SampleHere(position: any, clock: number?): Sample
	return ShrineMath.Sample(REGION, position, clock)
end

--[[
	ComposeCooldown(inputs)

	THE single place a roll cooldown is decided. Three server-owned sources, one
	formula:

	    cooldown = base * passMultiplier / (inShrine and rollSpeedMultiplier or 1)

	clamped to the floor so no stack of factors can ever reach a free roll.

	THE ZONE CANNOT STACK WITH ITSELF. `inShrine` is a boolean, not a count: ten
	players in the zone, or one player standing in it for an hour, compose the same
	cooldown. There is exactly one division and no way to express "twice inside".

	Totality matters here: a damaged factor (a string, a NaN, a negative) degrades
	to "no bonus" rather than poisoning the cooldown into nonsense - and a rate
	below 1 degrades to 1, so a damaged config cannot make rolling SLOWER than the
	base either.
]]
function ShrineMath.ComposeCooldown(inputs: CooldownInputs): number
	local base = coordinate(inputs.base)
	if base == nil or base <= 0 then
		base = 0
	end

	local pass = coordinate(inputs.passMultiplier)
	if pass == nil or pass <= 0 then
		-- A multiplier that is missing or non-positive means "no discount", never
		-- "free" and never "slower than no pass at all".
		pass = 1
	end

	local cooldown = base * pass

	if inputs.inShrine == true then
		local speed = 1
		local configured = coordinate(ShrineMath.SpeedMultiplier())
		if configured ~= nil and configured >= 1 then
			speed = configured
		end
		-- Unreadable, or a zone that would slow the player down: neither is the
		-- shipped mechanic, so neither is applied silently.
		cooldown /= speed
	end

	local minimum = coordinate(inputs.minimum)
	if minimum == nil or minimum < 0 then
		minimum = CONSTANTS.minimumCooldownSeconds
	end
	if cooldown < minimum then
		cooldown = minimum
	end

	return cooldown
end

return ShrineMath
