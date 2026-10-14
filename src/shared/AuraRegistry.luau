--!strict
--[[
	AuraRegistry
	============
	The public face of the aura ladder, and the only module consumers need. It
	turns AuraLadder's raw declarations into three derived things, once, at load:

	  * REGISTRY        - id -> config, with `tier` and `tierColor` attached.
	                      Both are DERIVED from `rarity` through the single
	                      AuraLadder.TierBands table and are never authored, so a
	                      rung's label can never disagree with its odds.
	  * ORDER           - every id, ascending rarity. Grids, odds tables and
	                      pickers iterate this instead of keeping a list.
	  * Count/HighestRarity - the ladder's size and its ceiling.

	It also owns the ladder's INTEGRITY GUARD: a load-time error if two rungs
	claim the same rarity or derive the same tier, so a bad ladder edit fails
	loudly instead of silently mislabelling an aura.

	Data flow, one direction only:

	    AuraLadder (data)
	        -> AuraRegistry (index + tier policy, this file)
	        -> AuraMaterializer (config -> Roblox datatypes)
	        -> RollMath / MainUI / RNGService / any renderer

	Nothing here touches Roblox datatypes at module scope. `Materialize` and
	`ToColor3` are thin delegations to AuraMaterializer so callers keep needing
	only one import.
]]

local function loadSibling(name: string): any
	-- Roblox resolves siblings as instances; Lune resolves the relative path.
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

	error(string.format("[AuraRegistry] could not load sibling module %q", name), 2)
end

-- The annotation is a TYPE-ONLY reference to the real modules, so the aura shape
-- keeps exactly one definition; the runtime values come from the dual loader. A
-- `typeof(...)` in type position is erased before execution - it never runs the
-- require (verified: the call count stays 0).
local AuraLadder: typeof(require("./AuraLadder")) = loadSibling("AuraLadder")
local AuraMaterializer: typeof(require("./AuraMaterializer")) = loadSibling("AuraMaterializer")

export type RGB = AuraLadder.RGB
export type AuraDeclaration = AuraLadder.AuraDeclaration
export type AuraConfig = AuraLadder.AuraConfig
export type TierBand = AuraLadder.TierBand
export type MaterializedAura = AuraMaterializer.MaterializedAura

local AURAS: { AuraDeclaration } = AuraLadder.Auras
local TIER_BANDS: { TierBand } = AuraLadder.TierBands

-- The one place a rarity becomes a tier. Bands are ascending and inclusive on
-- `maxRarity`, so a rarity above the top band is clamped to the top tier rather
-- than falling off the end.
local function tierBandFor(rarity: number): TierBand
	for _, band in ipairs(TIER_BANDS) do
		if rarity <= band.maxRarity then
			return band
		end
	end
	return TIER_BANDS[#TIER_BANDS]
end

local AuraRegistry = {}

function AuraRegistry.TierOf(rarity: number): string
	return tierBandFor(rarity).tier
end

function AuraRegistry.TierColorOf(rarity: number): RGB
	return tierBandFor(rarity).color
end

-- =============================================================================
-- Derived indexes (built once at module load).
-- =============================================================================

local REGISTRY: { [string]: AuraConfig } = {}
local ORDER: { string } = table.create(#AURAS)

do
	local seenRarity: { [number]: string } = {}
	local seenTier: { [string]: string } = {}

	for _, declaration in ipairs(AURAS) do
		if REGISTRY[declaration.id] ~= nil then
			error(string.format("AuraRegistry: duplicate aura id %q", declaration.id), 2)
		end

		local rarityClash = seenRarity[declaration.rarity]
		if rarityClash ~= nil then
			error(string.format(
				"AuraRegistry: %s and %s both claim 1/%d",
				rarityClash,
				declaration.id,
				declaration.rarity
			), 2)
		end
		seenRarity[declaration.rarity] = declaration.id

		local tier = AuraRegistry.TierOf(declaration.rarity)
		local tierClash = seenTier[tier]
		if tierClash ~= nil then
			error(string.format(
				"AuraRegistry: %s and %s both derive tier %q - add a rung to TierBands between them",
				tierClash,
				declaration.id,
				tier
			), 2)
		end
		seenTier[tier] = declaration.id

		-- Attach the derived tier so consumers keep reading config.tier.
		local config: any = table.clone(declaration)
		config.tier = tier
		config.tierColor = AuraRegistry.TierColorOf(declaration.rarity)

		REGISTRY[declaration.id] = config :: AuraConfig
		table.insert(ORDER, declaration.id)
	end
end

-- Ascending rarity => ascending "coolness". Used by UI grids and odds tables.
table.sort(ORDER, function(left: string, right: string): boolean
	return REGISTRY[left].rarity < REGISTRY[right].rarity
end)

AuraRegistry.ORDER = ORDER
AuraRegistry.Count = #AURAS

function AuraRegistry.All(): { [string]: AuraConfig }
	return REGISTRY
end

function AuraRegistry.Get(id: string): AuraConfig?
	return REGISTRY[id]
end

-- Same as Get, but raises with a useful message instead of silently returning nil.
function AuraRegistry.Expect(id: string): AuraConfig
	local config = REGISTRY[id]
	if config == nil then
		error(string.format("AuraRegistry.Expect: unknown aura id %q", tostring(id)), 2)
	end
	return config
end

function AuraRegistry.HighestRarity(): number
	local highest = 0
	for _, aura in ipairs(AURAS) do
		if aura.rarity > highest then
			highest = aura.rarity
		end
	end
	return highest
end

-- Returns every aura id whose rarity is at least `minRarity`, rarest last.
function AuraRegistry.RarityAtLeast(minRarity: number): { string }
	local result: { string } = {}
	for _, id in ipairs(ORDER) do
		if REGISTRY[id].rarity >= minRarity then
			table.insert(result, id)
		end
	end
	return result
end

-- Returns a copy so callers cannot corrupt the shared registry entry.
function AuraRegistry.Describe(id: string): { [string]: any }?
	local config = REGISTRY[id]
	if config == nil then
		return nil
	end
	local description: { [string]: any } = {}
	for key, value in pairs(config :: any) do
		description[key] = value
	end
	return description
end

-- -----------------------------------------------------------------------------
-- Rendering seam. These delegate to AuraMaterializer and are the only functions
-- here that require a Roblox engine.
-- -----------------------------------------------------------------------------

function AuraRegistry.ToColor3(rgb: RGB): Color3
	return AuraMaterializer.ToColor3(rgb)
end

function AuraRegistry.Materialize(id: string): MaterializedAura?
	local config = REGISTRY[id]
	if config == nil then
		return nil
	end
	return AuraMaterializer.Materialize(config)
end

return AuraRegistry
