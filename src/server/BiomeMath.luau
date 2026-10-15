--!strict
--[[
	BiomeMath
	=========
	The pure half of the biome events: which event a given moment belongs to, how
	long it has left, and the boost object the roll path consumes. BiomeConfig is
	the data; this file is the rules that read it.

	NO ROBLOX, NO CLOCK OF ITS OWN. Every function takes the elapsed time as an
	argument, so the schedule is executable in the terminal harness with an
	injected clock and cannot quietly depend on when the module loaded. RNGService
	owns the epoch (it already owns every other piece of server time) and passes
	`os.clock() - BIOME_EPOCH` in.

	WHERE THE BOOST ENTERS THE ROLL: nowhere in here. This module only RESOLVES the
	event into the shape RollMath already knows how to weigh
	(`{ id, multiplier, auraIds }`), and RNGService passes that object to
	`RollMath.SelectAura` - the single selection path - as one more weight factor
	beside luck and pity. There is no second selector, and no aura is special-cased
	anywhere outside BiomeConfig's own data.
]]

--[[
	Sibling loading, the same dual-runtime pattern AuraRegistry and RollMath use:
	Roblox resolves instances, Lune resolves a relative path. Written out rather
	than `require("./BiomeConfig")`, because a string require is not a thing in
	Roblox and the module would simply fail to load there.
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

	error(string.format("[BiomeMath] could not load sibling module %q", name), 2)
end

local BiomeConfig: any = loadSibling("BiomeConfig")

export type RGB = { r: number, g: number, b: number }

export type BiomeDefinition = {
	id: string,
	displayName: string,
	blurb: string,
	accent: RGB,
	auraIds: { string },
}

-- The shape RollMath consumes. `auraIds` is a SET because the roll path looks an
-- aura up per entry while building weights.
export type Boost = {
	id: string,
	multiplier: number,
	auraIds: { [string]: boolean },
	-- The themed rungs resolved from the LADDER: what the HUD lists and what the
	-- payload carries, so an event can only ever advertise real auras.
	rungs: { Rung },
}

export type Rung = {
	rarity: number,
	tier: string,
	auraId: string,
	displayName: string,
}

export type CycleState = {
	id: string,
	displayName: string,
	blurb: string,
	accent: RGB,
	index: number,
	cycleSeconds: number,
	multiplier: number,
	elapsedInCycle: number,
	secondsRemaining: number,
	progress: number,
}

-- Structural slice of AuraRegistry that the resolution needs.
export type RungSource = {
	ORDER: { string },
	Get: (string) -> any?,
}

local CONSTANTS = BiomeConfig.Constants
local BIOMES: { BiomeDefinition } = BiomeConfig.Biomes

local BiomeMath = {}

BiomeMath.Constants = CONSTANTS
BiomeMath.Biomes = BIOMES

function BiomeMath.CycleSeconds(): number
	return CONSTANTS.cycleSeconds
end

function BiomeMath.Multiplier(): number
	return CONSTANTS.multiplier
end

function BiomeMath.Count(): number
	return #BIOMES
end

-- The event ids in cycle order. The HUD is told the CURRENT one by the server and
-- never keeps a list of its own, so this exists for diagnostics and the harness.
function BiomeMath.Ids(): { string }
	local ids: { string } = table.create(#BIOMES)
	for _, biome in ipairs(BIOMES) do
		table.insert(ids, biome.id)
	end
	return ids
end

-- A duration that is not a usable number is "the cycle just started": total, so a
-- NaN clock cannot produce a NaN countdown on screen.
local function sanitizeElapsed(value: any): number
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return 0
	end
	return value
end

-- Which entry of the cycle this elapsed time falls in (1-based).
function BiomeMath.IndexAt(elapsedSeconds: number): number
	local count = #BIOMES
	if count <= 0 then
		return 0
	end

	local cycle = CONSTANTS.cycleSeconds
	if type(cycle) ~= "number" or cycle ~= cycle or cycle <= 0 then
		return 1
	end

	local elapsed = sanitizeElapsed(elapsedSeconds)
	local step = math.floor(elapsed / cycle)
	local offset = (CONSTANTS.startIndex - 1 + step) % count
	return offset + 1
end

--[[
	At(elapsedSeconds)

	The whole schedule for one moment: the event, how far into it we are and how
	long is left. Server-owned end to end - the client is handed this, never asked
	to compute it (see RNGService and the HUD).
]]
function BiomeMath.At(elapsedSeconds: number): CycleState
	local cycle = CONSTANTS.cycleSeconds
	if type(cycle) ~= "number" or cycle ~= cycle or cycle <= 0 then
		cycle = 1
	end

	local elapsed = sanitizeElapsed(elapsedSeconds)
	local index = BiomeMath.IndexAt(elapsed)
	local biome = BIOMES[index]
	if biome == nil then
		-- Only reachable with an empty BIOMES list; callers get a usable shape
		-- rather than a nil index crash in the middle of a roll.
		return {
			id = "",
			displayName = "",
			blurb = "",
			accent = { r = 255, g = 255, b = 255 },
			index = 0,
			cycleSeconds = cycle,
			multiplier = 1,
			elapsedInCycle = 0,
			secondsRemaining = cycle,
			progress = 0,
		}
	end

	local elapsedInCycle = elapsed % cycle
	return {
		id = biome.id,
		displayName = biome.displayName,
		blurb = biome.blurb,
		accent = biome.accent,
		index = index,
		cycleSeconds = cycle,
		multiplier = CONSTANTS.multiplier,
		elapsedInCycle = elapsedInCycle,
		secondsRemaining = cycle - elapsedInCycle,
		progress = elapsedInCycle / cycle,
	}
end

-- =============================================================================
-- Resolving the data against the ladder
-- =============================================================================

--[[
	Audit(source)

	Every problem with the biome data as a list of sentences, and NOTHING thrown:
	the harness runs this against the shipped config (asserting it is clean) and
	against deliberately broken ones (asserting each problem is caught).

	What counts as a problem:
	  * a biome with no themed rungs, which would be an event that does nothing;
	  * a themed id the ladder does not have (a typo, or a renamed aura);
	  * a rung claimed by two events, which would make an event's identity fuzzy;
	  * a repeated or empty biome id, which the payload and the client key on.
]]
function BiomeMath.Audit(source: RungSource): { string }
	local problems: { string } = {}
	local seenIds: { [string]: boolean } = {}
	local claimedBy: { [string]: string } = {}

	for _, biome in ipairs(BIOMES) do
		if type(biome.id) ~= "string" or biome.id == "" then
			table.insert(problems, "a biome has no id")
		elseif seenIds[biome.id] == true then
			table.insert(problems, string.format("biome id %q appears twice", biome.id))
		else
			seenIds[biome.id] = true
		end

		if type(biome.auraIds) ~= "table" or #biome.auraIds == 0 then
			table.insert(problems, string.format("biome %s themes no rungs", tostring(biome.id)))
		else
			for _, auraId in ipairs(biome.auraIds) do
				if source.Get(auraId) == nil then
					table.insert(
						problems,
						string.format("biome %s themes %q, which is not on the ladder", tostring(biome.id), tostring(auraId))
					)
				else
					local owner = claimedBy[auraId]
					if owner ~= nil then
						table.insert(
							problems,
							string.format("%s is themed by both %s and %s", tostring(auraId), owner, tostring(biome.id))
						)
					else
						claimedBy[auraId] = tostring(biome.id)
					end
				end
			end
		end
	end

	return problems
end

--[[
	Boosts(source)

	One Boost per biome, keyed by biome id, with the rungs resolved from the
	ladder (ascending rarity) so the HUD and the payload only ever name real auras.

	Raises on any Audit problem: a bad biome config must fail at load, loudly, the
	way a bad ladder does - not at 3am in the middle of a roll.
]]
function BiomeMath.Boosts(source: RungSource): { [string]: Boost }
	local problems = BiomeMath.Audit(source)
	if #problems > 0 then
		error("[BiomeMath] BiomeConfig: " .. table.concat(problems, "; "), 2)
	end

	local boosts: { [string]: Boost } = {}

	for _, biome in ipairs(BIOMES) do
		local auraIds: { [string]: boolean } = {}
		local rungs: { Rung } = {}

		for _, auraId in ipairs(biome.auraIds) do
			auraIds[auraId] = true

			local config = source.Get(auraId)
			if config ~= nil then
				table.insert(rungs, {
					rarity = (config :: any).rarity,
					tier = tostring((config :: any).tier or ""),
					auraId = auraId,
					displayName = tostring((config :: any).displayName or auraId),
				})
			end
		end

		table.sort(rungs, function(left: Rung, right: Rung): boolean
			return left.rarity < right.rarity
		end)

		boosts[biome.id] = {
			id = biome.id,
			multiplier = CONSTANTS.multiplier,
			auraIds = auraIds,
			rungs = rungs,
		}
	end

	return boosts
end

-- The boost for an id, or nil for an unknown one: the roll path stays total.
function BiomeMath.BoostFor(boosts: { [string]: Boost }, id: string?): Boost?
	if type(id) ~= "string" then
		return nil
	end
	return boosts[id]
end

return BiomeMath
